const MAX_ENTRIES = 100
const MAX_TEXT_LENGTH = 180
const MAX_ANCESTORS = 32

export const HOTSWAP_CHECK_SCHEMA_VERSION = 1
export const HOTSWAP_VERDICTS = Object.freeze([
  'SUPPORTED',
  'PARTIAL',
  'UNAVAILABLE',
  'MANUAL_REVIEW',
])

const REQUIRED_OPERATIONS = Object.freeze([
  Object.freeze({ name: 'entry.update', aliases: ['entry.update', 'update'] }),
  Object.freeze({ name: 'entry.dispose', aliases: ['entry.dispose', 'dispose'] }),
  Object.freeze({ name: 'entry.refresh', aliases: ['entry.refresh', 'refresh'] }),
])

const CORE_NAMES = new Set([
  'api-gateway',
  'connection',
  'dsh-plugin-debug',
  'llm',
  'modules',
  'permission',
  'session',
  'tools',
  'typert',
  'web',
  'web-client',
  'webserver',
  'web-server',
])

export const HOTSWAP_CHECK_SCHEMA = Object.freeze([
  { code: 'inventory-unavailable', severity: 'error', description: 'the Host did not expose a readable plugin inventory' },
  { code: 'inventory-read-failed', severity: 'error', description: 'the Host plugin inventory could not be read without executing a lifecycle action' },
  { code: 'lifecycle-contract-missing', severity: 'error', description: 'the Host did not declare a stable public plugin lifecycle contract' },
  { code: 'lifecycle-contract-not-authoritative', severity: 'error', description: 'the declared lifecycle contract is not marked as an authoritative DSH Host contract' },
  { code: 'lifecycle-contract-not-stable', severity: 'error', description: 'the declared lifecycle contract is not explicitly marked stable' },
  { code: 'lifecycle-contract-unversioned', severity: 'error', description: 'the declared lifecycle contract has no explicit version that can be audited' },
  { code: 'lifecycle-contract-incomplete', severity: 'warning', description: 'the declared lifecycle contract is missing required operations or safety guarantees' },
  { code: 'internal-api-not-contract', severity: 'warning', description: 'internal loader methods were observed but are not evidence of a supported hot swap contract' },
  { code: 'official-hmr-not-action-contract', severity: 'info', description: 'the official HMR service was observed but it does not authorize this tool to mutate plugin entries' },
  { code: 'target-not-found', severity: 'error', description: 'the requested plugin id or name was not present in the observed inventory' },
  { code: 'target-ambiguous', severity: 'warning', description: 'the requested plugin name matched more than one inventory entry' },
  { code: 'protected-entry', severity: 'error', description: 'the target is a protected DSH core or Debug entry' },
  { code: 'runtime-only-entry', severity: 'error', description: 'the target is marked runtime-only and needs an explicit host-specific review' },
  { code: 'ancestor-disabled', severity: 'error', description: 'an owning ancestor is disabled; changing the child would not be an isolated operation' },
  { code: 'dynamic-disabled-expression', severity: 'error', description: 'disabled state uses a dynamic !!js expression and cannot be evaluated by this read-only probe' },
  { code: 'target-disabled', severity: 'warning', description: 'the target is already disabled in its declared entry options' },
  { code: 'target-identity-missing', severity: 'warning', description: 'the observed entry has neither a stable id nor a module name' },
].map(item => Object.freeze({ ...item })))

function asRecord(value) {
  return value && typeof value === 'object' && !Array.isArray(value) ? value : null
}

function safeRead(object, key) {
  if (object === null || object === undefined) return undefined
  try {
    return object[key]
  } catch {
    return undefined
  }
}

function safeCall(object, method, ...args) {
  const fn = safeRead(object, method)
  if (typeof fn !== 'function') return { ok: false, value: undefined }
  try {
    return { ok: true, value: fn.call(object, ...args) }
  } catch (error) {
    return { ok: false, value: undefined, error }
  }
}

function text(value, fallback = null) {
  if (typeof value !== 'string' && typeof value !== 'number') return fallback
  const result = String(value).trim()
  if (!result) return fallback
  return result.slice(0, MAX_TEXT_LENGTH)
}

function booleanValue(value) {
  return value === true || value === false ? value : undefined
}

function isJsExpression(value) {
  if (typeof value === 'function') return true
  if (typeof value === 'string') return /^!!js(?:[/:]|\s|$)/i.test(value.trim())
  const candidate = asRecord(value)
  return (typeof candidate?.__jsExpr === 'string' && candidate.__jsExpr.trim() !== '')
    || (typeof candidate?.type === 'string' && candidate.type.toLowerCase() === 'js')
}

function optionsOf(entry) {
  return asRecord(safeRead(entry, 'options')) ?? {}
}

function readBoolean(entry, options, key) {
  const direct = booleanValue(safeRead(entry, key))
  if (direct !== undefined) return direct
  return booleanValue(safeRead(options, key))
}

function readFlag(entry, options, metadata, key, aliases = []) {
  for (const candidate of [key, ...aliases]) {
    const direct = booleanValue(safeRead(entry, candidate))
    if (direct !== undefined) return direct
    const option = booleanValue(safeRead(options, candidate))
    if (option !== undefined) return option
    const meta = booleanValue(safeRead(metadata, candidate))
    if (meta !== undefined) return meta
  }
  return false
}

function normalizeKey(value) {
  return text(value, '')
    .toLowerCase()
    .replace(/\\/g, '/')
    .replace(/\s+/g, '-')
}

function isCoreIdentity(id, name) {
  for (const value of [id, name]) {
    const normalized = normalizeKey(value)
    if (!normalized) continue
    if (CORE_NAMES.has(normalized)) return true
    // DSH core modules are commonly represented by their package name rather
    // than a short loader id. Keep the whole official namespace protected;
    // this probe is read-only today, but a future opt-in action must not be
    // able to mistake an @deepseek-ai/* entry for a third-party plugin.
    if (normalized.startsWith('@deepseek-ai/')) return true
    // Bundle/include rows are host-owned composition entries. Their concrete
    // child may be unknown to a static probe, so fail closed instead of
    // presenting an include row as an isolated hot-swap candidate.
    if (normalized.startsWith('include:')) return true
    if (normalized.startsWith('dsh-plugin-debug:')) return true
    if (normalized.startsWith('typert:') || normalized.startsWith('typert-')) return true
  }
  return false
}

function getOwningAncestors(entry) {
  const explicit = safeRead(entry, 'ancestors')
  if (Array.isArray(explicit)) return explicit.slice(0, MAX_ANCESTORS)

  const result = []
  const seen = new Set()
  let current = entry
  while (result.length < MAX_ANCESTORS) {
    const parent = safeRead(current, 'parent')
    const parentContext = safeRead(parent, 'ctx')
    const parentFiber = safeRead(parentContext, 'fiber')
    const ancestor = safeRead(parentFiber, 'entry')
    if (!ancestor || seen.has(ancestor)) break
    seen.add(ancestor)
    result.push(ancestor)
    current = ancestor
  }
  return result
}

function describeEntry(entry, index) {
  const raw = asRecord(entry) ?? {}
  const options = optionsOf(entry)
  const metadata = asRecord(safeRead(entry, 'metadata')) ?? asRecord(safeRead(options, 'metadata')) ?? {}
  const id = text(safeRead(raw, 'id') ?? safeRead(options, 'id') ?? safeRead(entry, 'id'))
  const name = text(safeRead(raw, 'name') ?? safeRead(options, 'name') ?? safeRead(entry, 'name'))
  const disabledValue = safeRead(raw, 'disabled') ?? safeRead(options, 'disabled')
  const dynamicDisabled = isJsExpression(disabledValue)
  const disabled = dynamicDisabled ? undefined : booleanValue(disabledValue)
  const runtimeOnly = readFlag(entry, options, metadata, 'runtimeOnly', ['runtime_only'])
  const explicitProtected = readFlag(entry, options, metadata, 'protected', ['core', 'protectedCore'])
  const core = explicitProtected || isCoreIdentity(id, name)
  const privateApisSeen = ['update', '_dispose', 'dispose', 'refresh']
    .filter(method => typeof safeRead(entry, method) === 'function')

  let ancestorDisabled = false
  let ancestorDynamicDisabled = false
  const ancestors = getOwningAncestors(entry)
  for (const ancestor of ancestors) {
    const ancestorOptions = optionsOf(ancestor)
    const ancestorDisabledValue = safeRead(ancestor, 'disabled') ?? safeRead(ancestorOptions, 'disabled')
    if (isJsExpression(ancestorDisabledValue)) ancestorDynamicDisabled = true
    else if (ancestorDisabledValue === true) ancestorDisabled = true
  }

  const riskCodes = []
  if (!id && !name) riskCodes.push('target-identity-missing')
  if (core) riskCodes.push('protected-entry')
  if (runtimeOnly) riskCodes.push('runtime-only-entry')
  if (ancestorDisabled) riskCodes.push('ancestor-disabled')
  if (ancestorDynamicDisabled || dynamicDisabled) riskCodes.push('dynamic-disabled-expression')
  if (disabled === true) riskCodes.push('target-disabled')

  return {
    index,
    id,
    name,
    disabled: disabled ?? (dynamicDisabled ? 'dynamic' : null),
    runtimeOnly,
    protected: core,
    ancestorDisabled,
    ancestorDynamicDisabled,
    dynamicDisabled,
    privateApisSeen,
    riskCodes,
    live: Boolean(safeRead(entry, 'fiber')),
  }
}

function resolveService(context, name) {
  const direct = safeRead(context, name)
  if (direct !== undefined) return direct
  const result = safeCall(context, 'get', name)
  return result.ok ? result.value : undefined
}

function resolveNested(object, path) {
  let current = object
  for (const key of path) {
    current = safeRead(current, key)
    if (current === undefined || current === null) return undefined
  }
  return current
}

function resolveLifecycleContract(context, supplied) {
  if (supplied !== undefined) return supplied
  const candidates = [
    resolveNested(context, ['capabilities', 'pluginLifecycle']),
    resolveNested(context, ['hostCapabilities', 'pluginLifecycle']),
    resolveNested(context, ['dsh', 'capabilities', 'pluginLifecycle']),
    resolveNested(context, ['host', 'capabilities', 'pluginLifecycle']),
  ]
  return candidates.find(candidate => candidate !== undefined) ?? undefined
}

function normalizeContract(input) {
  const source = asRecord(input)
  if (!source) {
    return {
      declared: false,
      stable: false,
      declaredStable: false,
      authoritative: false,
      version: null,
      operations: [],
      missingOperations: REQUIRED_OPERATIONS.map(item => item.name),
      missingSafety: ['serialQueue', 'coreProtection', 'rollback'],
      serialQueue: false,
      coreProtection: false,
      rollback: false,
      dryRun: false,
    }
  }

  const operations = []
  for (const value of [safeRead(source, 'operations'), safeRead(source, 'actions')]) {
    if (!Array.isArray(value)) continue
    for (const item of value) {
      const normalized = text(item, '')?.toLowerCase()
      if (normalized && !operations.includes(normalized)) operations.push(normalized)
    }
  }
  const hasOperation = aliases => aliases.some(alias => operations.includes(alias))
  const missingOperations = REQUIRED_OPERATIONS
    .filter(item => !hasOperation(item.aliases))
    .map(item => item.name)
  const serialQueue = safeRead(source, 'serialQueue') === true
  const coreProtection = safeRead(source, 'coreProtection') === true || safeRead(source, 'protectedCore') === true
  const rollback = safeRead(source, 'rollback') === true || safeRead(source, 'supportsRollback') === true
  const authoritative = safeRead(source, 'official') === true || ['dsh', 'dsh-host', 'deepseek-harness'].includes(String(safeRead(source, 'source') ?? '').toLowerCase())
  const declaredStable = safeRead(source, 'stable') === true
  const stable = declaredStable && authoritative
  const missingSafety = [
    ['serialQueue', serialQueue],
    ['coreProtection', coreProtection],
    ['rollback', rollback],
  ].filter(([, present]) => !present).map(([key]) => key)

  return {
    declared: true,
    stable,
    declaredStable,
    authoritative,
    version: text(safeRead(source, 'version')),
    operations,
    missingOperations,
    missingSafety,
    serialQueue,
    coreProtection,
    rollback,
    dryRun: safeRead(source, 'dryRun') === true || safeRead(source, 'supportsDryRun') === true,
  }
}

function collectInventory(context, supplied) {
  if (Array.isArray(supplied)) {
    return {
      observed: true,
      source: 'probe-input',
      entries: supplied.slice(0, MAX_ENTRIES).map(describeEntry),
      truncated: supplied.length > MAX_ENTRIES,
      error: null,
    }
  }

  const loader = resolveService(context, 'loader')
  const result = safeCall(loader, 'entries')
  const iteratorFactory = result.ok ? safeRead(result.value, Symbol.iterator) : undefined
  if (!result.ok || !result.value || typeof iteratorFactory !== 'function') {
    return {
      observed: false,
      source: 'host-loader',
      entries: [],
      truncated: false,
      error: result.error ? 'loader.entries threw while being observed' : 'Host loader.entries() is unavailable',
    }
  }

  const entries = []
  try {
    const iterator = iteratorFactory.call(result.value)
    let truncated = false
    for (let index = 0; index <= MAX_ENTRIES; index += 1) {
      const next = iterator.next()
      if (next.done) break
      if (index >= MAX_ENTRIES) {
        truncated = true
        break
      }
      entries.push(describeEntry(next.value, index))
    }
    return { observed: true, source: 'host-loader', entries, truncated, error: null }
  } catch {
    return {
      observed: false,
      source: 'host-loader',
      entries: [],
      truncated: false,
      error: 'Host loader.entries() returned an unreadable iterator',
    }
  }
}

function observeHmr(context, supplied) {
  const hmr = supplied ?? resolveService(context, 'hmr')
  if (!hmr || typeof hmr !== 'object') return { status: 'absent', methods: [] }
  const methods = ['getLinked', 'registerConfig'].filter(method => typeof safeRead(hmr, method) === 'function')
  return {
    status: methods.length > 0 ? 'present' : 'unknown',
    methods,
  }
}

function finding(code, detail = undefined) {
  const definition = HOTSWAP_CHECK_SCHEMA.find(item => item.code === code)
  return {
    code,
    severity: definition?.severity ?? 'warning',
    detail: detail ?? definition?.description ?? code,
  }
}

function safeTarget(entries, requested) {
  const target = text(requested)
  if (!target) return { requested: null, matches: [], entry: null }
  const normalized = normalizeKey(target)
  const matches = entries.filter(entry => normalizeKey(entry.id) === normalized || normalizeKey(entry.name) === normalized)
  return { requested: target, matches, entry: matches.length === 1 ? matches[0] : null }
}

function decideVerdict({ inventory, contract, target, findings }) {
  if (target.requested && target.matches.length === 0) return 'UNAVAILABLE'
  if (target.matches.length > 1 || target.entry?.riskCodes.length > 0) return 'MANUAL_REVIEW'
  if (!inventory.observed || !contract.declared) return 'UNAVAILABLE'
  if (!contract.authoritative || !contract.stable || !contract.version) return 'UNAVAILABLE'
  if (contract.missingOperations.length > 0 || contract.missingSafety.length > 0) return 'PARTIAL'
  if (!target.entry) return 'PARTIAL'
  if (findings.some(item => item.code === 'target-identity-missing')) return 'MANUAL_REVIEW'
  return 'SUPPORTED'
}

export function inspectHotswapCapabilities({
  context = undefined,
  inventory = undefined,
  lifecycleContract = undefined,
  hmr = undefined,
  targetId = undefined,
} = {}) {
  const observedInventory = collectInventory(context, inventory)
  const contract = normalizeContract(resolveLifecycleContract(context, lifecycleContract))
  const hmrObservation = observeHmr(context, hmr)
  const target = safeTarget(observedInventory.entries, targetId)
  const findings = []

  if (!observedInventory.observed) findings.push(finding(observedInventory.error?.includes('threw') ? 'inventory-read-failed' : 'inventory-unavailable', observedInventory.error))
  if (!contract.declared) findings.push(finding('lifecycle-contract-missing'))
  else {
    if (!contract.authoritative) findings.push(finding('lifecycle-contract-not-authoritative'))
    if (!contract.declaredStable) findings.push(finding('lifecycle-contract-not-stable'))
    if (!contract.version) findings.push(finding('lifecycle-contract-unversioned'))
  }
  if (contract.declared && contract.authoritative && contract.stable && contract.version
    && (contract.missingOperations.length > 0 || contract.missingSafety.length > 0)) {
    const missing = [...contract.missingOperations, ...contract.missingSafety]
    findings.push(finding('lifecycle-contract-incomplete', `public lifecycle contract is incomplete: ${missing.join(', ') || 'not marked stable/official'}`))
  }
  if (hmrObservation.status === 'present' && !contract.declared) findings.push(finding('official-hmr-not-action-contract'))
  if (observedInventory.entries.some(entry => entry.privateApisSeen.length > 0)) {
    findings.push(finding('internal-api-not-contract', 'loader entries expose internal lifecycle-shaped methods, but this probe never calls them and the Host has not authorized them'))
  }
  if (target.requested && target.matches.length === 0) findings.push(finding('target-not-found', `no observed plugin entry matched ${target.requested}`))
  if (target.matches.length > 1) findings.push(finding('target-ambiguous', `plugin name/id matched ${target.matches.length} entries`))
  if (target.entry) {
    for (const code of target.entry.riskCodes) findings.push(finding(code))
  }

  const verdict = decideVerdict({ inventory: observedInventory, contract, target, findings })
  return {
    schemaVersion: HOTSWAP_CHECK_SCHEMA_VERSION,
    action: 'plugin_hotswap_check',
    mode: 'capability-report-only',
    verdict,
    execution: 'NOT_ATTEMPTED',
    executionAttempted: false,
    executionVerified: false,
    actionsExecuted: [],
    readOnly: true,
    actualHotSwap: false,
    target: {
      requested: target.requested,
      matchCount: target.matches.length,
      entry: target.entry,
    },
    host: {
      inventory: {
        status: observedInventory.observed ? 'present' : 'unavailable',
        source: observedInventory.source,
        count: observedInventory.entries.length,
        truncated: observedInventory.truncated,
      },
      officialHmr: hmrObservation,
      lifecycleContract: contract,
      serialQueue: contract.serialQueue ? 'declared' : 'not-declared',
    },
    entries: observedInventory.entries,
    findings,
    limitations: [
      'This is a read-only capability report; it does not call entry.update(), dispose(), refresh(), _dispose(), loader.update(), or ESM/CJS cache eviction.',
      'SUPPORTED means the Host declared a stable, authoritative lifecycle contract and the selected entry passed metadata guards; no reload was attempted.',
      'An observed official HMR service is not itself permission to mutate a plugin entry or to rewrite a Profile patch.',
      'No package manager, shell, network request, Profile write, or plugin code execution is performed by this probe.',
    ],
    networkAccessed: false,
    commandsExecuted: false,
    targetMutated: false,
    mutations: {
      profile: false,
      dependencies: false,
      lifecycle: false,
    },
  }
}

export function getHotswapCheckSchema() {
  return HOTSWAP_CHECK_SCHEMA.map(item => ({ schemaVersion: HOTSWAP_CHECK_SCHEMA_VERSION, ...item }))
}
