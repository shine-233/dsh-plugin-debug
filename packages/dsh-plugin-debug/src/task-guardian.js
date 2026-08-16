import { appendFileSync, mkdirSync, readdirSync, renameSync, statSync, unlinkSync } from 'node:fs'
import { createHash, randomUUID } from 'node:crypto'
import { homedir } from 'node:os'
import { join } from 'node:path'

export const GUARDIAN_STATUS_PATH = '/api/dsh-plugin-debug/guardian/status'

const GUARDIAN_SCHEMA_VERSION = 1
const DEFAULT_LOOP_MESSAGE = '[dsh-plugin-debug guardian] 检测到相同工具调用在短窗口内重复，任务可能正在原地循环。请停止重复当前步骤，检查已有证据并换一种方法继续。'
const DEFAULT_RECURSION_MESSAGE = '[dsh-plugin-debug guardian] 检测到子任务或工作流嵌套过深，存在自我递归风险。请停止继续派生子任务，在当前层级收敛并完成可验证的下一步。'
const SENSITIVE_KEY = /(authorization|cookie|credential|password|secret|token|api[-_]?key)/iu

function recordOf(value) {
  return value && typeof value === 'object' && !Array.isArray(value) ? value : {}
}

function boundedInteger(value, fallback, minimum, maximum) {
  const parsed = Number(value)
  if (!Number.isFinite(parsed)) return fallback
  return Math.min(maximum, Math.max(minimum, Math.trunc(parsed)))
}

function boundedMessage(value, fallback) {
  if (typeof value !== 'string') return fallback
  const text = value.replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/gu, ' ').trim()
  return text.length > 0 && text.length <= 1000 ? text : fallback
}

export function normalizeGuardianConfig(input = {}) {
  const source = recordOf(input)
  const maxLoopRepeats = boundedInteger(source.maxLoopRepeats, 5, 2, 20)
  return {
    enabled: source.enabled !== false,
    policy: source.policy === 'report' ? 'report' : 'auto',
    maxLoopRepeats,
    loopWindowSize: boundedInteger(source.loopWindowSize, 8, maxLoopRepeats, 64),
    maxSubagentDepth: boundedInteger(source.maxSubagentDepth, 5, 1, 32),
    cooldownMs: boundedInteger(source.cooldownMs, 30000, 0, 600000),
    maxSessions: boundedInteger(source.maxSessions, 256, 16, 1024),
    maxRecentEvents: boundedInteger(source.maxRecentEvents, 50, 10, 100),
    eventLog: source.eventLog !== false,
    eventLogMaxBytes: boundedInteger(source.eventLogMaxBytes, 262144, 1024, 4 * 1024 * 1024),
    eventLogMaxFiles: boundedInteger(source.eventLogMaxFiles, 3, 2, 10),
    loopMessage: boundedMessage(source.loopMessage, DEFAULT_LOOP_MESSAGE),
    recursionMessage: boundedMessage(source.recursionMessage, DEFAULT_RECURSION_MESSAGE),
  }
}

export const guardianConfigSchema = Object.assign(
  value => normalizeGuardianConfig(value),
  {
    toJSON: () => ({
      type: 'object',
      dict: {
        enabled: { type: 'boolean' },
        policy: { type: 'string' },
        maxLoopRepeats: { type: 'number' },
        loopWindowSize: { type: 'number' },
        maxSubagentDepth: { type: 'number' },
       cooldownMs: { type: 'number' },
       eventLog: { type: 'boolean' },
       eventLogMaxBytes: { type: 'number' },
       eventLogMaxFiles: { type: 'number' },
       loopMessage: { type: 'string' },
       recursionMessage: { type: 'string' },
        maxSessions: { type: 'number' },
        maxRecentEvents: { type: 'number' },
     },
    }),
  },
)

function stableValue(value, depth = 0, seen = new WeakSet()) {
  if (depth > 6) return '[depth-limit]'
  if (value === null || value === undefined) return value ?? null
  if (typeof value === 'string') {
    if (value.length > 8192) return `[string:${value.length}]`
    try {
      return stableValue(JSON.parse(value), depth + 1, seen)
    } catch {
      return value
    }
  }
  if (typeof value === 'number' || typeof value === 'boolean') return value
  if (typeof value !== 'object') return `[${typeof value}]`
  if (seen.has(value)) return '[circular]'
  seen.add(value)
  if (Array.isArray(value)) return value.slice(0, 100).map(item => stableValue(item, depth + 1, seen))
  const output = {}
  for (const key of Object.keys(value).sort().slice(0, 100)) {
    output[key] = SENSITIVE_KEY.test(key) ? '[redacted]' : stableValue(value[key], depth + 1, seen)
  }
  return output
}

export function guardianToolFingerprint(event) {
  const data = recordOf(event?.data)
  const name = String(data.name ?? data.tool ?? recordOf(data.block).name ?? 'unknown').slice(0, 180)
  const args = data.arguments ?? data.input ?? recordOf(data.block).arguments ?? null
  const canonical = JSON.stringify(stableValue(args))
  return createHash('sha256').update(`${name}\n${canonical}`).digest('hex')
}

function createGuardianMessage(text) {
  return Object.freeze({
    id: randomUUID(),
    role: 'user',
    source: Object.freeze({ kind: 'plugin', plugin: 'dsh-plugin-debug-guardian' }),
    content: Object.freeze([Object.freeze({ type: 'text', text })]),
  })
}

function parentSessionId(agent) {
  return agent?.session?.header?.parentSession ?? agent?.session?.meta?.parentSession
}

function persistedDelegationDepth(agent) {
  const value = agent?.session?.header?.delegationDepth
  const parsed = Number(value)
  if (!Number.isFinite(parsed) || parsed < 0) return 0
  return Math.trunc(parsed)
}

function getLineageDepth(ctx, agent) {
  let current = agent
  let runtimeDepth = 0
  const durableDepth = persistedDelegationDepth(agent)
  const seen = new Set()
  while (current) {
    const parentId = parentSessionId(current)
    if (parentId === undefined || parentId === null) break
    const key = String(parentId)
    if (seen.has(key)) return Math.max(33, durableDepth)
    seen.add(key)
    runtimeDepth += 1
    current = typeof ctx?.agents?.get === 'function' ? ctx.agents.get(parentId) : undefined
    if (!current) break
  }
  return Math.max(runtimeDepth, durableDepth)
}

function safeEventType(value) {
  if (typeof value !== 'string' || value.length === 0 || value.length > 120) return 'unknown'
  return /^[a-z0-9/_-]+$/iu.test(value) ? value : 'unknown'
}

const INTERRUPTION_REASONS = new Set([
  'aborted',
  'blocked',
  'cancelled',
  'error',
  'interrupted',
  'max-tokens',
])

function sessionKey(value) {
  const id = value?.id
  return id === undefined || id === null ? '' : String(id)
}

function makeEventWriter(configProvider, options, log) {
  const home = options.home ?? process.env.DSH_HOME ?? join(homedir(), '.dsh')
  const guardianRoot = join(home, 'guardian')
  const file = join(guardianRoot, 'events.jsonl')
  const archive = index => `${file}.${index}`

  const pruneArchives = maxFiles => {
    // Remove archives that exceed a newly lowered retention limit before
    // shifting the remaining files. This keeps the total file count bounded
    // even when configuration changes while an installation is running.
    for (const name of readdirSync(guardianRoot)) {
      const match = /^events\.jsonl\.(\d+)$/u.exec(name)
      if (match && Number(match[1]) >= maxFiles) {
        unlinkSync(join(guardianRoot, name))
      }
    }
  }

  const rotate = maxFiles => {
    pruneArchives(maxFiles)
    for (let index = maxFiles - 1; index >= 1; index -= 1) {
      const target = archive(index)
      const source = index === 1 ? file : archive(index - 1)
      try {
        unlinkSync(target)
      } catch (error) {
        if (error?.code !== 'ENOENT') throw error
      }
      try {
        renameSync(source, target)
      } catch (error) {
        if (error?.code !== 'ENOENT') throw error
      }
    }
  }

  return {
    file,
    retention() {
      const config = configProvider()
      return { maxBytes: config.eventLogMaxBytes, maxFiles: config.eventLogMaxFiles }
    },
    write(event) {
      const config = configProvider()
      if (!config.eventLog) return
      try {
        mkdirSync(guardianRoot, { recursive: true })
        const line = `${JSON.stringify(event)}\n`
        const incomingBytes = Buffer.byteLength(line, 'utf8')
        let currentBytes = 0
        try { currentBytes = statSync(file).size } catch (error) {
          if (error?.code !== 'ENOENT') throw error
        }
        pruneArchives(config.eventLogMaxFiles)
        if (incomingBytes > config.eventLogMaxBytes) {
          log(`Guardian event dropped because its redacted record exceeds eventLogMaxBytes (${incomingBytes} > ${config.eventLogMaxBytes})`)
          return
        }
        if (currentBytes > 0 && currentBytes + incomingBytes > config.eventLogMaxBytes) {
          rotate(config.eventLogMaxFiles)
        }
        appendFileSync(file, line, 'utf8')
      } catch (error) {
        log(`Guardian event report could not be written: ${String(error?.message ?? error)}`)
      }
    },
  }
}

function registerStatusRoute(ctx, controller) {
  if (typeof ctx?.inject !== 'function') return
  ctx.inject(['webServer'], (wctx) => {
    const register = () => wctx.webServer.register({
      kind: 'exact',
      path: GUARDIAN_STATUS_PATH,
      handler: async (req, res) => {
        if (req.method !== 'GET') {
          res.writeHead(405, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' })
          res.end(JSON.stringify({ ok: false, error: 'method not allowed' }))
          return
        }
        res.writeHead(200, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' })
        res.end(JSON.stringify(controller.snapshot()))
      },
    })
    if (typeof wctx.effect === 'function') wctx.effect(register, 'dsh-plugin-debug guardian status route')
    else register()
  })
}

export function registerTaskGuardian(ctx, input = {}, options = {}) {
  const initial = normalizeGuardianConfig(input)
  let currentConfig = () => initial
  const now = typeof options.now === 'function' ? options.now : () => Date.now()
  const logger = typeof ctx?.logger?.info === 'function'
    ? message => ctx.logger.info(`[dsh-plugin-debug guardian] ${message}`)
    : () => {}
  const entries = new Map()
  const recentEvents = []
  let nextSessionRef = 1
  const writer = makeEventWriter(() => currentConfig(), options, logger)

  const addRecent = (event) => {
    recentEvents.push(event)
    const limit = currentConfig().maxRecentEvents
    if (recentEvents.length > limit) recentEvents.splice(0, recentEvents.length - limit)
    writer.write(event)
  }

  const record = (kind, entry, details = {}) => {
    const event = {
      ts: new Date(now()).toISOString(),
      kind,
      sessionRef: entry?.sessionRef ?? null,
      ...details,
    }
    addRecent(event)
    return event
  }

  const ensure = (id, agent) => {
    const key = String(id ?? '')
    if (!key) return null
    let entry = entries.get(key)
    if (!entry) {
      if (entries.size >= currentConfig().maxSessions) {
        const idle = [...entries.entries()].find(([, candidate]) => !candidate.running && candidate.busy === 0)
        if (idle) entries.delete(idle[0])
        else return null
      }
      entry = {
        sessionRef: `session-${String(nextSessionRef++).padStart(4, '0')}`,
        agent: null,
        running: false,
        busy: 0,
        workflowDepth: 0,
        lineageDepth: 0,
        calls: [],
        lastGuidanceAt: Number.NEGATIVE_INFINITY,
        lastEvent: 'created',
        turn: 0,
      }
      entries.set(key, entry)
    }
    if (agent) entry.agent = agent
    return entry
  }

  const guide = (entry, detectedKind, message) => {
    const cfg = currentConfig()
    if (cfg.policy !== 'auto') return false
    const timestamp = now()
    if (timestamp - entry.lastGuidanceAt < cfg.cooldownMs) return false
    entry.lastGuidanceAt = timestamp
    const agent = entry.agent
    const payload = createGuardianMessage(message)
    try {
      if (agent?.status === 'running' && typeof agent.steer === 'function') agent.steer(payload)
      else if (typeof agent?.inject === 'function') agent.inject(payload)
      else return false
      record(detectedKind.replace(/_DETECTED$/u, '_GUIDED'), entry, { mode: agent?.status === 'running' ? 'steer' : 'inject' })
      return true
    } catch (error) {
      record('GUIDANCE_UNAVAILABLE', entry, { for: detectedKind })
      logger(`Guidance was unavailable for ${entry.sessionRef}: ${String(error?.message ?? error)}`)
      return false
    }
  }

  const detectRecursion = (entry, source) => {
    const depth = Math.max(entry.lineageDepth, entry.workflowDepth)
    const threshold = currentConfig().maxSubagentDepth
    if (depth <= threshold) return
    record('RECURSION_DETECTED', entry, { depth, threshold, source })
    guide(entry, 'RECURSION_DETECTED', currentConfig().recursionMessage)
  }

  const onAgentCreated = (payload) => {
    try {
      const agent = payload?.agent ?? payload
      const key = sessionKey(agent?.session) || sessionKey(agent)
      const entry = ensure(key, agent)
      if (!entry) return
      entry.running = agent?.status === 'running'
      entry.lineageDepth = getLineageDepth(ctx, agent)
      detectRecursion(entry, 'agent-lineage')
    } catch (error) {
      logger(`Agent creation observation failed: ${String(error?.message ?? error)}`)
    }
  }

  const onAgentStatus = (payload, legacyPayload) => {
    try {
      const view = legacyPayload?.agent ? legacyPayload : payload
      const agent = view?.agent ?? legacyPayload?.agent
      const status = view?.status ?? legacyPayload?.status
      const key = sessionKey(agent?.session) || sessionKey(agent)
      const entry = ensure(key, agent)
      if (!entry) return
      entry.running = status === 'running'
      if (status === 'idle') {
        entry.busy = 0
        entry.workflowDepth = 0
      }
    } catch (error) {
      logger(`Agent status observation failed: ${String(error?.message ?? error)}`)
    }
  }

  const onSessionEvent = (session, event) => {
    try {
      if (!event || typeof event !== 'object') return
      const key = sessionKey(session)
      const knownAgent = typeof ctx?.agents?.get === 'function' ? ctx.agents.get(session?.id) : undefined
      const entry = ensure(key, knownAgent)
      if (!entry) return
      const type = safeEventType(event.type)
      entry.lastEvent = type
      if (type === 'turn/start') {
        entry.turn = Number.isFinite(Number(event?.data?.turn)) ? Number(event.data.turn) : entry.turn
        entry.running = true
      }
      if (type === 'tool/call') {
        entry.busy += 1
        const fingerprint = guardianToolFingerprint(event)
        entry.calls.push(fingerprint)
        const cfg = currentConfig()
        if (entry.calls.length > cfg.loopWindowSize) entry.calls.splice(0, entry.calls.length - cfg.loopWindowSize)
        const repeats = entry.calls.filter(value => value === fingerprint).length
        if (repeats >= cfg.maxLoopRepeats) {
          record('LOOP_DETECTED', entry, { fingerprint, repeats, windowSize: entry.calls.length, turn: entry.turn })
          guide(entry, 'LOOP_DETECTED', cfg.loopMessage)
          entry.calls = []
        }
      } else if (type === 'tool/result') {
        entry.busy = Math.max(0, entry.busy - 1)
      } else if (type === 'tool-workflow/run-start') {
        entry.busy += 1
      } else if (type === 'tool-workflow/run-end') {
        entry.busy = Math.max(0, entry.busy - 1)
      } else if (type === 'tool-workflow/agent-start') {
        entry.workflowDepth += 1
        detectRecursion(entry, 'workflow-events')
      } else if (type === 'tool-workflow/agent-end') {
        entry.workflowDepth = Math.max(0, entry.workflowDepth - 1)
      } else if (type === 'step/end') {
        entry.busy = 0
      } else if (type === 'turn/end') {
        entry.busy = 0
        entry.workflowDepth = 0
        const reason = safeEventType(event?.data?.reason?.kind)
        if (INTERRUPTION_REASONS.has(reason)) {
          record('INTERRUPTION_OBSERVED', entry, { reason, turn: entry.turn })
        }
      }
    } catch (error) {
      logger(`Session observation failed: ${String(error?.message ?? error)}`)
    }
  }

  const snapshot = () => {
    const cfg = currentConfig()
    const watching = [...entries.values()].map(entry => ({
      sessionRef: entry.sessionRef,
      running: entry.running,
      busy: entry.busy,
      depth: Math.max(entry.lineageDepth, entry.workflowDepth),
      recentCalls: entry.calls.length,
      lastEvent: entry.lastEvent,
    }))
    const activeSessions = watching.filter(entry => entry.running).length
    const inFlightOperations = watching.reduce((total, entry) => total + entry.busy, 0)
    return {
      ok: true,
      kind: 'dsh-plugin-debug-guardian-status',
      schemaVersion: GUARDIAN_SCHEMA_VERSION,
      enabled: cfg.enabled,
      policy: cfg.policy,
      safeToRestart: activeSessions === 0 && inFlightOperations === 0,
      activeSessions,
      inFlightOperations,
      watching,
      recentEvents: [...recentEvents],
      safety: {
        actions: ['detect', 'guide', 'report'],
        terminatesTasks: false,
        stopsProcesses: false,
        restartsHost: false,
        disablesPlugins: false,
        mutatesProfile: false,
      },
      privacy: {
        rawSessionIdsReturned: false,
        rawToolArgumentsReturned: false,
        fingerprintsAreEncryption: false,
        eventStore: '$DSH_HOME/guardian/events.jsonl',
        eventLogRetention: writer.retention(),
      },
    }
  }

  const controller = { snapshot, statusPath: GUARDIAN_STATUS_PATH, eventFile: writer.file }
  if (!initial.enabled || !ctx || typeof ctx.on !== 'function') return controller

  if (typeof ctx.inject === 'function') {
    ctx.inject(['settings'], (sctx) => {
      try {
        const scope = sctx.settings.register('guardian', guardianConfigSchema, { base: initial })
        currentConfig = () => normalizeGuardianConfig(scope.get())
        if (typeof scope.watch === 'function') scope.watch(() => record('CONFIG_UPDATED', null, { policy: currentConfig().policy }))
      } catch (error) {
        logger(`Guardian settings integration was unavailable: ${String(error?.message ?? error)}`)
      }
    })
  }

  ctx.on('agent/created', onAgentCreated)
  ctx.on('agent/disposed', (payload) => {
    const agent = payload?.agent ?? payload
    const key = sessionKey(agent?.session) || sessionKey(agent)
    if (key) entries.delete(key)
  })
  ctx.on('agent/status', onAgentStatus)
  ctx.on('session/event', onSessionEvent)
  registerStatusRoute(ctx, controller)
  record('GUARDIAN_ARMED', null, { policy: initial.policy, neverTerminatesTasks: true })
  return controller
}
