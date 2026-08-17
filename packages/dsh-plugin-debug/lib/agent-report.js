import { createHash } from 'node:crypto'

/**
 * Deterministic DSH session report.
 *
 * This is the small, dependency-free part of the DeepTrace idea that belongs
 * in the debug plugin: read a session source, aggregate usage and failures,
 * and explain the result without calling a model.  It deliberately does not
 * fetch pricing, read credentials, write session history, or persist a report.
 *
 * The source is an injected behaviour surface rather than a hard dependency
 * on dsh-session-query.  A full profile can provide persisted + live history;
 * a reduced profile can still report the live ctx.sessions service.
 */

export const AGENT_REPORT_SCHEMA_VERSION = 1
export const AGENT_REPORT_DOCUMENT_SCHEMA_VERSION = 1
export const AGENT_REPORT_PRESETS = ['daily', '24h', 'weekly', 'monthly', 'yearly', 'custom']

const DAY_MS = 24 * 60 * 60 * 1000
const MAX_SESSIONS = 500
const MAX_EVENTS_PER_SESSION = 100000
const MAX_TOTAL_EVENTS = 1000000

// Conservative built-in estimate.  It is intentionally labelled as an
// estimate and never presented as the provider's invoice.
const PRICES = {
  flash: { cache: 0.02, input: 1, output: 2 },
  pro: { cache: 0.025, input: 3, output: 6 },
}

const SECRET_PATTERNS = [
  { pattern: /\bsk-[A-Za-z0-9]{16,}\b/, label: 'OpenAI 风格密钥' },
  { pattern: /\bAKIA[0-9A-Z]{16}\b/, label: 'AWS Access Key' },
  { pattern: /-----BEGIN (?:RSA |OPENSSH |EC )?PRIVATE KEY-----/, label: '私钥块' },
  { pattern: /\bghp_[A-Za-z0-9]{20,}\b/, label: 'GitHub PAT' },
  { pattern: /\bxox[baprs]-[A-Za-z0-9-]{10,}\b/, label: 'Slack Token' },
  { pattern: /\b(?:api[_-]?key|token|password|secret)\b\s*[=:]\s*['"]?[A-Za-z0-9_.-]{12,}/i, label: '配置型密钥' },
]

// Security boundary: these regular expressions only classify command text that
// already exists in a Session event. They are never passed to child_process,
// PowerShell, a shell, or any other executor. Keep report detection separate
// from command execution so a dangerous string remains inert input.
const DANGEROUS_PATTERNS = [
  { pattern: /rm\s+(-[a-z]*r[a-z]*f|-[a-z]*f[a-z]*r)\s+(?:\/(?:\s|$)|~\/?(?:\s|$))/, label: '删除根目录/家目录', severity: 'red' },
  { pattern: /DROP\s+(TABLE|DATABASE)/i, label: '删库', severity: 'red' },
  { pattern: /^(?:sudo\s+)?(?:shutdown|reboot|halt)\b/, label: '关机/重启', severity: 'red' },
  { pattern: /mkfs\./, label: '格式化磁盘', severity: 'red' },
  { pattern: /dd\s+if=.*of=\/dev\//, label: 'dd 写设备', severity: 'red' },
  { pattern: /:\(\)\s*\{\s*:\|:\s*&\s*\};?\s*:/, label: 'fork 炸弹', severity: 'red' },
  { pattern: /rm\s+(-[a-z]*r[a-z]*f|-[a-z]*f[a-z]*r)\b/, label: 'rm -rf 删除', severity: 'amber' },
  { pattern: /git\s+push\b[^\n]*--force/, label: 'force push', severity: 'amber' },
  { pattern: /git\s+reset\s+--hard/, label: '硬重置 git', severity: 'amber' },
  { pattern: /chmod\s+(-R\s+)?777/, label: '777 全开放', severity: 'amber' },
  { pattern: /curl\s+\S+\s*\|\s*(ba)?sh/, label: 'curl|sh 远程执行', severity: 'amber' },
]

function record(value) {
  return value && typeof value === 'object' && !Array.isArray(value) ? value : {}
}

function finiteNumber(value, fallback = 0) {
  return typeof value === 'number' && Number.isFinite(value) ? value : fallback
}

function nonNegativeNumber(value) {
  return Math.max(0, finiteNumber(value))
}

function stringValue(value) {
  return typeof value === 'string' ? value : ''
}

function dictionary() {
  return Object.create(null)
}

// Session metadata is not a trusted presentation string. Keep labels bounded
// and markdown-safe so a hostile model/tool/provider name cannot inject a
// table row, control character, or an unbounded report line.
function safeLabel(value, max = 80) {
  const normalized = String(value ?? '')
    .replace(/\bsk-[A-Za-z0-9]{16,}\b/g, '[redacted-secret]')
    .replace(/\bghp_[A-Za-z0-9]{20,}\b/g, '[redacted-secret]')
    .replace(/\bAKIA[0-9A-Z]{16}\b/g, '[redacted-secret]')
    .replace(/(\b(?:api[_-]?key|token|password|secret)\b\s*[=:]\s*)['"]?[A-Za-z0-9_.-]{12,}/gi, '$1[redacted-secret]')
    .replace(/[\u0000-\u001f\u007f`|<>()[\]{}&]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
  return normalized.slice(0, max) || 'unknown'
}

function sessionIdOf(header) {
  const id = record(header).id
  return typeof id === 'string' || typeof id === 'number' ? String(id) : ''
}

function headerOf(snapshot) {
  const value = record(snapshot)
  return record(value.session).id !== undefined ? value.session : record(value.header)
}

function modelTier(model) {
  return /pro/i.test(model.includes('/') ? model.slice(model.indexOf('/') + 1) : model) ? 'pro' : 'flash'
}

function modelKey(provider, model) {
  const safeProvider = safeLabel(provider)
  const safeModel = safeLabel(model)
  if (safeProvider && safeProvider !== 'unknown') return `${safeProvider}/${safeModel}`
  return safeModel
}

function modelAndProvider(state, data) {
  const value = record(data)
  const header = record(value.header)
  const config = record(header.config)
  const context = value
  const model = stringValue(config.model) || stringValue(context.model)
  const provider = stringValue(config.provider) || stringValue(context.provider) || stringValue(context.route)
  if (model) state.model = safeLabel(model)
  if (provider) state.provider = safeLabel(provider.trim().toLowerCase())
}

function usageOf(data) {
  const usage = record(record(data).usage)
  return {
    input: nonNegativeNumber(usage.inputTokens),
    output: nonNegativeNumber(usage.outputTokens),
    cacheRead: nonNegativeNumber(usage.cacheReadTokens),
    cacheWrite: nonNegativeNumber(usage.cacheWriteTokens),
    reasoning: nonNegativeNumber(usage.reasoningTokens),
  }
}

// DSH's token meter may publish an early `assistant/chunk` usage sample and
// then replace it with the final `assistant/message` sample for the same
// turn/step.  Keep the latest sample instead of double-counting it.  The
// fallback key is event-specific when a malformed/legacy event has no
// turn/step pair, so unrelated samples cannot collapse into one another.
function usageSampleOf(event) {
  const value = record(event)
  const data = record(value.data)
  if (value.type === 'assistant/chunk') {
    const chunk = record(data.chunk)
    if (chunk.type !== 'usage') return null
    return { usage: usageOf({ usage: chunk.usage }), turn: data.turn, step: data.step }
  }
  if (value.type === 'assistant/message' && data.usage !== undefined) {
    return { usage: usageOf(data), turn: data.turn, step: data.step }
  }
  return null
}

function textValues(data) {
  const value = record(data)
  const content = value.content ?? record(value.message).content
  if (typeof content === 'string') return [content]
  if (!Array.isArray(content)) return []
  return content.flatMap(block => {
    const item = record(block)
    return item.type === 'text' && typeof item.text === 'string' ? [item.text] : []
  })
}

function stripQuotes(value) {
  return value.replace(/["'][^"'\n]*["']/g, ' ')
}

function secretLabels(value) {
  return SECRET_PATTERNS.filter(item => item.pattern.test(value)).map(item => item.label)
}

function shellCommandOf(data) {
  const value = record(data)
  const name = stringValue(value.name).toLowerCase()
  if (!['bash', 'pwsh', 'powershell', 'shell', 'terminal', 'run_code'].includes(name)) return null
  const raw = value.arguments
  const args = typeof raw === 'string' ? (() => {
    try { return record(JSON.parse(raw)) } catch { return {} }
  })() : record(raw)
  const command = stringValue(args.command) || stringValue(args.commandLine) || stringValue(args.script)
  return command || null
}

function resultFailed(data) {
  const value = record(data)
  if (value.error !== undefined && value.error !== null) return true
  const message = record(value.message)
  if (message.isError === true) return true
  if (Array.isArray(message.content)) {
    return message.content.some(block => record(block).type === 'error')
  }
  return typeof message.content === 'string' && /error|failed|EACCES|ENOENT|command not found/i.test(message.content)
}

function normalizeAgentReportDocument(document) {
  const value = record(document)
  if (value.schemaVersion !== AGENT_REPORT_DOCUMENT_SCHEMA_VERSION) {
    throw new Error(`脱敏 Session 文档 schemaVersion 必须是 ${AGENT_REPORT_DOCUMENT_SCHEMA_VERSION}`)
  }
  if (!Array.isArray(value.sessions)) throw new Error('脱敏 Session 文档必须包含 sessions 数组')
  if (value.sessions.length > MAX_SESSIONS) throw new Error(`脱敏 Session 文档最多允许 ${MAX_SESSIONS} 个 Session`)

  const ids = new Set()
  let totalEvents = 0
  const sessions = value.sessions.map((item, index) => {
    const source = record(item)
    const header = record(source.header ?? source.session)
    const id = stringValue(header.id)
    if (!id) throw new Error(`脱敏 Session 文档第 ${index + 1} 项缺少 header.id`)
    if (ids.has(id)) throw new Error(`脱敏 Session 文档包含重复的 Session ID（第 ${index + 1} 项）`)
    ids.add(id)
    if (!Number.isSafeInteger(header.createdAt) || header.createdAt < 0) {
      throw new Error(`脱敏 Session 文档第 ${index + 1} 项的 createdAt 必须是毫秒时间戳`)
    }
    const events = source.events
    if (!Array.isArray(events)) throw new Error(`脱敏 Session 文档第 ${index + 1} 项缺少 events 数组`)
    if (events.length > MAX_EVENTS_PER_SESSION) throw new Error(`单个 Session 事件数不能超过 ${MAX_EVENTS_PER_SESSION}`)
    totalEvents += events.length
    if (totalEvents > MAX_TOTAL_EVENTS) throw new Error(`脱敏 Session 文档事件总数不能超过 ${MAX_TOTAL_EVENTS}`)
    const normalizedEvents = events.map((event, eventIndex) => {
      const normalized = record(event)
      if (!stringValue(normalized.type)) throw new Error(`脱敏 Session 文档第 ${index + 1} 项事件 ${eventIndex + 1} 缺少 type`)
      if (!Number.isSafeInteger(normalized.seq) || normalized.seq < 0) throw new Error(`脱敏 Session 文档第 ${index + 1} 项事件 ${eventIndex + 1} 的 seq 无效`)
      if (!Number.isSafeInteger(normalized.time) || normalized.time < 0) throw new Error(`脱敏 Session 文档第 ${index + 1} 项事件 ${eventIndex + 1} 的 time 无效`)
      return normalized
    })
    return {
      header: {
        id,
        createdAt: header.createdAt,
        ...(Number.isSafeInteger(header.seedLength) && header.seedLength >= 0 ? { seedLength: header.seedLength } : {}),
        ...(Number.isSafeInteger(header.delegationDepth) && header.delegationDepth >= 0 ? { delegationDepth: header.delegationDepth } : {}),
      },
      events: normalizedEvents,
    }
  })
  return sessions
}

function emptyAggregate(period) {
  return {
    period,
    sessions: 0,
    subagentSessions: 0,
    turns: 0,
    steps: 0,
    userMessages: 0,
    assistantMessages: 0,
    totalEvents: 0,
    toolCallsTotal: 0,
    toolErrors: 0,
    turnFailures: 0,
    turnAborts: 0,
    turnInterruptions: 0,
    commands: 0,
    retryBursts: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, reasoning: 0 },
    models: dictionary(),
    toolCalls: dictionary(),
    dangerous: { total: 0, red: 0, amber: 0, byLabel: dictionary() },
    secrets: { total: 0, byLabel: dictionary(), bySource: { user: 0, tool: 0 } },
    unknownEvents: 0,
    sessionsDetail: [],
  }
}

function ensureModel(models, key) {
  return (models[key] ??= { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, reasoning: 0 })
}

function ensureSession(sessions, id, time) {
  let current = sessions.get(id)
  if (!current) {
    current = {
      // Keep the raw ID only as the in-memory Map key.  The result object is an
      // exported API, so never let a provider/session identifier cross that
      // boundary; a stable digest preserves grouping without exposing it.
      sessionId: anonymizedSessionId(id),
      firstTime: time,
      lastTime: time,
      events: 0,
      turns: 0,
      userMessages: 0,
      assistantMessages: 0,
      toolCalls: 0,
      toolErrors: 0,
      retryBursts: 0,
      dangerCount: 0,
      redDanger: 0,
      modelTokens: dictionary(),
      cost: 0,
    }
    sessions.set(id, current)
  }
  current.firstTime = Math.min(current.firstTime, time)
  current.lastTime = Math.max(current.lastTime, time)
  current.events += 1
  return current
}

function anonymizedSessionId(id) {
  const normalized = String(id ?? '')
  if (!normalized) return 'session-unknown'
  const digest = createHash('sha256')
    .update('dsh-plugin-debug:agent-report:session:', 'utf8')
    .update(normalized, 'utf8')
    .digest('hex')
  return `session-${digest.slice(0, 16)}`
}

function addSecret(aggregate, labels, source) {
  for (const label of labels) {
    aggregate.secrets.total += 1
    aggregate.secrets.byLabel[label] = (aggregate.secrets.byLabel[label] ?? 0) + 1
    aggregate.secrets.bySource[source] += 1
  }
}

function addUsage(target, usage) {
  target.input += usage.input
  target.output += usage.output
  target.cacheRead += usage.cacheRead
  target.cacheWrite += usage.cacheWrite
  target.reasoning += usage.reasoning
}

function costOfUsage(usage, model) {
  const prices = PRICES[modelTier(model)]
  return (usage.cacheRead / 1000000) * prices.cache +
    (Math.max(0, usage.input - usage.cacheRead) / 1000000) * prices.input +
    (usage.output / 1000000) * prices.output
}

function formatTokens(value) {
  if (value >= 1000000) return `${(value / 1000000).toFixed(2)}M`
  if (value >= 1000) return `${(value / 1000).toFixed(1)}K`
  return String(Math.round(value))
}

function formatNumber(value) {
  return new Intl.NumberFormat('zh-CN').format(Math.round(value))
}

function safeSessionId(id) {
  const normalized = String(id ?? '')
  if (/^session-[0-9a-f]{16}$/u.test(normalized)) return normalized
  return anonymizedSessionId(normalized)
}

function presetRange(preset, now, from, to) {
  if (!AGENT_REPORT_PRESETS.includes(preset)) throw new Error(`未知报告区间：${String(preset)}`)
  if (preset === 'custom') {
    const fromMs = Date.parse(String(from ?? ''))
    const toMs = Date.parse(String(to ?? ''))
    if (!Number.isFinite(fromMs) || !Number.isFinite(toMs)) throw new Error('自定义区间必须提供有效的 from/to ISO 时间')
    if (toMs <= fromMs) throw new Error('时间区间无效：to 必须晚于 from')
    return { from: fromMs, to: toMs }
  }
  if (preset === 'daily') return { from: new Date(now).setHours(0, 0, 0, 0), to: now }
  if (preset === '24h') return { from: now - DAY_MS, to: now }
  if (preset === 'weekly') return { from: now - 7 * DAY_MS, to: now }
  if (preset === 'monthly') return { from: now - 30 * DAY_MS, to: now }
  return { from: now - 365 * DAY_MS, to: now }
}

export function resolveAgentReportRange(preset = 'weekly', from, to, now = Date.now()) {
  return presetRange(preset, now, from, to)
}

/**
 * Read the injected source with bounded concurrency.  Errors are counted, not
 * printed: a report must never turn a session payload into an error log.
 */
async function collectAgentReportEvents(source, period) {
  if (!source || typeof source.listSessions !== 'function' || typeof source.readSession !== 'function') {
    return { available: false, sourceKind: 'none', headers: [], events: [], coverage: { listedSessions: 0, selectedSessions: 0, readSessions: 0, readFailures: 0, eventsRead: 0, eventsUsed: 0, truncated: false } }
  }

  let records
  try {
    records = await source.listSessions()
  } catch {
    return { available: false, sourceKind: source.kind ?? 'unknown', headers: [], events: [], coverage: { listedSessions: 0, selectedSessions: 0, readSessions: 0, readFailures: 1, eventsRead: 0, eventsUsed: 0, truncated: false } }
  }
  const list = Array.isArray(records) ? records : []
  const candidates = []
  let candidateOverflow = false
  for (const item of list) {
    const candidate = { record: record(item), header: record(item).header ?? record(item).session }
    if (!sessionIdOf(candidate.header) || !Number.isFinite(finiteNumber(candidate.header.createdAt, NaN)) || finiteNumber(candidate.header.createdAt) >= period.to) continue
    if (candidates.length >= MAX_SESSIONS) {
      candidateOverflow = true
      break
    }
    candidates.push(candidate)
  }
  const selected = candidates
  const headers = selected.map(item => item.header)
  const events = []
  let readSessions = 0
  let readFailures = 0
  let eventsRead = 0
  let reservedEvents = 0
  let budgetExhausted = false
  let cursor = 0
  const worker = async () => {
    for (;;) {
      const index = cursor++
      if (index >= selected.length) return
      const remainingBudget = MAX_TOTAL_EVENTS - reservedEvents
      if (remainingBudget <= 0) {
        budgetExhausted = true
        return
      }
      const sessionEventBudget = Math.min(MAX_EVENTS_PER_SESSION, remainingBudget)
      // Reserve the budget before awaiting the source. JavaScript runs this
      // synchronous section atomically, so concurrent workers cannot reserve
      // more than MAX_TOTAL_EVENTS for parsing and aggregation.
      reservedEvents += sessionEventBudget
      const id = sessionIdOf(selected[index].header)
      try {
        const snapshot = await source.readSession(id)
        const session = headerOf(snapshot)
        const sessionId = sessionIdOf(session) || id
        const seedLength = Math.max(0, Math.floor(finiteNumber(session.seedLength)))
        const rawEvents = Array.isArray(record(snapshot).events) ? record(snapshot).events : []
        const bounded = rawEvents.slice(0, sessionEventBudget)
        readSessions += 1
        eventsRead += bounded.length
        if (rawEvents.length > sessionEventBudget) budgetExhausted = true
        for (const event of bounded) {
          if (events.length >= MAX_TOTAL_EVENTS) break
          if (finiteNumber(event.seq) < seedLength) continue
          events.push({ sessionId, event })
        }
      } catch {
        readFailures += 1
      }
    }
  }
  await Promise.all(Array.from({ length: Math.min(8, Math.max(1, selected.length)) }, () => worker()))
  const eventsUsed = events.filter(item => finiteNumber(item.event.time) >= period.from && finiteNumber(item.event.time) < period.to).length
  return {
    available: true,
    sourceKind: source.kind ?? 'unknown',
    headers,
    events,
    coverage: {
      listedSessions: list.length,
      selectedSessions: selected.length,
      readSessions,
      readFailures,
      eventsRead,
      eventsUsed,
      truncated: candidateOverflow || budgetExhausted || selected.length > readSessions + readFailures,
    },
  }
}

export function aggregateAgentReportEvents(collected, period) {
  const aggregate = emptyAggregate(period)
  const sessionAgg = new Map()
  const headerById = new Map((collected.headers ?? []).map(header => [sessionIdOf(header), header]))
  const seenSessions = new Set()
  const modelState = new Map()
  const usageSamples = new Map()
  const lastCommand = new Map()
  const commandStreak = new Map()
  const days = new Set()

  for (const item of collected.events ?? []) {
    const event = record(item.event)
    const time = finiteNumber(event.time, NaN)
    if (!Number.isFinite(time) || time < period.from || time >= period.to) continue
    const type = stringValue(event.type)
    if (type.startsWith('whale/') || type.startsWith('dsh-plugin-debug/')) continue
    const sessionId = item.sessionId || 'unknown'
    const seedLength = Math.max(0, Math.floor(finiteNumber(headerById.get(sessionId)?.seedLength)))
    if (finiteNumber(event.seq) < seedLength) continue
    const data = record(event.data)
    const session = ensureSession(sessionAgg, sessionId, time)
    seenSessions.add(sessionId)
    aggregate.totalEvents += 1
    const day = new Date(time).toISOString().slice(0, 10)
    days.add(day)

    if (type === 'turn/start') {
      aggregate.turns += 1
      session.turns += 1
    } else if (type === 'turn/end') {
      const reason = stringValue(record(data.reason).kind)
      if (reason === 'error' || reason === 'max-tokens') aggregate.turnFailures += 1
      if (reason === 'aborted') aggregate.turnAborts += 1
      if (reason === 'interrupted') aggregate.turnInterruptions += 1
    } else if (type === 'step/start') {
      aggregate.steps += 1
    } else if (type === 'user/message') {
      aggregate.userMessages += 1
      session.userMessages += 1
      for (const text of textValues(data)) addSecret(aggregate, secretLabels(text), 'user')
    } else if (type === 'assistant/message') {
      aggregate.assistantMessages += 1
      const usageSample = usageSampleOf(event)
      if (usageSample) {
        const state = modelState.get(sessionId) ?? { model: 'unknown', provider: 'unknown' }
        const turn = finiteNumber(usageSample.turn, NaN)
        const step = finiteNumber(usageSample.step, NaN)
        const sampleKey = Number.isFinite(turn) && Number.isFinite(step)
          ? `${sessionId}\u0000${turn}\u0000${step}`
          : `${sessionId}\u0000seq:${finiteNumber(event.seq, 0)}`
        usageSamples.set(sampleKey, {
          sessionId,
          usage: usageSample.usage,
          modelKey: modelKey(state.provider, state.model),
        })
      }
    } else if (type === 'assistant/chunk') {
      const usageSample = usageSampleOf(event)
      if (usageSample) {
        const state = modelState.get(sessionId) ?? { model: 'unknown', provider: 'unknown' }
        const turn = finiteNumber(usageSample.turn, NaN)
        const step = finiteNumber(usageSample.step, NaN)
        const sampleKey = Number.isFinite(turn) && Number.isFinite(step)
          ? `${sessionId}\u0000${turn}\u0000${step}`
          : `${sessionId}\u0000seq:${finiteNumber(event.seq, 0)}`
        usageSamples.set(sampleKey, {
          sessionId,
          usage: usageSample.usage,
          modelKey: modelKey(state.provider, state.model),
        })
      }
    } else if (type === 'request/header' || type === 'request/context') {
      const state = modelState.get(sessionId) ?? { model: 'unknown', provider: 'unknown' }
      modelAndProvider(state, data)
      modelState.set(sessionId, state)
    } else if (type === 'tool/call') {
      aggregate.toolCallsTotal += 1
      session.toolCalls += 1
      const name = safeLabel(stringValue(data.name), 64)
      aggregate.toolCalls[name] = (aggregate.toolCalls[name] ?? 0) + 1
      const command = shellCommandOf(data)
      if (command) {
        aggregate.commands += 1
        const firstLine = command.split('\n', 1)[0].trim()
        const comparison = firstLine.replace(/\s+/g, ' ')
        if (lastCommand.get(sessionId) === comparison) {
          const streak = (commandStreak.get(sessionId) ?? 1) + 1
          commandStreak.set(sessionId, streak)
          if (streak === 3) {
            aggregate.retryBursts += 1
            session.retryBursts += 1
          }
        } else {
          lastCommand.set(sessionId, comparison)
          commandStreak.set(sessionId, 1)
        }
        addSecret(aggregate, secretLabels(firstLine), 'tool')
        const matchText = stripQuotes(firstLine)
        const danger = DANGEROUS_PATTERNS.find(item => item.pattern.test(matchText))
        if (danger) {
          aggregate.dangerous.total += 1
          aggregate.dangerous[danger.severity] += 1
          aggregate.dangerous.byLabel[danger.label] = (aggregate.dangerous.byLabel[danger.label] ?? 0) + 1
          session.dangerCount += 1
          if (danger.severity === 'red') session.redDanger += 1
        }
      }
    } else if (type === 'tool/result') {
      if (resultFailed(data)) {
        aggregate.toolErrors += 1
        session.toolErrors += 1
      }
    } else if (type !== 'assistant/chunk' && type !== 'session/end-seed' && type !== 'todo/write') {
      aggregate.unknownEvents += 1
    }
  }

  // Fold one latest provider usage sample per turn/step.  This mirrors the
  // runtime token-meter projection: an early chunk survives a failed request,
  // while a later finalized assistant message replaces the same step's sample.
  for (const sample of usageSamples.values()) {
    addUsage(aggregate.tokens, sample.usage)
    addUsage(ensureModel(aggregate.models, sample.modelKey), sample.usage)
    const session = sessionAgg.get(sample.sessionId)
    if (session) addUsage(ensureModel(session.modelTokens, sample.modelKey), sample.usage)
  }

  for (const header of collected.headers ?? []) {
    const createdAt = finiteNumber(header.createdAt, NaN)
    if (Number.isFinite(createdAt) && createdAt >= period.from && createdAt < period.to) {
      seenSessions.add(sessionIdOf(header))
    }
    if (finiteNumber(header.delegationDepth) >= 1 && Number.isFinite(createdAt) && createdAt < period.to) aggregate.subagentSessions += 1
  }
  aggregate.sessions = seenSessions.size
  aggregate.activeDays = days.size
  aggregate.sessionsDetail = [...sessionAgg.values()]
  return aggregate
}

export function computeAgentReportCost(models) {
  const perModel = dictionary()
  let total = 0
  for (const [model, usage] of Object.entries(models ?? {})) {
    const cost = costOfUsage(usage, model)
    perModel[model] = cost
    total += cost
  }
  return { perModel, total, currency: 'CNY', source: 'builtin-estimate' }
}

function renderCost(cost) {
  return `¥${cost.total.toFixed(4)}（内置估算价，非账单）`
}

export function renderAgentReport(result) {
  const s = result.summary
  const c = result.cost
  const coverage = result.coverage
  const lines = []
  lines.push(`# DSH Agent 报告（${result.status}）`)
  lines.push('')
  lines.push(`- 区间：${new Date(result.range.from).toISOString()} → ${new Date(result.range.to).toISOString()}`)
  lines.push(`- 数据源：${result.sourceKind === 'session-query' ? 'SessionQuery（持久化 + 当前会话）' : result.sourceKind === 'live-sessions' ? 'ctx.sessions（仅当前内存会话）' : result.sourceKind === 'redacted-document' ? '明确提供的脱敏 Session JSON' : '未连接'}`)
  lines.push(`- 覆盖：列出 ${formatNumber(coverage.listedSessions)} 个会话，读取 ${formatNumber(coverage.readSessions)} 个，使用 ${formatNumber(coverage.eventsUsed)} 条事件`)
  if (coverage.readFailures > 0 || coverage.truncated) lines.push('- 注意：部分会话读取失败或达到有界扫描上限，下面的数字是部分覆盖，不能当作完整账单。')
  lines.push('')
  lines.push('## 一句话结论')
  lines.push('')
  lines.push(`本区间有 **${formatNumber(s.sessions)}** 个会话、**${formatNumber(s.turns)}** 个回合，产生 **${formatNumber(s.toolCallsTotal)}** 次工具调用；Token 约 **${formatTokens(s.tokens.input + s.tokens.output + s.tokens.cacheRead + s.tokens.cacheWrite + s.tokens.reasoning)}**，费用约 **${renderCost(c)}**。`)
  lines.push('')
  lines.push('## Token 与成本')
  lines.push('')
  lines.push(`- 输入 ${formatTokens(s.tokens.input)} · 输出 ${formatTokens(s.tokens.output)} · 缓存命中 ${formatTokens(s.tokens.cacheRead)} · 缓存写入 ${formatTokens(s.tokens.cacheWrite)} · 思考 ${formatTokens(s.tokens.reasoning)}`)
  lines.push(`- 费用：${renderCost(c)}；当前只使用本地内置价格，未知模型按 flash 档估算。`)
  const models = Object.entries(s.models).sort((a, b) => costOfUsage(b[1], b[0]) - costOfUsage(a[1], a[0])).slice(0, 8)
  if (models.length) {
    lines.push('')
    lines.push('| 模型 | 输入 | 输出 | 缓存命中 | 缓存写入 | 思考 | 估算费用 |')
    lines.push('| --- | ---: | ---: | ---: | ---: | ---: | ---: |')
    for (const [model, usage] of models) lines.push(`| ${model} | ${formatTokens(usage.input)} | ${formatTokens(usage.output)} | ${formatTokens(usage.cacheRead)} | ${formatTokens(usage.cacheWrite)} | ${formatTokens(usage.reasoning)} | ¥${costOfUsage(usage, model).toFixed(4)} |`)
  }
  lines.push('')
  lines.push('## 工具调用与异常')
  lines.push('')
  lines.push(`- 工具调用 ${formatNumber(s.toolCallsTotal)} 次；命令 ${formatNumber(s.commands)} 条；工具失败 ${formatNumber(s.toolErrors)} 次。`)
  lines.push(`- 回合失败 ${formatNumber(s.turnFailures)} 次；中止 ${formatNumber(s.turnAborts)} 次；中断 ${formatNumber(s.turnInterruptions)} 次。`)
  lines.push(`- 重试风暴 ${formatNumber(s.retryBursts)} 次（同一命令连续重复至少 3 次）。`)
  const tools = Object.entries(s.toolCalls).sort((a, b) => b[1] - a[1]).slice(0, 10)
  if (tools.length) lines.push(`- 常用工具：${tools.map(([name, count]) => `\`${name}\` × ${formatNumber(count)}`).join('、')}`)
  lines.push('')
  lines.push('## 风险')
  lines.push('')
  lines.push('- 风险项只来自 Session 事件中的命令文本线索，不代表 Debug 插件执行了这些命令。')
  lines.push(`- 危险操作 ${formatNumber(s.dangerous.total)} 条：红级 ${formatNumber(s.dangerous.red)}，黄级 ${formatNumber(s.dangerous.amber)}。`)
  if (Object.keys(s.dangerous.byLabel).length) lines.push(`- 风险类型：${Object.entries(s.dangerous.byLabel).map(([label, count]) => `${label} × ${formatNumber(count)}`).join('、')}`)
  lines.push(`- 疑似密钥/令牌命中 ${formatNumber(s.secrets.total)} 次（只统计类型，不展示原文）。`)
  if (Object.keys(s.secrets.byLabel).length) lines.push(`- 命中类型：${Object.entries(s.secrets.byLabel).map(([label, count]) => `${label} × ${formatNumber(count)}`).join('、')}`)
  lines.push('')
  lines.push('## 费用最高的会话（仅显示脱敏短 ID）')
  lines.push('')
  const sessions = [...s.sessionsDetail].sort((a, b) => b.cost - a.cost).slice(0, 5)
  if (!sessions.length) lines.push('没有可展示的会话明细。')
  else for (const session of sessions) lines.push(`- \`${safeSessionId(session.sessionId)}\`：¥${session.cost.toFixed(4)} · ${formatNumber(session.events)} 事件 · ${formatNumber(session.toolCalls)} 工具 · ${formatNumber(session.toolErrors)} 失败 · ${formatNumber(session.dangerCount)} 风险`)
  lines.push('')
  lines.push('---')
  lines.push('*报告由本地确定性代码生成，0 token；只读，不执行命令，不写回 Session，不读取凭据。*')
  return lines.join('\n')
}

export async function generateAgentReport({ source, preset = 'weekly', from, to, now = Date.now() }) {
  const range = resolveAgentReportRange(preset, from, to, now)
  const collected = await collectAgentReportEvents(source, range)
  if (!collected.available) {
    const result = {
      schemaVersion: AGENT_REPORT_SCHEMA_VERSION,
      status: 'UNAVAILABLE',
      sourceKind: collected.sourceKind,
      range,
      coverage: collected.coverage,
      summary: emptyAggregate(range),
      cost: { perModel: {}, total: 0, currency: 'CNY', source: 'builtin-estimate' },
    }
    result.report = '# DSH Agent 报告（UNAVAILABLE）\n\n当前 Host 没有可读取的 Session 服务，或会话源读取失败。没有执行任何命令，也没有修改任何数据。'
    return result
  }
  const summary = aggregateAgentReportEvents(collected, range)
  const cost = computeAgentReportCost(summary.models)
  for (const detail of summary.sessionsDetail) {
    detail.cost = Object.entries(detail.modelTokens).reduce((total, [model, usage]) => total + costOfUsage(usage, model), 0)
  }
  const result = {
    schemaVersion: AGENT_REPORT_SCHEMA_VERSION,
    status: collected.coverage.readFailures > 0 || collected.coverage.truncated ? 'PARTIAL' : 'PASS',
    sourceKind: collected.sourceKind,
    range,
    coverage: collected.coverage,
    summary,
    cost,
  }
  result.report = renderAgentReport(result)
  return result
}

export function createLiveSessionsReportSource(sessions) {
  return {
    kind: 'live-sessions',
    async listSessions() {
      return sessions.list().map(session => ({ header: session.header, live: true }))
    },
    async readSession(id) {
      const session = sessions.list().find(item => sessionIdOf(item.header) === String(id))
      if (!session) throw new Error('session unavailable')
      return { session: session.header, events: session.events }
    },
  }
}

/**
 * Create a bounded, read-only report source from one explicitly supplied
 * redacted JSON document.  It never discovers DSH_HOME/Profile files and it
 * never exposes the document's raw IDs or event payloads to the report.
 */
export function createAgentReportDocumentSource(document) {
  const sessions = normalizeAgentReportDocument(document)
  return {
    kind: 'redacted-document',
    async listSessions() {
      return sessions.map(({ header }) => ({ header: structuredClone(header), offline: true }))
    },
    async readSession(id) {
      const session = sessions.find(item => item.header.id === String(id))
      if (!session) throw new Error('脱敏 Session 文档中不存在请求的 Session')
      return { session: structuredClone(session.header), events: structuredClone(session.events) }
    },
  }
}

export async function generateAgentReportFromDocument(document, options = {}) {
  return generateAgentReport({ ...options, source: createAgentReportDocumentSource(document) })
}
