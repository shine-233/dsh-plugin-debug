import { checkRepository, getCheckSchema, scanRepositories, REPORT_SCHEMA_VERSION } from './repository-check.js'
import { inspectHotswapCapabilities } from './hotswap-check.js'
import { registerAgentReportTool, registerPluginCheckTool, registerPluginHotswapCheckTool } from './tool-adapter.js'
import { createLiveSessionsReportSource, generateAgentReport } from './agent-report.js'
import { registerTaskGuardian } from './task-guardian.js'

// The debug bundle is intentionally standalone.  DSH hosts that expose a
// richer `defineTool` helper may still normalize this object at registration
// time, but installing the plugin must not require a private host package just
// to run the read-only policy and client diagnostics.
const defineTool = (definition) => definition

export const name = 'dsh-plugin-debug'
// The Guardian observes agent/session events when the Host exposes them, but
// their absence must not prevent the rest of the read-only debug bundle from
// loading on older or reduced DSH Hosts.
export const inject = ['tools']

const VALID_DECISIONS = new Set(['allow', 'ask', 'deny'])
const DEFAULT_DANGEROUS_TOOL_PATTERNS = [
  'bash',
  'pwsh',
  'shell',
  'terminal*',
  'run_code',
]

function asRecord(value) {
  return value && typeof value === 'object' && !Array.isArray(value) ? value : {}
}

function wildcardMatch(pattern, value) {
  if (typeof pattern !== 'string' || pattern.length === 0) return true
  const escaped = pattern.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*').replace(/\?/g, '.')
  return new RegExp(`^${escaped}$`, 'i').test(String(value ?? ''))
}

function getJsonPointer(value, pointer) {
  if (pointer === '' || pointer === '/') return value
  if (typeof pointer !== 'string' || !pointer.startsWith('/')) return undefined
  return pointer.slice(1).split('/').reduce((current, segment) => {
    if (current === null || current === undefined) return undefined
    const key = segment.replace(/~1/g, '/').replace(/~0/g, '~')
    return current[key]
  }, value)
}

function toolArguments(exec) {
  return asRecord(exec?.arguments)
}

function sandboxPermission(exec) {
  const args = toolArguments(exec)
  return args.sandbox_permissions ?? args.sandboxPermissions
}

function ruleMatches(rule, exec) {
  const candidate = asRecord(rule)
  if (!wildcardMatch(candidate.tool, exec?.name)) return false
  if (candidate.permission !== undefined && candidate.permission !== sandboxPermission(exec)) return false
  const when = asRecord(candidate.when)
  if (when.pointer !== undefined && getJsonPointer(toolArguments(exec), when.pointer) !== when.equals) return false
  return true
}

export function normalizeToolPolicyConfig(input = {}) {
  const outer = asRecord(input)
  const source = asRecord(outer.toolPolicy ?? outer)
  const defaultDecision = VALID_DECISIONS.has(source.defaultDecision) ? source.defaultDecision : 'allow'
  const rules = Array.isArray(source.rules)
    ? source.rules.filter((rule) => rule && typeof rule === 'object').map((rule) => ({ ...rule }))
    : []
  const dangerousToolPatterns = Array.isArray(source.dangerousToolPatterns) && source.dangerousToolPatterns.length > 0
    ? source.dangerousToolPatterns.filter((pattern) => typeof pattern === 'string')
    : DEFAULT_DANGEROUS_TOOL_PATTERNS
  return {
    enabled: source.enabled === true,
    defaultDecision,
    rules,
    protectDangerousShell: source.protectDangerousShell !== false,
    dangerousToolPatterns,
  }
}

export function decideToolCall(config, exec) {
  const policy = normalizeToolPolicyConfig(config)
  if (!policy.enabled) return { kind: 'allow', reason: 'tool policy disabled' }

  let matchedRule = null
  for (const rule of policy.rules) {
    if (!ruleMatches(rule, exec)) continue
    matchedRule = rule
    break
  }

  const permission = sandboxPermission(exec)
  const isDangerousShell = permission === 'danger-full-access' && policy.dangerousToolPatterns.some((pattern) => wildcardMatch(pattern, exec?.name))
  if (isDangerousShell && policy.protectDangerousShell && matchedRule?.decision !== 'deny') {
    return {
      kind: 'ask',
      reason: 'danger-full-access shell call requires explicit approval',
      matchedRule: matchedRule ?? undefined,
    }
  }

  const decision = matchedRule?.decision ?? policy.defaultDecision
  if (!VALID_DECISIONS.has(decision)) return { kind: 'deny', reason: 'invalid tool policy decision' }
  return {
    kind: decision,
    reason: matchedRule?.reason ?? `tool policy decision: ${decision}`,
    matchedRule: matchedRule ?? undefined,
  }
}

// This is an opt-in Host-side policy seam. The browser provenance UI remains
// independent of it, and the external launcher remains responsible for
// crashes, file recovery, and Profile mutation. With no config, this hook is a
// strict no-op so installing the bundle cannot silently change tool behavior.
export function apply(ctx, config = {}) {
  let sessionQuery = null
  let sessions = null
  if (typeof ctx?.inject === 'function') {
    ctx.inject(['sessionQuery'], child => {
      sessionQuery = child.sessionQuery
    })
    ctx.inject(['sessions'], child => {
      sessions = child.sessions
    })
  }
  if (ctx?.tools?.register) {
    registerPluginCheckTool(ctx, {
      defineTool,
      checker: {
        check: checkRepository,
        scan: scanRepositories,
        schema: getCheckSchema,
      },
    })
    registerPluginHotswapCheckTool(ctx, {
      defineTool,
      probe: ({ pluginId }) => inspectHotswapCapabilities({ context: ctx, targetId: pluginId }),
    })
    registerAgentReportTool(ctx, {
      defineTool,
      getSource: () => {
        if (sessionQuery && typeof sessionQuery.listSessions === 'function' && typeof sessionQuery.readSession === 'function') {
          return {
            kind: 'session-query',
            listSessions: signal => sessionQuery.listSessions(signal),
            readSession: sessionId => sessionQuery.readSession(sessionId),
          }
        }
        if (sessions && typeof sessions.list === 'function') return createLiveSessionsReportSource(sessions)
        return null
      },
      generate: generateAgentReport,
    })
  }
  registerTaskGuardian(ctx, asRecord(config).guardian)
  const policy = normalizeToolPolicyConfig(config)
  if (!policy.enabled || !ctx || typeof ctx.on !== 'function') return
  ctx.on('tools/pre-execute', (exec, next) => {
    const decision = decideToolCall(policy, exec)
    if (decision.kind === 'allow') return next()
    return decision
  }, { prepend: true })
}

export { checkRepository, getCheckSchema, scanRepositories, REPORT_SCHEMA_VERSION }
export { HOTSWAP_CHECK_SCHEMA_VERSION, getHotswapCheckSchema, inspectHotswapCapabilities } from './hotswap-check.js'
export { AGENT_REPORT_SCHEMA_VERSION, AGENT_REPORT_PRESETS, aggregateAgentReportEvents, computeAgentReportCost, generateAgentReport, resolveAgentReportRange } from './agent-report.js'
export { GUARDIAN_STATUS_PATH, guardianToolFingerprint, normalizeGuardianConfig, registerTaskGuardian } from './task-guardian.js'
