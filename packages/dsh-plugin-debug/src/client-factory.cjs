const { createElement, useEffect, useState } = require('react')

const PLUGIN_ID = 'dsh-plugin-debug'
const NS = 'dsh.pluginProvenance'
const inject = ['slots', 'locale']
const STORAGE_KEY = `${PLUGIN_ID}.enabled`
const TOGGLE_EVENT = `${PLUGIN_ID}:toggle`
const DIAGNOSTICS_EVENT = `${PLUGIN_ID}:diagnostics`
const OPEN_DIAGNOSTICS_EVENT = `${PLUGIN_ID}:open-diagnostics`
const POINTER_EVENT = `${PLUGIN_ID}:pointer`
const STARTUP_GUARD_EVENT = `${PLUGIN_ID}:startup-guard`
const STARTUP_GUARD_QUERY = 'dsh_debug_guard'
const STARTUP_DIAGNOSTIC_STORAGE_PREFIX = `${PLUGIN_ID}.startup-diagnostic.v1`
const DEBUG_GLOBAL = '__DSH_PLUGIN_DEBUG__'
const LEGACY_PROVENANCE_GLOBAL = '__DSH_PLUGIN_PROVENANCE__'
const BRIDGE_SELECTOR = 'meta[data-dsh-debug-bridge="1"]'
const LEGACY_BRIDGE_SELECTOR = 'meta[data-dsh-provenance-bridge="1"]'
const REPORT_SCHEMA_VERSION = 5
const POINTER_OBSERVATION_SCHEMA_VERSION = 2
const CAPABILITY_SCHEMA_VERSION = 1
const ERROR_CAPTURE_PHASE = 'settings-mounted'
const MAX_REPORTED_ERRORS = 20
const MAX_REPORTED_CLUES = 30
const MAX_RUNTIME_ITEMS = 80
const MAX_RUNTIME_NODES = MAX_RUNTIME_ITEMS * 8
const MAX_SLOT_NODES = 300
const MAX_POINTER_ANCESTORS = 64
const clientErrors = []
const slotErrors = []
let errorCaptureInstalled = false
let errorCaptureStartedAt = null
let runtimeContext = null
let runtimeCleanup = null
let pluginInventoryState = 'not-observed'
let pluginInventoryEntries = []
let pluginInventoryError = null
let pluginInventoryRequest = 0
let currentPointerInfo = null
let bridgeElement = null
let startupGuardNotice = null
let startupDiagnosticState = { status: 'not-requested', sessionId: null, error: null }

function createOpaqueId(prefix) {
  try {
    const randomUuid = typeof globalThis !== 'undefined' && typeof globalThis.crypto?.randomUUID === 'function'
      ? globalThis.crypto.randomUUID()
      : null
    if (randomUuid) return `${prefix}-${randomUuid}`
  } catch {
    // A reduced browser realm may not expose crypto.randomUUID.
  }
  return `${prefix}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 12)}`
}

const PAGE_OBSERVATION_ID = createOpaqueId('page')

function readStartupGuardNotice() {
  if (typeof location === 'undefined') return null
  try {
    const rawSearch = String(location.search || '')
    const params = typeof URLSearchParams === 'function' ? new URLSearchParams(rawSearch) : null
    const value = params ? params.get(STARTUP_GUARD_QUERY) : (() => {
      const match = rawSearch.match(new RegExp(`[?&]${STARTUP_GUARD_QUERY}=([^&]*)`, 'u'))
      return match ? decodeURIComponent(match[1]) : null
    })()
    if (value !== 'isolated') return null
    return { kind: 'isolated', source: 'standalone-crash-guard' }
  } catch {
    return null
  }
}

startupGuardNotice = readStartupGuardNotice()

function getStartupDiagnosticState() {
  return { ...startupDiagnosticState }
}

function emitStartupGuardEvent() {
  if (typeof document === 'undefined' || typeof Event !== 'function') return
  try { document.dispatchEvent(new Event(STARTUP_GUARD_EVENT)) } catch { /* minimal DOM fixture */ }
}

function setStartupDiagnosticState(next) {
  startupDiagnosticState = { ...startupDiagnosticState, ...next }
  emitStartupGuardEvent()
  if (typeof document !== 'undefined') dispatchDiagnosticsEvent()
}

function startupDiagnosticEntries() {
  return pluginInventoryEntries
    .filter(entry => entry.enabled === false || entry.fiberPhase === 'failed')
    .slice(0, 8)
    .map(entry => ({
      moduleName: typeof entry.moduleName === 'string' ? entry.moduleName.slice(0, 160) : null,
      fiberPhase: typeof entry.fiberPhase === 'string' ? entry.fiberPhase : null,
      enabled: entry.enabled === true,
    }))
}

function startupDiagnosticMarker(notice, entries) {
  const names = entries.map(entry => entry.moduleName || 'unknown').sort().join(',')
  const page = typeof location !== 'undefined' && typeof location.pathname === 'string' ? location.pathname : '/'
  return `${STARTUP_DIAGNOSTIC_STORAGE_PREFIX}:${page}:${notice?.kind || 'unknown'}:${names}`.slice(0, 700)
}

function startupDiagnosticPrompt(entries) {
  const facts = entries.length === 0
    ? '安全隔离已发生，但当前页面没有可读取的插件清单。'
    : entries.map(entry => `${entry.moduleName || 'unknown'} (${entry.fiberPhase || (entry.enabled ? 'enabled' : 'disabled')})`).join(', ')
  return [
    'DSH Debug 启动故障诊断摘要。只使用下面的元数据，不读取原始日志、Tool 参数、Tool 结果、凭据或文件内容。',
    `Crash Guard 已隔离一个明确映射的第三方插件；可见条目：${facts}。`,
    '请只给出人工复核和恢复建议；该诊断会话必须保持 no-tools，不执行命令、不修改文件。',
  ].join('\n')
}

function dismissStartupGuardNotice() {
  startupGuardNotice = null
  if (typeof history !== 'undefined' && typeof history.replaceState === 'function' && typeof location !== 'undefined') {
    try {
      const url = new URL(location.href)
      url.searchParams.delete(STARTUP_GUARD_QUERY)
      history.replaceState(null, '', url.toString())
    } catch { /* a restricted browser URL must not break the diagnostics UI */ }
  }
  emitStartupGuardEvent()
}

async function maybeCreateStartupDiagnosticSession(ctx, notice = startupGuardNotice) {
  if (!notice || startupDiagnosticState.status === 'created' || startupDiagnosticState.status === 'creating') return getStartupDiagnosticState()
  const entries = startupDiagnosticEntries()
  const marker = startupDiagnosticMarker(notice, entries)
  try {
    if (typeof localStorage !== 'undefined' && localStorage.getItem(marker) === 'created') {
      setStartupDiagnosticState({ status: 'deduplicated' })
      return getStartupDiagnosticState()
    }
  } catch { /* localStorage may be unavailable */ }

  const sessions = optionalService(ctx, 'sessions')
  const policy = optionalService(ctx, 'diagnosticSessionPolicy')
  if (policy?.automatic !== true || policy?.mode !== 'no-tools' || typeof sessions?.create !== 'function') {
    setStartupDiagnosticState({ status: 'unavailable', error: 'Host did not advertise an automatic no-tools diagnostic-session policy.' })
    return getStartupDiagnosticState()
  }

  setStartupDiagnosticState({ status: 'creating', error: null })
  try {
    const sessionId = await sessions.create({})
    const binding = typeof sessions.binding === 'function' ? sessions.binding(sessionId) : null
    const session = binding?.session
    if (typeof session?.rename === 'function') await session.rename('DSH Debug 启动诊断')
    if (typeof session?.prompt !== 'function') throw new Error('created diagnostic session does not expose prompt')
    const result = await session.prompt([{ type: 'text', text: startupDiagnosticPrompt(entries) }], 'queue')
    if (!result?.ok) throw new Error(result?.error?.message || 'diagnostic prompt was not accepted')
    try { if (typeof localStorage !== 'undefined') localStorage.setItem(marker, 'created') } catch { /* best effort dedup */ }
    setStartupDiagnosticState({ status: 'created', sessionId: String(sessionId), error: null })
  } catch (error) {
    setStartupDiagnosticState({ status: 'error', error: redactSensitiveText(error?.message || String(error)).slice(0, 300) })
  }
  return getStartupDiagnosticState()
}

const zh = {
  tab: '鼠标溯源',
  title: '鼠标来源检查器',
  inspectorTab: '鼠标溯源',
  diagnosticsTab: '诊断',
  hint: '开启后，把鼠标移到 DSH 页面任意位置，即可查看当前节点能确认到的插件、模块和 Slot 来源。',
  enable: '开启鼠标溯源',
  disable: '关闭鼠标溯源',
  enabled: '已开启：移动鼠标即可查看来源。',
  disabled: '未开启：点击按钮后才会监听鼠标移动。',
  plugin: '插件',
  module: '模块',
  slot: 'Slot',
  evidence: '证据',
  node: '节点',
  unknown: '未知',
  titleOverlay: '插件 / 模块来源',
  unknownSource: '当前节点没有可确认的来源标记。',
  high: '高：明确的 data-dsh-plugin 标记',
  medium: '中：样式表中的插件/CSS 模块标记',
  low: '低：只有 data-slot 标记',
  none: '无：没有可靠的来源标记',
  nodeTypes: '来源证据等级',
  limitation: '说明：没有标记的通用 DOM 节点只能显示“未知”，插件内部代码不会被猜测。',
  diagnosticsTitle: 'DSH 客户端诊断',
  diagnosticsHint: '扫描当前浏览器页面的插件标记、样式来源、Slot 挂载线索和插件加载后的客户端错误。',
  rescan: '重新扫描',
  copyReport: '复制诊断报告',
  copied: '已复制',
  copyFailed: '复制失败，请查看下方报告',
  downloadReport: '下载 JSON',
  downloaded: '已下载',
  downloadFailed: '下载失败，请查看下方报告',
  clearErrors: '清空客户端错误',
  runtime: '运行环境',
  page: '页面',
  moduleLoader: 'ModuleLoader',
  moduleSystem: '客户端模块系统',
  slotRegistry: 'Slot Registry',
  hostStatus: 'Host 状态',
  modelRoute: '当前模型路由',
  permissionStatus: '权限状态',
  permissionDefault: '默认权限预设',
  sandboxMode: '沙箱模式',
  approvalPolicy: '审批策略',
  sessionStatus: '当前 Session',
  toolCalls: 'Tool Call',
  pointerEvidence: 'Pointer observation',
  present: '已发现',
  missing: '未发现',
  unavailable: '不可用',
  counts: '页面计数',
  pluginMarkers: '插件标记',
  moduleMarkers: '模块标记',
  slotMarkers: 'Slot 标记',
  styleNodes: '带来源的样式节点',
  cssClasses: 'CSS class 来源数',
  cssConflicts: 'CSS 来源冲突',
  markerConflicts: 'DOM/CSS 标记冲突',
  slotHints: '重复 Slot 挂载线索',
  moduleOwnershipClues: '同名模块多插件线索',
  clientErrors: '客户端错误',
  cluesTitle: '待复核线索',
  noConflicts: '暂未发现明确的冲突线索。',
  noErrors: '暂未捕获客户端 error 或 unhandledrejection。',
  conflictHint: '这些是诊断线索，不等于已经证明插件有 bug；同一个 CSS class 被多个来源声明时尤其值得检查。',
  clientErrorHint: '这里只记录插件加载后浏览器端的 error/unhandledrejection，不包含 DSH Host 或远程 Agent 的完整日志。',
  toolCallBoundary: 'Tool Call 边界',
  toolCallHint: 'Tool Call 失败通常发生在 Host、Agent、权限或远程 API 层。本 Client 插件目前只报告浏览器端线索，不会伪造“Tool Call 已诊断”。',
  toolCallDetails: 'Tool Call 只读摘要',
  noSession: '当前没有打开的 Session，暂时没有可观察的 Tool Call。',
  noToolCallErrors: '当前 Session 尚未观察到 Tool Call 错误。',
  runningToolCall: '已看到调用，但尚未收到对应 result；这不是自动证明失败。',
  slotErrors: 'Slot 渲染错误',
  noSlotErrors: '暂未捕获 Slot entry 渲染错误。',
  pluginInventory: 'Host 插件清单',
  dynamicCordis: '动态 Cordis 插件',
  runtimeSignals: '运行时信号',
  runningCalls: '进行中的 Tool Call',
  toolResultErrors: 'Tool Result 错误',
  turnErrors: 'Turn / Agent 错误',
  loadedPackages: '已加载动态插件',
  failedPlugins: '失败插件',
  runtimeFailureHint: '这些来自 DSH 官方只读运行时接口；它们能定位失败边界，但不会自动断言因果关系。',
  reportPrivacy: '报告只保留脱敏后的错误摘要，不读取 Cookie、Token、请求正文或 Tool Call 参数；错误文本仍可能包含业务信息，请分享前人工检查。',
  reportPreview: '报告预览',
  startupGuardTitle: '启动保护通知',
  startupGuardMessage: '启动时发现一个明确映射的第三方插件异常，Crash Guard 已生成可逆隔离并重启 DSH。',
  startupGuardOpen: '打开诊断',
  startupGuardDismiss: '关闭通知',
  startupDiagnosticPending: '正在准备诊断会话',
  startupDiagnosticCreated: '诊断会话已创建',
  startupDiagnosticUnavailable: '未创建：Host 未声明 no-tools 安全策略',
  startupDiagnosticDeduplicated: '已跳过：本次故障已创建过诊断会话',
  startupDiagnosticError: '诊断会话创建失败',
}

const en = {
  tab: 'Pointer provenance',
  title: 'Pointer source inspector',
  inspectorTab: 'Pointer inspector',
  diagnosticsTab: 'Diagnostics',
  hint: 'Enable it, then move the pointer over any part of DSH to inspect the plugin, module, and Slot source that can be confirmed.',
  enable: 'Enable pointer inspector',
  disable: 'Disable pointer inspector',
  enabled: 'Enabled: move the pointer to inspect a source.',
  disabled: 'Disabled: pointer events are not monitored until you enable it.',
  plugin: 'Plugin',
  module: 'Module',
  slot: 'Slot',
  evidence: 'Evidence',
  node: 'Node',
  unknown: 'Unknown',
  titleOverlay: 'Plugin / module provenance',
  unknownSource: 'This node has no source marker that can be confirmed.',
  high: 'High: explicit data-dsh-plugin marker',
  medium: 'Medium: plugin/CSS module marker from a stylesheet',
  low: 'Low: data-slot marker only',
  none: 'None: no reliable source marker',
  nodeTypes: 'Evidence levels',
  limitation: 'Limitation: an unmarked DOM node is reported as unknown; the inspector does not guess private plugin code.',
  diagnosticsTitle: 'DSH client diagnostics',
  diagnosticsHint: 'Scan plugin markers, stylesheet sources, Slot mount clues, and client errors observed after this plugin loaded.',
  rescan: 'Rescan',
  copyReport: 'Copy diagnostic report',
  copied: 'Copied',
  copyFailed: 'Copy failed; inspect the report below',
  downloadReport: 'Download JSON',
  downloaded: 'Downloaded',
  downloadFailed: 'Download failed; inspect the report below',
  clearErrors: 'Clear client errors',
  runtime: 'Runtime',
  page: 'Page',
  moduleLoader: 'ModuleLoader',
  moduleSystem: 'Client module system',
  slotRegistry: 'Slot Registry',
  hostStatus: 'Host status',
  modelRoute: 'Model route',
  permissionStatus: 'Permission status',
  permissionDefault: 'Default permission preset',
  sandboxMode: 'Sandbox mode',
  approvalPolicy: 'Approval policy',
  sessionStatus: 'Current session',
  toolCalls: 'Tool Calls',
  pointerEvidence: 'Pointer observation',
  present: 'Present',
  missing: 'Missing',
  unavailable: 'Unavailable',
  counts: 'Page counts',
  pluginMarkers: 'Plugin markers',
  moduleMarkers: 'Module markers',
  slotMarkers: 'Slot markers',
  styleNodes: 'Attributed style nodes',
  cssClasses: 'CSS class sources',
  cssConflicts: 'CSS source conflicts',
  markerConflicts: 'DOM/CSS marker conflicts',
  slotHints: 'Duplicate Slot mount clues',
  moduleOwnershipClues: 'Same-module multi-plugin clues',
  clientErrors: 'Client errors',
  cluesTitle: 'Clues to review',
  noConflicts: 'No clear conflict clues found.',
  noErrors: 'No client error or unhandledrejection captured yet.',
  conflictHint: 'These are diagnostic clues, not proof of a bug; a CSS class with multiple sources deserves review.',
  clientErrorHint: 'This records browser error/unhandledrejection events after the plugin loaded, not complete DSH Host or remote Agent logs.',
  toolCallBoundary: 'Tool Call boundary',
  toolCallHint: 'Tool Call failures usually happen in the Host, Agent, permission, or remote API layer. This Client plugin reports browser clues only and does not claim to diagnose Tool Calls.',
  toolCallDetails: 'Read-only Tool Call summary',
  noSession: 'No session is open, so there is no Tool Call snapshot to observe yet.',
  noToolCallErrors: 'No Tool Call error has been observed in the current session.',
  runningToolCall: 'A call was observed without its result; this does not prove failure by itself.',
  slotErrors: 'Slot render errors',
  noSlotErrors: 'No Slot entry render error captured yet.',
  pluginInventory: 'Host plugin inventory',
  dynamicCordis: 'Dynamic Cordis plugins',
  runtimeSignals: 'Runtime signals',
  runningCalls: 'Running Tool Calls',
  toolResultErrors: 'Tool result errors',
  turnErrors: 'Turn / Agent errors',
  loadedPackages: 'Loaded dynamic packages',
  failedPlugins: 'Failed plugins',
  runtimeFailureHint: 'These facts come from DSH read-only runtime interfaces; they locate the failure boundary without claiming causality.',
  reportPrivacy: 'The report keeps only redacted client-error summaries. It does not read cookies, tokens, request bodies, or Tool Call arguments; error text may still contain business data, so review it before sharing.',
  reportPreview: 'Report preview',
  startupGuardTitle: 'Startup guard notice',
  startupGuardMessage: 'A mapped third-party plugin failed during startup. Crash Guard created a reversible quarantine and restarted DSH.',
  startupGuardOpen: 'Open diagnostics',
  startupGuardDismiss: 'Dismiss notice',
  startupDiagnosticPending: 'Preparing a diagnostic session',
  startupDiagnosticCreated: 'Diagnostic session created',
  startupDiagnosticUnavailable: 'Not created: Host did not advertise a no-tools safety policy',
  startupDiagnosticDeduplicated: 'Skipped: this incident already has a diagnostic session',
  startupDiagnosticError: 'Diagnostic session creation failed',
}

function readEnabled() {
  if (typeof window === 'undefined') return false
  try {
    return window.localStorage.getItem(STORAGE_KEY) === '1'
  } catch {
    return false
  }
}

function setEnabled(enabled) {
  if (typeof window === 'undefined' || typeof document === 'undefined') return
  try {
    window.localStorage.setItem(STORAGE_KEY, enabled ? '1' : '0')
  } catch {
    // A read-only storage area should not make the inspector unusable.
  }
  if (typeof Event === 'function') document.dispatchEvent(new Event(TOGGLE_EVENT))
  updateBridgeElement(currentPointerInfo)
}

function clonePointerInfo(info) {
  if (!info || typeof info !== 'object') return null
  return {
    ...info,
    sources: Array.isArray(info.sources) ? info.sources.map(source => ({ ...source })) : [],
  }
}

function getBridgeElement() {
  if (typeof document === 'undefined') return null
  if (bridgeElement && bridgeElement.isConnected !== false) return bridgeElement
  try {
    bridgeElement = document.querySelector?.(BRIDGE_SELECTOR) || document.querySelector?.(LEGACY_BRIDGE_SELECTOR) || null
    if (!bridgeElement && typeof document.createElement === 'function') {
      bridgeElement = document.createElement('meta')
      bridgeElement.setAttribute('data-dsh-debug-bridge', '1')
      ;(document.head || document.documentElement)?.appendChild(bridgeElement)
    }
  } catch {
    bridgeElement = null
  }
  return bridgeElement
}

function updateBridgeElement(info) {
  const element = getBridgeElement()
  if (!element?.setAttribute) return
  const set = (name, value) => {
    if (value === null || value === undefined || value === '') element.removeAttribute?.(name)
    else element.setAttribute(name, truncateText(value, 240))
  }
  element.setAttribute('data-plugin-id', PLUGIN_ID)
  element.setAttribute('data-api-version', '1')
  element.setAttribute('data-pointer-event', POINTER_EVENT)
  element.setAttribute('data-enabled', readEnabled() ? '1' : '0')
  set('data-observation-id', info?.observationId)
  set('data-page-observation-id', info?.pageObservationId || PAGE_OBSERVATION_ID)
  set('data-observed-at', info?.observedAt)
  set('data-current-plugin', info?.plugin)
  set('data-current-module', info?.module)
  set('data-current-slot', info?.slot)
  set('data-current-evidence', info?.evidence)
  set('data-current-confidence', info?.confidence)
  set('data-current-node', info?.node)
  set('data-current-observation-id', info?.observationId)
  set('data-current-page-observation-id', info?.pageObservationId || PAGE_OBSERVATION_ID)
  set('data-current-observed-at', info?.observedAt)
}

function getBridgeSnapshot() {
  const element = getBridgeElement()
  if (!element?.getAttribute) return null
  const value = name => element.getAttribute(name)
  return {
    pluginId: value('data-plugin-id'),
    apiVersion: value('data-api-version'),
    pointerEvent: value('data-pointer-event'),
    enabled: value('data-enabled') === '1',
    observationId: value('data-observation-id'),
    pageObservationId: value('data-page-observation-id'),
    observedAt: value('data-observed-at'),
    current: {
      plugin: value('data-current-plugin'),
      module: value('data-current-module'),
      slot: value('data-current-slot'),
      evidence: value('data-current-evidence'),
      confidence: value('data-current-confidence'),
      node: value('data-current-node'),
      observationId: value('data-current-observation-id'),
      pageObservationId: value('data-current-page-observation-id'),
      observedAt: value('data-current-observed-at'),
    },
  }
}

function setCurrentPointerInfo(info) {
  const cloned = clonePointerInfo(info)
  currentPointerInfo = cloned
    ? {
        ...cloned,
        observationSchemaVersion: POINTER_OBSERVATION_SCHEMA_VERSION,
        observationId: cloned.observationId || createOpaqueId('pointer'),
        pageObservationId: cloned.pageObservationId || PAGE_OBSERVATION_ID,
        observedAt: cloned.observedAt || new Date().toISOString(),
      }
    : null
  updateBridgeElement(currentPointerInfo)
  if (typeof document === 'undefined' || typeof CustomEvent !== 'function') return
  try {
    document.dispatchEvent(new CustomEvent(POINTER_EVENT, { detail: clonePointerInfo(currentPointerInfo) }))
  } catch {
    // A minimal test DOM or older browser may not implement CustomEvent.
  }
}

function getPointerEvidenceSnapshot() {
  return {
    schemaVersion: POINTER_OBSERVATION_SCHEMA_VERSION,
    enabled: readEnabled(),
    pointerEvent: POINTER_EVENT,
    pageObservationId: PAGE_OBSERVATION_ID,
    current: clonePointerInfo(currentPointerInfo),
    bridge: getBridgeSnapshot(),
  }
}

function installProvenanceApi() {
  const targets = []
  if (typeof document !== 'undefined') targets.push(document)
  if (typeof document !== 'undefined' && document.defaultView) targets.push(document.defaultView)
  if (typeof window !== 'undefined') targets.push(window)
  if (typeof globalThis !== 'undefined') targets.push(globalThis)
  const uniqueTargets = targets.filter((target, index) => target && targets.indexOf(target) === index)
  if (uniqueTargets.length === 0) return null
  const api = {
    pluginId: PLUGIN_ID,
    apiVersion: 1,
    reportSchemaVersion: REPORT_SCHEMA_VERSION,
    pointerEvent: POINTER_EVENT,
    get enabled() { return readEnabled() },
    enable() {
      setEnabled(true)
      return readEnabled()
    },
    disable() {
      setEnabled(false)
      return readEnabled()
    },
    setEnabled(value) {
      setEnabled(Boolean(value))
      return readEnabled()
    },
    getCurrent() {
      return clonePointerInfo(currentPointerInfo)
    },
    getPointerEvidence() {
      return getPointerEvidenceSnapshot()
    },
    getBridgeSnapshot,
    inspect(target, x = 0, y = 0) {
      if (typeof document === 'undefined') return null
      const ownerDocument = target?.ownerDocument && typeof target.ownerDocument.querySelectorAll === 'function'
        ? target.ownerDocument
        : document
      return inspectTarget(target, buildStyleIndex(ownerDocument), x, y)
    },
    scan() {
      return scanDiagnostics(typeof document === 'undefined' ? null : document)
    },
    getClientErrors,
    clearClientErrors,
  }
  for (const target of uniqueTargets) {
    target[DEBUG_GLOBAL] = api
    // Keep the old global as a read-only compatibility alias for existing
    // browser fixtures and integrations during the package rename.
    target[LEGACY_PROVENANCE_GLOBAL] = api
  }
  if (typeof document !== 'undefined' && document.documentElement?.setAttribute) {
    document.documentElement.setAttribute('data-dsh-debug-bridge', '1')
  }
  updateBridgeElement(currentPointerInfo)
  return api
}

function uninstallProvenanceApi(api) {
  const targets = []
  if (typeof document !== 'undefined') targets.push(document)
  if (typeof document !== 'undefined' && document.defaultView) targets.push(document.defaultView)
  if (typeof window !== 'undefined') targets.push(window)
  if (typeof globalThis !== 'undefined') targets.push(globalThis)
  for (const target of targets.filter((item, index) => item && targets.indexOf(item) === index)) {
    if (target[DEBUG_GLOBAL] === api) {
      try { delete target[DEBUG_GLOBAL] } catch { target[DEBUG_GLOBAL] = undefined }
    }
    if (target[LEGACY_PROVENANCE_GLOBAL] === api) {
      try { delete target[LEGACY_PROVENANCE_GLOBAL] } catch { target[LEGACY_PROVENANCE_GLOBAL] = undefined }
    }
  }
  try { bridgeElement?.remove?.() } catch { }
  bridgeElement = null
  if (currentPointerInfo) setCurrentPointerInfo(null)
}

function dispatchDiagnosticsEvent() {
  if (typeof document === 'undefined' || typeof Event !== 'function') return
  document.dispatchEvent(new Event(DIAGNOSTICS_EVENT))
}

function truncateText(value, maxLength = 1000) {
  const text = typeof value === 'string' ? value : String(value ?? '')
  return text.length > maxLength ? `${text.slice(0, Math.max(0, maxLength - 1))}…` : text
}

function sanitizeUrl(value) {
  if (!value) return null
  const text = String(value)
  try {
    if (typeof URL === 'function') {
      const base = typeof location !== 'undefined' && location.href ? location.href : undefined
      const parsed = new URL(text, base)
      return truncateText(`${parsed.origin}${parsed.pathname}`, 400)
    }
  } catch {
    // Fall through to the conservative string-only redaction below.
  }
  return truncateText(text.split(/[?#]/u, 1)[0], 400) || null
}

function redactSensitiveText(value) {
  let text = truncateText(value, 4000)
  text = text.replace(
    /((?:["']?(?:authorization|proxy-authorization|cookie|set-cookie|api[-_]?key|access[-_]?token|refresh[-_]?token|password|secret|token)["']?)\s*[:=]\s*)(?:(['"])[^'"']*\2|(?:(?:bearer|basic)\s+)?[^\s,;}\]]+)/giu,
    (match, prefix, quote) => `${prefix}${quote || ''}[redacted]${quote || ''}`,
  )
  return text
    .replace(/\b(?:bearer|basic)\s+[A-Za-z0-9._~+/=-]+/giu, match => `${match.split(/\s+/u)[0]} [redacted]`)
    .replace(/https?:\/\/[^\s"'<>]+/gu, match => sanitizeUrl(match) || '[url]')
}

function readableError(value) {
  if (value instanceof Error) return value.message || value.name || 'Error'
  if (typeof value === 'string') return value
  if (value && typeof value.message === 'string') return value.message
  try {
    const serialized = JSON.stringify(value)
    return serialized === undefined ? String(value) : serialized
  } catch {
    return String(value)
  }
}

function recordClientError(kind, value, event = null) {
  const message = redactSensitiveText(readableError(value)).slice(0, 1000) || 'Unknown browser error'
  const errorObject = value instanceof Error || typeof value?.stack === 'string'
    ? value
    : event?.error instanceof Error || typeof event?.error?.stack === 'string'
      ? event.error
      : null
  const filename = sanitizeUrl(event?.filename || event?.target?.src || event?.target?.href)
  const stack = errorObject?.stack ? redactSensitiveText(errorObject.stack).slice(0, 4000) : null
  const previous = clientErrors.at(-1)
  if (previous && previous.kind === kind && previous.message === message && previous.filename === filename) return
  clientErrors.push({
    kind,
    message,
    time: new Date().toISOString(),
    capturePhase: ERROR_CAPTURE_PHASE,
    filename,
    line: Number.isFinite(event?.lineno) ? event.lineno : null,
    column: Number.isFinite(event?.colno) ? event.colno : null,
    stack,
  })
  if (clientErrors.length > 100) clientErrors.splice(0, clientErrors.length - 100)
  dispatchDiagnosticsEvent()
}

function installClientErrorCapture() {
  if (errorCaptureInstalled || typeof window === 'undefined' || typeof window.addEventListener !== 'function') return
  errorCaptureInstalled = true
  errorCaptureStartedAt = new Date().toISOString()
  window.addEventListener('error', event => {
    const resourceError = !event.error && !event.message && event.target && event.target !== window
    recordClientError(resourceError ? 'resource-error' : 'error', event.error || event.message || 'Unknown browser error', event)
  }, true)
  window.addEventListener('unhandledrejection', event => {
    recordClientError('unhandledrejection', event.reason || 'Unhandled promise rejection')
  })
}

function getClientErrors() {
  return clientErrors.slice()
}

function clearClientErrors() {
  clientErrors.length = 0
  dispatchDiagnosticsEvent()
}

function optionalService(ctx, name) {
  if (!ctx) return null
  try {
    if (typeof ctx.get === 'function') return ctx.get(name) || null
  } catch {
    // Optional DSH services are allowed to be absent in a minimal composition.
  }
  if (typeof ctx.get === 'function') return null
  try {
    return ctx[name] || null
  } catch {
    return null
  }
}

function readObservableSnapshot(source) {
  try {
    return typeof source?.getSnapshot === 'function' ? source.getSnapshot() : undefined
  } catch {
    return undefined
  }
}

function mapEntriesOf(value) {
  try {
    return typeof value?.entries === 'function' ? Array.from(value.entries()) : []
  } catch {
    return []
  }
}

function mapKeysOf(value) {
  try {
    return typeof value?.keys === 'function' ? Array.from(value.keys(), key => String(key)).sort() : []
  } catch {
    return []
  }
}

function collectionSize(value) {
  if (Number.isFinite(value?.size)) return value.size
  return mapEntriesOf(value).length
}

function boundedStrings(values, limit = MAX_RUNTIME_ITEMS) {
  return Array.from(values || [], value => String(value))
    .sort((left, right) => left.localeCompare(right))
    .slice(0, limit)
}

function snapshotModuleSystem() {
  const loader = typeof window !== 'undefined' ? window.__ModuleLoader__ : null
  const globalModules = typeof globalThis !== 'undefined' ? globalThis.__DSH_MODULES__ : null
  const windowModules = typeof window !== 'undefined' ? window.__DSH_MODULES__ : null
  const modules = windowModules || globalModules
  const unavailable = {
    status: modules ? 'unavailable' : loader ? 'unavailable' : 'missing',
    version: null,
    counts: { factories: 0, loaded: 0, seed: 0, statics: 0, graphRows: 0, pendingArrival: 0, materializing: 0 },
    factories: [],
    loaded: [],
    seed: [],
    statics: [],
    graphRows: [],
    pendingArrival: [],
    materializing: [],
    truncated: false,
  }
  if (!modules || typeof modules !== 'object') return unavailable

  const loadedEntries = mapEntriesOf(modules.loadCache)
    .slice(0, MAX_RUNTIME_ITEMS)
    .map(([key, record]) => ({
      id: String(record?.id ?? key),
      styles: boundedStrings(record?.styles, 20),
      edges: boundedStrings(record?.edges, 20),
    }))
    .sort((left, right) => left.id.localeCompare(right.id))
  const graphRows = mapEntriesOf(modules.graphRows)
    .slice(0, MAX_RUNTIME_ITEMS)
    .map(([key, row]) => ({
      id: String(row?.id ?? key),
      url: sanitizeUrl(row?.url),
      immediately: row?.immediately === true,
    }))
    .sort((left, right) => left.id.localeCompare(right.id))
  const counts = {
    factories: collectionSize(modules.factories),
    loaded: collectionSize(modules.loadCache),
    seed: collectionSize(modules.seed),
    statics: collectionSize(modules.statics),
    graphRows: collectionSize(modules.graphRows),
    pendingArrival: collectionSize(modules.pendingArrival),
    materializing: collectionSize(modules.materializing),
  }
  return {
    status: typeof modules.version === 'string' ? 'present' : 'unavailable',
    version: typeof modules.version === 'string' ? modules.version : null,
    counts,
    factories: boundedStrings(mapKeysOf(modules.factories)),
    loaded: loadedEntries,
    seed: boundedStrings(mapKeysOf(modules.seed)),
    statics: boundedStrings(mapKeysOf(modules.statics)),
    graphRows,
    pendingArrival: boundedStrings(mapKeysOf(modules.pendingArrival)),
    materializing: boundedStrings(modules.materializing),
    truncated: Object.values(counts).some(value => value > MAX_RUNTIME_ITEMS),
  }
}

function projectSlotNode(node, state, depth = 0) {
  if (!node || state.count >= MAX_SLOT_NODES) return null
  state.count += 1
  const occupants = Array.isArray(node.occupants) ? node.occupants.slice(0, MAX_RUNTIME_ITEMS).map(occupant => ({
    registrant: typeof occupant?.registrant === 'string' ? occupant.registrant : null,
    key: typeof occupant?.key === 'string' ? occupant.key : null,
    id: typeof occupant?.id === 'string' ? occupant.id : null,
    order: Number.isFinite(occupant?.order) ? occupant.order : null,
    priority: Number.isFinite(occupant?.priority) ? occupant.priority : null,
    active: occupant?.active === true,
  })) : []
  const children = depth >= 8 || !Array.isArray(node.children)
    ? []
    : node.children.map(child => projectSlotNode(child, state, depth + 1)).filter(Boolean)
  return {
    name: typeof node.name === 'string' ? node.name : 'unknown-slot',
    kind: typeof node.kind === 'string' ? node.kind : 'unknown',
    scope: typeof node.scope === 'string' ? node.scope : 'unknown',
    declaredBy: typeof node.declaredBy === 'string' ? node.declaredBy : null,
    occupants,
    children,
  }
}

function flattenSlotNodes(nodes, output = []) {
  for (const node of nodes || []) {
    output.push(node)
    flattenSlotNodes(node.children, output)
  }
  return output
}

function snapshotSlotRegistry() {
  const slots = optionalService(runtimeContext, 'slots')
  const empty = {
    status: slots ? 'unavailable' : 'missing',
    nodes: [],
    counts: { declarations: 0, occupants: 0, activeOccupants: 0, inactiveOccupants: 0, singleWithMultipleOccupants: 0, duplicateCells: 0 },
    multipleOccupants: [],
    duplicateCells: [],
    error: null,
  }
  if (!slots || typeof slots.snapshot !== 'function') return empty
  try {
    const state = { count: 0 }
    const snapshot = slots.snapshot()
    const nodes = (Array.isArray(snapshot) ? snapshot : [])
      .map(node => projectSlotNode(node, state))
      .filter(Boolean)
    const flat = flattenSlotNodes(nodes)
    const multipleOccupants = flat
      .filter(node => node.kind === 'single' && node.occupants.length > 1)
      .slice(0, MAX_RUNTIME_ITEMS)
      .map(node => ({ name: node.name, kind: node.kind, occupants: node.occupants }))
    const cells = new Map()
    for (const node of flat) {
      for (const occupant of node.occupants) {
        const cell = occupant.key || occupant.id || '<unkeyed>'
        const identity = `${node.name}\u0000${cell}\u0000${occupant.priority ?? '<none>'}`
        const current = cells.get(identity) || { name: node.name, cell, priority: occupant.priority, occupants: [] }
        current.occupants.push({ registrant: occupant.registrant, key: occupant.key, id: occupant.id, active: occupant.active })
        cells.set(identity, current)
      }
    }
    const duplicateCells = Array.from(cells.values())
      .filter(item => item.occupants.length > 1)
      .slice(0, MAX_RUNTIME_ITEMS)
    const occupants = flat.flatMap(node => node.occupants)
    return {
      status: 'present',
      nodes,
      counts: {
        declarations: flat.length,
        occupants: occupants.length,
        activeOccupants: occupants.filter(item => item.active).length,
        inactiveOccupants: occupants.filter(item => !item.active).length,
        singleWithMultipleOccupants: multipleOccupants.length,
        duplicateCells: duplicateCells.length,
      },
      multipleOccupants,
      duplicateCells,
      error: null,
      truncated: state.count >= MAX_SLOT_NODES,
    }
  } catch (error) {
    return { ...empty, status: 'present', error: summarizeError(error) }
  }
}

function summarizeError(value) {
  if (value === null || value === undefined) return null
  const record = value && typeof value === 'object' ? value : null
  const name = typeof record?.name === 'string' ? record.name : null
  const code = typeof record?.code === 'string' ? record.code : null
  const message = redactSensitiveText(record?.message ?? readableError(value)).slice(0, 1000)
  return { name, code, message: message || null }
}

function snapshotHostStatus() {
  const connection = optionalService(runtimeContext, 'connection')
  const source = connection?.hostDescription
  const description = readObservableSnapshot(source)
  const empty = {
    status: source ? 'present' : 'missing',
    connectionState: source && description ? 'connected' : source ? 'disconnected' : 'unavailable',
    description: null,
  }
  if (!description || typeof description !== 'object') return empty
  return {
    status: 'present',
    connectionState: 'connected',
    description: {
      version: typeof description.version === 'string' ? description.version : null,
      provider: typeof description.provider === 'string' ? description.provider : null,
      model: typeof description.model === 'string' ? description.model : null,
      attachedSessions: Number.isFinite(description.attachedSessions) ? description.attachedSessions : null,
      canOpenPath: description.canOpenPath === true,
      cwdPresent: typeof description.cwd === 'string' && description.cwd.length > 0,
    },
  }
}

function snapshotPermissionStatus() {
  const presets = optionalService(runtimeContext, 'permissionPresets')
  const approval = optionalService(runtimeContext, 'approval')
  const shell = optionalService(runtimeContext, 'shell')
  const available = Boolean(presets || approval || shell)
  const result = {
    status: available ? 'present' : 'missing',
    defaultPreset: null,
    sandboxMode: null,
    approvalPolicy: null,
    presetNames: [],
    source: available ? 'host-services-read-only' : 'not-observed',
  }
  try {
    if (typeof presets?.defaultPreset === 'string') result.defaultPreset = presets.defaultPreset
  } catch {
    // A versioned optional service may expose no readable default.
  }
  try {
    if (Array.isArray(presets?.names)) result.presetNames = boundedStrings(presets.names, 20)
  } catch {
    // Keep the rest of the permission snapshot usable.
  }
  try {
    if (typeof shell?.sandboxMode === 'string') result.sandboxMode = shell.sandboxMode
  } catch {
    // Some shell providers intentionally omit sandbox capability.
  }
  try {
    if (typeof approval?.config?.policy === 'string') result.approvalPolicy = approval.config.policy
  } catch {
    // Approval is optional in a minimal client composition.
  }
  return result
}

function projectRunningCall(call) {
  return {
    callId: typeof call?.callId === 'string' ? call.callId : null,
    name: typeof call?.name === 'string' ? call.name : null,
    turn: Number.isFinite(call?.turn) ? call.turn : null,
    step: Number.isFinite(call?.step) ? call.step : null,
    time: Number.isFinite(call?.time) ? call.time : null,
    hasArguments: typeof call?.argsRaw === 'string' && call.argsRaw.length > 0,
  }
}

function collectToolBlocks(value, output = [], state = { visited: 0, truncated: false, outputTruncated: false, resultCount: 0, resultErrorCount: 0 }) {
  if (!value || state.truncated) return output
  if (state.visited >= MAX_RUNTIME_NODES) {
    state.truncated = true
    return output
  }
  state.visited += 1
  if (value.kind === 'tool-result') {
    state.resultCount += 1
    if (value.isError === true || value.error) state.resultErrorCount += 1
    if (output.length < MAX_RUNTIME_ITEMS) output.push(value)
    else state.outputTruncated = true
  }
  if (Array.isArray(value.subCalls)) {
    for (const child of value.subCalls) collectToolBlocks(child, output, state)
  }
  return output
}

function snapshotSessionStatus() {
  const sessions = optionalService(runtimeContext, 'sessions')
  const list = readObservableSnapshot(sessions?.list)
  const empty = {
    status: sessions?.list ? 'unavailable' : 'missing',
    current: null,
    toolCalls: {
      status: sessions?.list ? 'unavailable' : 'missing',
      sessionId: null,
      running: [],
      resultErrors: [],
      turnErrors: [],
      totals: { running: 0, toolResults: 0, resultErrors: 0, turnErrors: 0 },
      truncated: { any: false, running: false, toolResults: false, resultErrors: false, turnErrors: false, traversal: false },
      countsComplete: false,
      openError: null,
      promptError: null,
      lastAgentError: null,
    },
    error: null,
  }
  if (!list || typeof list !== 'object') return empty
  const currentId = typeof list.current === 'string' ? list.current : null
  const row = currentId && list.byId && typeof list.byId === 'object' ? list.byId[currentId] : null
  const current = currentId ? {
    sessionId: currentId,
    title: null,
    titlePresent: typeof row?.displayTitle === 'string' && row.displayTitle.length > 0,
    running: row?.running === true,
    blank: row?.blank === true,
  } : null
  if (!currentId || typeof sessions?.binding !== 'function') {
    return {
      ...empty,
      status: 'present',
      current,
      toolCalls: { ...empty.toolCalls, status: 'no-session', sessionId: currentId },
    }
  }
  let snapshot
  try {
    snapshot = sessions.binding(currentId)?.session?.getSnapshot?.()
  } catch (error) {
    return { ...empty, status: 'present', current, toolCalls: { ...empty.toolCalls, status: 'unavailable', sessionId: currentId }, error: summarizeError(error) }
  }
  if (!snapshot || typeof snapshot !== 'object') {
    return { ...empty, status: 'present', current, toolCalls: { ...empty.toolCalls, status: 'unavailable', sessionId: currentId } }
  }
  const toolResults = []
  const nodes = Array.isArray(snapshot.nodes) ? snapshot.nodes : []
  const traversalState = { visited: 0, truncated: false, outputTruncated: false, resultCount: 0, resultErrorCount: 0 }
  for (const node of nodes) collectToolBlocks(node, toolResults, traversalState)
  const runningCalls = Array.isArray(snapshot.runningCalls) ? snapshot.runningCalls : []
  const running = runningCalls.slice(0, MAX_RUNTIME_ITEMS).map(projectRunningCall)
  const resultErrors = toolResults
    .filter(node => node.isError === true || node.error)
    .slice(0, MAX_RUNTIME_ITEMS)
    .map(node => ({
      callId: typeof node.callId === 'string' ? node.callId : null,
      time: Number.isFinite(node.time) ? node.time : null,
      callTime: Number.isFinite(node.callTime) ? node.callTime : null,
      isError: node.isError === true,
      error: summarizeError(node.error),
    }))
  const turnErrorNodes = nodes.filter(node => node.kind === 'turn-error')
  const turnErrors = turnErrorNodes.slice(0, MAX_RUNTIME_ITEMS)
    .map(node => ({
      time: Number.isFinite(node.time) ? node.time : null,
      turn: Number.isFinite(node.turn) ? node.turn : null,
      step: Number.isFinite(node.step) ? node.step : null,
      code: typeof node.code === 'string' ? node.code : null,
      message: redactSensitiveText(node.message || '').slice(0, 1000),
    }))
  const truncated = {
    any: runningCalls.length > MAX_RUNTIME_ITEMS || traversalState.outputTruncated || traversalState.truncated || turnErrorNodes.length > MAX_RUNTIME_ITEMS,
    running: runningCalls.length > MAX_RUNTIME_ITEMS,
    toolResults: traversalState.resultCount > MAX_RUNTIME_ITEMS || traversalState.outputTruncated || traversalState.truncated,
    resultErrors: traversalState.resultErrorCount > MAX_RUNTIME_ITEMS || traversalState.resultErrorCount > resultErrors.length || traversalState.truncated,
    turnErrors: turnErrorNodes.length > MAX_RUNTIME_ITEMS,
    traversal: traversalState.truncated,
  }
  return {
    status: 'present',
    current,
    toolCalls: {
      status: 'present',
      sessionId: currentId,
      running,
      resultErrors,
      turnErrors,
      totals: {
        running: runningCalls.length,
        toolResults: traversalState.resultCount,
        resultErrors: traversalState.resultErrorCount,
        turnErrors: turnErrorNodes.length,
      },
      truncated,
      countsComplete: !traversalState.truncated,
      openError: summarizeError(snapshot.openError),
      promptError: snapshot.promptError ? {
        op: typeof snapshot.promptError.op === 'string' ? snapshot.promptError.op : null,
        error: summarizeError(snapshot.promptError.error || snapshot.promptError),
      } : null,
      lastAgentError: snapshot.lastAgentError ? redactSensitiveText(snapshot.lastAgentError).slice(0, 1000) : null,
    },
    error: null,
  }
}

function mapObservableEntries(source, project) {
  const snapshot = readObservableSnapshot(source)
  return mapEntriesOf(snapshot)
    .slice(0, MAX_RUNTIME_ITEMS)
    .map(([key, value]) => project(String(key), value))
}

function snapshotDynamicCordis() {
  const runner = optionalService(runtimeContext, 'dynamicCordisRunner')
  const empty = {
    status: runner ? 'unavailable' : 'missing',
    loaded: [],
    activeRuns: [],
    runErrors: [],
    renderFailures: [],
  }
  if (!runner) return empty
  let loaded = []
  try {
    loaded = typeof runner.getSnapshot === 'function' ? runner.getSnapshot().slice(0, MAX_RUNTIME_ITEMS).map(item => ({
      pluginId: String(item.pluginId),
      packageId: String(item.packageId),
      pluginRunId: String(item.pluginRunId),
      name: typeof item.name === 'string' ? item.name : null,
      slots: boundedStrings(item.slots, 20),
      styleCount: Number.isFinite(item.styleCount) ? item.styleCount : null,
    })) : []
  } catch {
    loaded = []
  }
  const activeRuns = mapObservableEntries(runner.activeRuns, (pluginId, value) => ({
    pluginId,
    phase: typeof value?.phase === 'string' ? value.phase : null,
    packageId: value?.packageId ? String(value.packageId) : null,
    agentId: value?.agentId ? String(value.agentId) : null,
  }))
  const runErrors = mapObservableEntries(runner.lastRunError, (pluginId, value) => ({
    pluginId,
    packageId: value?.packageId ? String(value.packageId) : null,
    reason: typeof value?.reason === 'string' ? value.reason : null,
    error: summarizeError(value),
  }))
  const renderFailures = mapObservableEntries(runner.renderFailures, (pluginId, value) => ({
    pluginId,
    slot: typeof value?.slot === 'string' ? value.slot : null,
    abdicated: value?.abdicated === true,
    error: summarizeError(value),
  }))
  return { status: 'present', loaded, activeRuns, runErrors, renderFailures }
}

function snapshotPluginInventory() {
  return {
    status: pluginInventoryState,
    entries: pluginInventoryEntries.slice(0, MAX_RUNTIME_ITEMS),
    error: pluginInventoryError,
  }
}

function refreshPluginInventory(ctx = runtimeContext) {
  const remote = optionalService(ctx, 'remote.pluginInventory')
  const list = remote?.list
  if (typeof list !== 'function') {
    pluginInventoryState = 'not-observed'
    pluginInventoryEntries = []
    pluginInventoryError = null
    return Promise.resolve()
  }
  const request = ++pluginInventoryRequest
  pluginInventoryState = 'loading'
  pluginInventoryError = null
  dispatchDiagnosticsEvent()
  return Promise.resolve()
    .then(() => list.call(remote))
    .then(result => {
      if (request !== pluginInventoryRequest) return
      if (!result?.ok) throw new Error(`pluginInventory.list failed: ${result?.error?.code || 'unknown'}: ${result?.error?.message || 'unknown error'}`)
      const entries = Array.isArray(result.value?.entries) ? result.value.entries : []
      pluginInventoryEntries = entries.slice(0, MAX_RUNTIME_ITEMS).map(entry => ({
        entryId: typeof entry.entryId === 'string' ? entry.entryId : String(entry.entryId ?? ''),
        moduleName: typeof entry.moduleName === 'string' ? entry.moduleName : null,
        enabled: entry.enabled === true,
        fiberPhase: typeof entry.fiberPhase === 'string' ? entry.fiberPhase : null,
      }))
      pluginInventoryState = 'ready'
      pluginInventoryError = null
    })
    .catch(error => {
      if (request !== pluginInventoryRequest) return
      pluginInventoryState = 'error'
      pluginInventoryError = summarizeError(error)
    })
    .finally(() => {
      if (request === pluginInventoryRequest) dispatchDiagnosticsEvent()
    })
}

function recordSlotError(slot, entry, error, info = {}) {
  const options = entry?.options || {}
  const item = {
    slot: typeof slot === 'string' ? slot : String(slot ?? 'unknown-slot'),
    registrant: typeof entry?.registrant === 'string' ? entry.registrant : null,
    key: typeof options.key === 'string' ? options.key : null,
    id: typeof options.id === 'string' ? options.id : null,
    priority: Number.isFinite(options.priority) ? options.priority : null,
    abdicated: info?.abdicate === true || info?.abdicated === true,
    error: summarizeError(error),
    time: new Date().toISOString(),
  }
  const previous = slotErrors.at(-1)
  if (previous && previous.slot === item.slot && previous.registrant === item.registrant && previous.error?.message === item.error?.message) return
  slotErrors.push(item)
  if (slotErrors.length > 100) slotErrors.splice(0, slotErrors.length - 100)
  dispatchDiagnosticsEvent()
}

function installRuntimeDiagnostics(ctx) {
  runtimeContext = ctx
  const disposers = []
  const subscribe = source => {
    try {
      const dispose = source?.subscribe?.(dispatchDiagnosticsEvent)
      if (typeof dispose === 'function') disposers.push(dispose)
    } catch {
      // Optional observables are versioned seams; an absent/throwing subscriber must not break the UI.
    }
  }
  const connection = optionalService(ctx, 'connection')
  subscribe(connection?.hostDescription)
  if (connection?.hostDescription?.subscribe) {
    try {
      const dispose = connection.hostDescription.subscribe(() => { refreshPluginInventory(ctx) })
      if (typeof dispose === 'function') disposers.push(dispose)
    } catch {
      // The host description is still read on demand when the user rescans.
    }
  }
  const sessions = optionalService(ctx, 'sessions')
  subscribe(sessions?.list)
  const dynamic = optionalService(ctx, 'dynamicCordisRunner')
  subscribe(dynamic?.activeRuns)
  subscribe(dynamic?.lastRunError)
  subscribe(dynamic?.renderFailures)
  const slots = optionalService(ctx, 'slots')
  try {
    const dispose = slots?.onEntryError?.((slot, entry, error, info) => recordSlotError(slot, entry, error, info))
    if (typeof dispose === 'function') disposers.push(dispose)
  } catch {
    // Older DSH versions may not expose the entry crash supervision seam.
  }
  void refreshPluginInventory(ctx).then(() => maybeCreateStartupDiagnosticSession(ctx))
  const cleanup = () => {
    for (const dispose of disposers.splice(0)) {
      try { dispose() } catch { /* best effort during plugin unload */ }
    }
    if (runtimeContext === ctx) runtimeContext = null
  }
  if (typeof ctx.effect === 'function') {
    ctx.effect(() => cleanup, `${PLUGIN_ID}: runtime diagnostics`)
    runtimeCleanup = cleanup
  } else {
    runtimeCleanup = cleanup
  }
}

function isElement(value) {
  return Boolean(value && value.nodeType === 1 && typeof value.getAttribute === 'function')
}

function classNamesOf(element) {
  if (element.classList && typeof element.classList[Symbol.iterator] === 'function') {
    return Array.from(element.classList)
  }
  return String(element.className || '').split(/\s+/u).filter(Boolean)
}

function describeElement(element) {
  if (!isElement(element)) return 'node'
  const tagName = String(element.tagName || 'node').toLowerCase()
  const role = element.getAttribute('role')
  const safeRole = typeof role === 'string' && /^[A-Za-z][A-Za-z0-9_-]{0,31}$/u.test(role) ? role : null
  return `${tagName}${safeRole ? ` [role=${safeRole}]` : ''}`
}

function summarizeAttribute(elements, attribute) {
  const counts = new Map()
  for (const element of elements) {
    const value = element.getAttribute(attribute)
    if (!value) continue
    counts.set(value, (counts.get(value) || 0) + 1)
  }
  return Array.from(counts, ([value, count]) => ({ value, count }))
    .sort((left, right) => right.count - left.count || left.value.localeCompare(right.value))
}

function summarizePluginModuleRelations(elements) {
  const relations = new Map()
  for (const element of elements) {
    const module = element.getAttribute('data-dsh-module')
    if (!module) continue
    const plugin = element.getAttribute('data-dsh-plugin')
      || (typeof element.closest === 'function' ? element.closest('[data-dsh-plugin]')?.getAttribute('data-dsh-plugin') : null)
    if (!plugin) continue
    const key = `${plugin}\u0000${module}`
    const current = relations.get(key) || { plugin, module, count: 0 }
    current.count += 1
    relations.set(key, current)
  }
  return Array.from(relations.values())
    .sort((left, right) => left.plugin.localeCompare(right.plugin) || left.module.localeCompare(right.module))
}

function findModuleOwnershipClues(relations) {
  const owners = new Map()
  for (const relation of relations) {
    const current = owners.get(relation.module) || []
    if (!current.some(owner => owner.plugin === relation.plugin)) current.push(relation)
    owners.set(relation.module, current)
  }
  return Array.from(owners, ([module, entries]) => ({
    kind: 'module-multiple-plugin-owners',
    severity: 'review',
    module,
    plugins: entries.map(entry => entry.plugin).sort((left, right) => left.localeCompare(right)),
    occurrences: entries.reduce((total, entry) => total + entry.count, 0),
  }))
    .filter(item => item.plugins.length > 1)
    .sort((left, right) => left.module.localeCompare(right.module))
}

function getPagePath() {
  if (typeof location === 'undefined') return 'unknown'
  const origin = typeof location.origin === 'string' ? location.origin : ''
  const pathname = typeof location.pathname === 'string' ? location.pathname : '/'
  return `${origin}${pathname}` || 'unknown'
}

function moduleLoaderStatus() {
  if (typeof window === 'undefined') return 'unavailable'
  return typeof window.__ModuleLoader__?.load === 'function' ? 'present' : 'missing'
}

function capabilityObservation(status, evidence, canObserve, cannotProvide) {
  return {
    status,
    observed: status === 'observed-read-only' || status === 'partial-read-only',
    evidence,
    canObserve,
    cannotProvide,
  }
}

function hostGuardRequirement(provides) {
  return {
    status: 'required',
    observed: false,
    evidence: [],
    provides,
  }
}

function buildCapabilityStatus(runtimeDiagnostics = {}, pageEvidence = {}) {
  const session = runtimeDiagnostics.session || {}
  const host = runtimeDiagnostics.host || {}
  const pluginInventory = runtimeDiagnostics.pluginInventory || {}
  const dynamicCordis = runtimeDiagnostics.dynamicCordis || {}
  const slotRegistry = runtimeDiagnostics.slotRegistry || {}
  const toolCalls = runtimeDiagnostics.toolCalls || {}
  const pluginMarkerCount = Number.isFinite(pageEvidence.pluginMarkers) ? pageEvidence.pluginMarkers : 0

  const sessionStatus = session.status === 'present'
    ? session.current ? 'observed-read-only' : 'partial-read-only'
    : session.status === 'unavailable'
      ? 'unavailable'
      : 'not-observed'
  const workspaceStatus = host.connectionState === 'connected'
    ? 'partial-read-only'
    : host.status === 'present'
      ? 'unavailable'
      : 'not-observed'
  const pluginInventoryObserved = pluginInventory.status === 'ready'
  const pluginRuntimeObserved = dynamicCordis.status === 'present'
  const pluginMarkersObserved = pluginMarkerCount > 0
  const pluginStatus = pluginInventoryObserved
    ? 'observed-read-only'
    : pluginRuntimeObserved || pluginMarkersObserved
      ? 'partial-read-only'
      : pluginInventory.status === 'loading' || pluginInventory.status === 'error'
        ? 'unavailable'
        : 'not-observed'
  const crashEvidence = []
  if ((runtimeDiagnostics.slotErrors || []).length > 0) crashEvidence.push('slot-entry-error-capture')
  if (pluginRuntimeObserved) crashEvidence.push('dynamic-plugin-failure-signals')
  if (pluginInventoryObserved && (pluginInventory.entries || []).some(entry => entry.fiberPhase === 'failed')) {
    crashEvidence.push('plugin-failure-phase')
  }
  const crashStatus = crashEvidence.length > 0
    ? 'partial-read-only'
    : slotRegistry.status === 'unavailable' || dynamicCordis.status === 'unavailable' || pluginInventory.status === 'error'
      ? 'unavailable'
      : 'not-observed'
  const toolCallStatus = toolCalls.status === 'present'
    ? 'observed-read-only'
    : toolCalls.status === 'unavailable'
      ? 'unavailable'
      : 'not-observed'

  return {
    schemaVersion: CAPABILITY_SCHEMA_VERSION,
    clientMode: 'read-only',
    conversationSession: {
      client: capabilityObservation(
        sessionStatus,
        [
          ...(session.status === 'present' ? ['session-list-snapshot'] : []),
          ...(session.current ? ['current-session-summary'] : []),
        ],
        ['session-list-snapshot', 'current-session-summary', 'read-only-session-state-signals'],
        ['conversation-content', 'session-lifecycle-authority'],
      ),
      hostGuard: hostGuardRequirement(['conversation-session-authority', 'session-lifecycle-and-access-policy']),
    },
    workspaceFile: {
      client: capabilityObservation(
        workspaceStatus,
        workspaceStatus === 'partial-read-only' ? ['host-workspace-presence', 'host-file-capability-flag'] : [],
        ['workspace-presence-metadata', 'file-capability-flag'],
        ['workspace-identity', 'file-contents', 'file-mutations', 'file-rollback'],
      ),
      hostGuard: hostGuardRequirement(['workspace-file-authority', 'file-read-write-delete-restore-rollback-policy']),
    },
    pluginEnablement: {
      client: capabilityObservation(
        pluginStatus,
        [
          ...(pluginInventoryObserved ? ['host-plugin-inventory-enabled-flags'] : []),
          ...(pluginRuntimeObserved ? ['dynamic-plugin-runtime-snapshot'] : []),
          ...(pluginMarkersObserved ? ['dom-plugin-markers'] : []),
        ],
        ['plugin-enabled-flag-when-host-inventory-exposes-it', 'loaded-plugin-presence-clues'],
        ['plugin-enable-disable-configuration', 'plugin-enablement-mutation'],
      ),
      hostGuard: hostGuardRequirement(['authoritative-plugin-enable-disable-policy', 'plugin-configuration-changes']),
    },
    crashQuarantine: {
      client: capabilityObservation(
        crashStatus,
        crashEvidence,
        ['slot-render-error-signals', 'plugin-failure-or-abdication-signals'],
        ['crash-causality', 'quarantine-or-isolation-action', 'restart-or-disable-decision'],
      ),
      hostGuard: hostGuardRequirement(['crash-quarantine-and-isolation', 'restart-disable-and-recovery-policy']),
    },
    toolCallObservation: {
      client: capabilityObservation(
        toolCallStatus,
        toolCalls.status === 'present' ? ['redacted-session-tool-call-snapshot'] : [],
        ['tool-call-status-and-error-metadata-without-arguments-or-output-bodies'],
        ['tool-arguments', 'request-bodies', 'tool-execution', 'tool-call-success-claim'],
      ),
      hostGuard: hostGuardRequirement(['tool-execution-and-authorization', 'definitive-tool-call-result', 'permission-and-retry-policy']),
    },
  }
}

function collectRuntimeDiagnostics() {
  const moduleSystem = snapshotModuleSystem()
  const slotRegistry = snapshotSlotRegistry()
  const host = snapshotHostStatus()
  const permission = snapshotPermissionStatus()
  const session = snapshotSessionStatus()
  const dynamicCordis = snapshotDynamicCordis()
  const pluginInventory = snapshotPluginInventory()
  const toolCalls = session.toolCalls
  const diagnostics = {
    runtime: {
      moduleLoader: moduleLoaderStatus(),
      moduleSystem: moduleSystem.status,
      slotRegistry: slotRegistry.status,
      hostStatus: host.status,
      permissionStatus: permission.status,
      sessionStatus: session.status,
      hostPluginInventory: pluginInventory.status === 'ready' ? 'present' : pluginInventory.status === 'not-observed' ? 'missing' : 'unavailable',
      toolCallDiagnostics: toolCalls.status === 'present' ? 'present' : toolCalls.status === 'missing' ? 'missing' : 'unavailable',
      dynamicCordis: dynamicCordis.status,
      startupGuard: startupGuardNotice ? 'present' : 'not-observed',
    },
    boundaries: {
      host: host.connectionState === 'connected' ? 'observed-read-only' : 'not-observed',
      toolCall: toolCalls.status === 'present' ? 'observed-read-only' : 'not-observed',
      causalAttribution: 'not-supported',
    },
    moduleSystem,
    slotRegistry,
    host,
    permission,
    session,
    toolCalls,
    dynamicCordis,
    pluginInventory,
    slotErrors: slotErrors.slice(-MAX_REPORTED_ERRORS),
    startupGuard: {
      notice: startupGuardNotice,
      diagnosticSession: getStartupDiagnosticState(),
    },
  }
  return { ...diagnostics, capabilities: buildCapabilityStatus(diagnostics) }
}

function runtimeCluesOf(runtimeDiagnostics) {
  const clues = []
  const permission = runtimeDiagnostics.permission || {}
  if (permission.defaultPreset === 'danger-full-access' || permission.approvalPolicy === 'never') {
    clues.push({
      kind: 'permission-default-full-access',
      severity: 'review',
      defaultPreset: permission.defaultPreset,
      sandboxMode: permission.sandboxMode,
      approvalPolicy: permission.approvalPolicy,
      meaning: 'a model should not preemptively request danger-full-access; first observe an actual sandbox denial and use the narrowest allowed retry',
    })
  }
  const pluginEntries = runtimeDiagnostics.pluginInventory.entries || []
  for (const entry of pluginEntries) {
    if (entry.enabled === false) {
      clues.push({ kind: 'runtime-plugin-disabled', severity: 'review', entryId: entry.entryId, moduleName: entry.moduleName })
    } else if (entry.fiberPhase === 'failed') {
      clues.push({ kind: 'runtime-plugin-failed', severity: 'error', entryId: entry.entryId, moduleName: entry.moduleName, fiberPhase: entry.fiberPhase })
    }
  }
  for (const item of runtimeDiagnostics.slotRegistry.multipleOccupants || []) {
    clues.push({ kind: 'slot-single-multiple-occupants', severity: 'review', name: item.name, occupants: item.occupants })
  }
  for (const item of runtimeDiagnostics.slotRegistry.duplicateCells || []) {
    clues.push({ kind: 'slot-duplicate-cell', severity: 'review', name: item.name, cell: item.cell, priority: item.priority, occupants: item.occupants })
  }
  for (const item of runtimeDiagnostics.slotErrors || []) {
    clues.push({ kind: 'slot-entry-render-error', severity: 'error', ...item })
  }
  for (const item of runtimeDiagnostics.toolCalls.resultErrors || []) {
    clues.push({ kind: 'tool-result-error', severity: 'error', ...item })
  }
  for (const item of runtimeDiagnostics.toolCalls.turnErrors || []) {
    clues.push({ kind: 'turn-error', severity: 'error', ...item })
  }
  for (const item of runtimeDiagnostics.dynamicCordis.runErrors || []) {
    clues.push({ kind: 'dynamic-plugin-run-error', severity: 'error', ...item })
  }
  for (const item of runtimeDiagnostics.dynamicCordis.renderFailures || []) {
    clues.push({ kind: 'dynamic-plugin-render-error', severity: 'error', ...item })
  }
  if (runtimeDiagnostics.pluginInventory.error) clues.push({ kind: 'plugin-inventory-error', severity: 'error', error: runtimeDiagnostics.pluginInventory.error })
  if (runtimeDiagnostics.slotRegistry.error) clues.push({ kind: 'slot-registry-error', severity: 'error', error: runtimeDiagnostics.slotRegistry.error })
  if (runtimeDiagnostics.host.error) clues.push({ kind: 'host-status-error', severity: 'error', error: runtimeDiagnostics.host.error })
  if (runtimeDiagnostics.session.error) clues.push({ kind: 'session-snapshot-error', severity: 'error', error: runtimeDiagnostics.session.error })
  return clues.slice(0, MAX_REPORTED_CLUES)
}

function scanDiagnostics(documentObject, errors = getClientErrors()) {
  const errorCount = Array.isArray(errors) ? errors.length : 0
  const errorItems = Array.isArray(errors) ? errors.slice(-MAX_REPORTED_ERRORS) : []
  const runtimeDiagnostics = collectRuntimeDiagnostics()
  const empty = {
    schemaVersion: REPORT_SCHEMA_VERSION,
    scannedAt: new Date().toISOString(),
    page: getPagePath(),
    title: '',
    pointer: getPointerEvidenceSnapshot(),
    runtime: runtimeDiagnostics.runtime,
    boundaries: runtimeDiagnostics.boundaries,
    moduleSystem: runtimeDiagnostics.moduleSystem,
    slotRegistry: runtimeDiagnostics.slotRegistry,
    host: runtimeDiagnostics.host,
    permission: runtimeDiagnostics.permission,
    session: runtimeDiagnostics.session,
    toolCalls: runtimeDiagnostics.toolCalls,
    capabilities: runtimeDiagnostics.capabilities,
    dynamicCordis: runtimeDiagnostics.dynamicCordis,
    pluginInventory: runtimeDiagnostics.pluginInventory,
    slotErrors: runtimeDiagnostics.slotErrors,
    startupGuard: runtimeDiagnostics.startupGuard,
    counts: {
      pluginMarkers: 0,
      moduleMarkers: 0,
      slotMarkers: 0,
      styleNodes: 0,
      cssClasses: 0,
      cssConflicts: 0,
      markerConflicts: 0,
      slotHints: 0,
      moduleOwnershipClues: 0,
      clues: 0,
      clientErrors: errorCount,
      slotErrors: runtimeDiagnostics.slotErrors.length,
      failedPlugins: runtimeDiagnostics.pluginInventory.entries.filter(entry => entry.fiberPhase === 'failed').length,
      toolResultErrors: runtimeDiagnostics.toolCalls.resultErrors.length,
      turnErrors: runtimeDiagnostics.toolCalls.turnErrors.length,
    },
    plugins: [],
    modules: [],
    slots: [],
    pluginModuleRelations: [],
    moduleOwnershipClues: [],
    cssConflicts: [],
    markerConflicts: [],
    slotHints: [],
    clues: [],
    errors: errorItems,
    truncated: {
      errors: errorCount > MAX_REPORTED_ERRORS,
      clues: false,
      toolCalls: runtimeDiagnostics.toolCalls.truncated?.any === true,
    },
  }
  if (!documentObject || typeof documentObject.querySelectorAll !== 'function') return empty

  const pluginNodes = Array.from(documentObject.querySelectorAll('[data-dsh-plugin]'))
  const moduleNodes = Array.from(documentObject.querySelectorAll('[data-dsh-module]'))
  const slotNodes = Array.from(documentObject.querySelectorAll('[data-slot]'))
  const styleNodes = Array.from(documentObject.querySelectorAll('style[data-plugin]'))
  const capabilities = buildCapabilityStatus(runtimeDiagnostics, { pluginMarkers: pluginNodes.length })
  const styleIndex = buildStyleIndex(documentObject)
  const cssConflicts = Array.from(styleIndex.entries())
    .filter(([, sources]) => sources.length > 1)
    .slice(0, MAX_REPORTED_CLUES)
    .map(([className, sources]) => ({
      kind: 'css-class-multiple-sources',
      severity: 'review',
      className,
      sources: sources.slice(0, 8),
    }))

  const markerConflicts = []
  for (const node of pluginNodes) {
    const plugin = node.getAttribute('data-dsh-plugin')
    const module = node.getAttribute('data-dsh-module') || null
    const sources = []
    for (const className of classNamesOf(node)) {
      for (const source of styleIndex.get(className) || []) {
        if (!sources.some(item => item.plugin === source.plugin && item.module === source.module)) sources.push(source)
      }
    }
    const differing = sources.filter(source => source.plugin !== plugin || (module && source.module !== module))
    if (differing.length > 0) {
      markerConflicts.push({
        kind: 'dom-css-source-mismatch',
        severity: 'review',
        node: describeElement(node),
        plugin,
        module,
        cssSources: differing.slice(0, 8),
      })
    }
  }

  const plugins = summarizeAttribute(pluginNodes, 'data-dsh-plugin')
  const modules = summarizeAttribute(moduleNodes, 'data-dsh-module')
  const slots = summarizeAttribute(slotNodes, 'data-slot')
  const pluginModuleRelations = summarizePluginModuleRelations(moduleNodes)
  const moduleOwnershipClues = findModuleOwnershipClues(pluginModuleRelations)
  const slotHints = slots
    .filter(item => item.count > 1)
    .slice(0, MAX_REPORTED_CLUES)
    .map(item => ({
      kind: 'slot-multiple-mounts',
      severity: 'review',
      ...item,
    }))
  const runtimeClues = runtimeCluesOf(runtimeDiagnostics)
  const clueCandidates = [
    ...cssConflicts,
    ...markerConflicts,
    ...moduleOwnershipClues,
    ...slotHints,
    ...runtimeClues,
  ]
  const clues = clueCandidates.slice(0, MAX_REPORTED_CLUES)
  const report = {
    ...empty,
    title: '',
    pointer: getPointerEvidenceSnapshot(),
    runtime: runtimeDiagnostics.runtime,
    boundaries: runtimeDiagnostics.boundaries,
    moduleSystem: runtimeDiagnostics.moduleSystem,
    slotRegistry: runtimeDiagnostics.slotRegistry,
    host: runtimeDiagnostics.host,
    permission: runtimeDiagnostics.permission,
    session: runtimeDiagnostics.session,
    toolCalls: runtimeDiagnostics.toolCalls,
    capabilities,
    dynamicCordis: runtimeDiagnostics.dynamicCordis,
    pluginInventory: runtimeDiagnostics.pluginInventory,
    slotErrors: runtimeDiagnostics.slotErrors,
    counts: {
      pluginMarkers: pluginNodes.length,
      moduleMarkers: moduleNodes.length,
      slotMarkers: slotNodes.length,
      styleNodes: styleNodes.length,
      cssClasses: styleIndex.size,
      cssConflicts: cssConflicts.length,
      markerConflicts: markerConflicts.length,
      slotHints: slotHints.length,
      moduleOwnershipClues: moduleOwnershipClues.length,
      clues: clueCandidates.length,
      clientErrors: errorCount,
      slotErrors: runtimeDiagnostics.slotErrors.length,
      failedPlugins: runtimeDiagnostics.pluginInventory.entries.filter(entry => entry.fiberPhase === 'failed').length,
      toolResultErrors: runtimeDiagnostics.toolCalls.resultErrors.length,
      turnErrors: runtimeDiagnostics.toolCalls.turnErrors.length,
    },
    plugins,
    modules,
    slots,
    pluginModuleRelations,
    moduleOwnershipClues,
    cssConflicts,
    markerConflicts: markerConflicts.slice(0, MAX_REPORTED_CLUES),
    slotHints,
    clues,
    errors: errorItems,
    truncated: {
      errors: errorCount > MAX_REPORTED_ERRORS,
      clues: clueCandidates.length > MAX_REPORTED_CLUES,
      toolCalls: runtimeDiagnostics.toolCalls.truncated?.any === true,
    },
  }
  return report
}

function formatDiagnosticsReport(report) {
  return JSON.stringify(report, null, 2)
}

function copyDiagnosticsReport(report) {
  if (typeof navigator === 'undefined' || typeof navigator.clipboard?.writeText !== 'function') {
    return Promise.reject(new Error('Clipboard API is unavailable'))
  }
  return navigator.clipboard.writeText(formatDiagnosticsReport(report))
}

function downloadDiagnosticsReport(
  report,
  documentObject = typeof document === 'undefined' ? null : document,
  urlObject = typeof URL === 'undefined' ? null : URL,
  BlobConstructor = typeof Blob === 'undefined' ? null : Blob,
) {
  if (!documentObject || typeof BlobConstructor !== 'function' || typeof urlObject?.createObjectURL !== 'function') {
    return Promise.reject(new Error('Browser download APIs are unavailable'))
  }
  const blob = new BlobConstructor([formatDiagnosticsReport(report)], { type: 'application/json;charset=utf-8' })
  const objectUrl = urlObject.createObjectURL(blob)
  const anchor = documentObject.createElement('a')
  const stamp = String(report?.scannedAt || new Date().toISOString())
    .replace(/[^0-9A-Za-z]+/gu, '-')
    .replace(/-+$/u, '')
  anchor.href = objectUrl
  anchor.download = `${PLUGIN_ID}-diagnostics-${stamp || 'report'}.json`
  anchor.rel = 'noopener'
  anchor.style.display = 'none'
  documentObject.body?.appendChild(anchor)
  try {
    anchor.click()
  } finally {
    anchor.remove?.()
    setTimeout(() => urlObject.revokeObjectURL?.(objectUrl), 0)
  }
  return Promise.resolve()
}

function extractCssClassNames(css) {
  const withoutComments = String(css || '').replace(/\/\*[\s\S]*?\*\//gu, ' ')
  const withoutStrings = withoutComments.replace(/(['"])(?:\\.|(?!\1)[^\\])*\1/gu, ' ')
  const names = new Set()
  for (const match of withoutStrings.matchAll(/(?<![0-9A-Za-z_-])\.([A-Za-z_-][A-Za-z0-9_-]*)/gu)) names.add(match[1])
  return names
}

function collectCssomClassNames(rules, names) {
  if (!rules) return
  for (const rule of Array.from(rules)) {
    if (typeof rule.selectorText === 'string') {
      for (const name of extractCssClassNames(rule.selectorText)) names.add(name)
    }
    if (rule.cssRules) collectCssomClassNames(rule.cssRules, names)
  }
}

function classNamesFromStyle(style) {
  const names = new Set()
  let cssomRead = false
  try {
    if (style.sheet?.cssRules) {
      cssomRead = true
      collectCssomClassNames(style.sheet.cssRules, names)
    }
  } catch {
    // Cross-origin or partially constructed stylesheets may reject CSSOM access.
  }
  // CSSOM is the preferred source because it excludes declarations, comments,
  // and quoted strings. The fallback is deliberately conservative for test
  // fixtures and runtimes that do not expose a readable stylesheet.
  if (!cssomRead || names.size === 0) {
    for (const name of extractCssClassNames(style.textContent || '')) names.add(name)
  }
  return names
}

function buildStyleIndex(documentObject) {
  const index = new Map()
  if (!documentObject || typeof documentObject.querySelectorAll !== 'function') return index
  const styleNodes = documentObject.querySelectorAll('style[data-plugin]')
  for (const style of styleNodes) {
    const plugin = style.getAttribute('data-plugin') || 'unknown-plugin'
    const module = style.getAttribute('data-plugin-css') || plugin
    const classNames = classNamesFromStyle(style)
    for (const className of classNames) {
      const sources = index.get(className) || []
      if (!sources.some(source => source.plugin === plugin && source.module === module)) {
        sources.push({ plugin, module })
      }
      index.set(className, sources)
    }
  }
  return index
}

function inspectTarget(target, styleIndex, x = 0, y = 0) {
  if (!isElement(target)) return null
  if (typeof target.closest === 'function' && target.closest('[data-dsh-source-inspector]')) return null

  const chain = []
  let current = target
  while (isElement(current) && chain.length < MAX_POINTER_ANCESTORS) {
    chain.push(current)
    current = current.parentElement
  }
  const ancestorLimitReached = isElement(current)

  const pluginNode = chain.find(element => element.getAttribute('data-dsh-plugin')) || null
  const moduleNode = chain.find(element => element.getAttribute('data-dsh-module')) || null
  const explicitPlugin = pluginNode?.getAttribute('data-dsh-plugin') || null
  const explicitModule = moduleNode?.getAttribute('data-dsh-module') || null
  const slot = chain.find(element => element.getAttribute('data-slot'))?.getAttribute('data-slot') || null
  const sources = []
  const classNames = []
  for (const element of chain) {
    for (const className of classNamesOf(element)) {
      if (!classNames.includes(className)) classNames.push(className)
      for (const source of styleIndex?.get(className) || []) {
        if (!sources.some(item => item.plugin === source.plugin && item.module === source.module)) {
          sources.push(source)
        }
      }
    }
  }

  const cssSource = sources[0] || null
  const plugin = explicitPlugin || cssSource?.plugin || null
  const module = explicitModule || cssSource?.module || null
  const confidence = explicitPlugin ? 'high' : cssSource ? 'medium' : slot ? 'low' : 'none'
  const tagName = String(target.tagName || 'node').toUpperCase()
  const role = target.getAttribute('role')
  const safeRole = typeof role === 'string' && /^[A-Za-z][A-Za-z0-9_-]{0,31}$/u.test(role) ? role : null
  const node = `${tagName.toLowerCase()}${safeRole ? ` [role=${safeRole}]` : ''}`
  const evidence = explicitPlugin
    ? 'data-dsh-plugin'
    : cssSource
      ? `data-plugin-css=${cssSource.module}`
      : slot
        ? 'data-slot'
        : 'none'
  const positionKey = `${Math.floor(x / 8)}:${Math.floor(y / 8)}`
  return {
    plugin,
    module,
    slot,
    confidence,
    evidence,
    node,
    className: classNames[0] || null,
    sources: sources.slice(0, 4),
    ancestorCount: chain.length,
    ancestorLimitReached,
    sourceSearchIncomplete: ancestorLimitReached,
    left: x + 14,
    top: y + 14,
    key: [plugin, module, slot, node, classNames.slice(0, 3).join(','), positionKey].join('|'),
  }
}

function startupDiagnosticStatusLabel(t, state) {
  if (state?.status === 'creating') return t('startupDiagnosticPending')
  if (state?.status === 'created') return t('startupDiagnosticCreated')
  if (state?.status === 'deduplicated') return t('startupDiagnosticDeduplicated')
  if (state?.status === 'error') return `${t('startupDiagnosticError')}: ${state.error || t('unknown')}`
  return t('startupDiagnosticUnavailable')
}

function StartupGuardBanner({ t, notice, diagnosticState, onOpen, onDismiss }) {
  if (!notice) return null
  const entries = startupDiagnosticEntries()
  const names = entries.map(entry => entry.moduleName).filter(Boolean).join(', ')
  return createElement(
    'div',
    {
      'data-dsh-plugin': PLUGIN_ID,
      'data-dsh-module': 'StartupGuardNotice',
      role: 'status',
      style: styles.startupBanner,
    },
    createElement('strong', { style: styles.startupBannerTitle }, t('startupGuardTitle')),
    createElement('p', { style: styles.startupBannerText }, t('startupGuardMessage')),
    names ? createElement('p', { style: styles.startupBannerText }, `插件：${names}`) : null,
    createElement('p', { style: styles.startupBannerText }, startupDiagnosticStatusLabel(t, diagnosticState)),
    createElement('div', { style: styles.startupBannerActions },
      createElement('button', {
        type: 'button',
        onClick: onOpen,
        style: styles.startupBannerButton,
      }, t('startupGuardOpen')),
      createElement('button', {
        type: 'button',
        onClick: onDismiss,
        style: styles.startupBannerButton,
      }, t('startupGuardDismiss')),
    ),
  )
}

function confidenceLabel(t, confidence) {
  return confidence === 'high'
    ? t('high')
    : confidence === 'medium'
      ? t('medium')
      : confidence === 'low'
        ? t('low')
        : t('none')
}

function ProvenanceOverlay({ t }) {
  const [enabled, setEnabledState] = useState(readEnabled)
  const [info, setInfo] = useState(null)
  const [notice, setNotice] = useState(startupGuardNotice)
  const [diagnosticState, setDiagnosticState] = useState(getStartupDiagnosticState)

  useEffect(() => {
    if (typeof document === 'undefined') return undefined
    const onStartupGuard = () => {
      setNotice(startupGuardNotice)
      setDiagnosticState(getStartupDiagnosticState())
    }
    document.addEventListener(STARTUP_GUARD_EVENT, onStartupGuard)
    return () => {
      document.removeEventListener(STARTUP_GUARD_EVENT, onStartupGuard)
    }
  }, [])

  useEffect(() => {
    if (typeof document === 'undefined') return undefined
    const onToggle = () => {
      setEnabledState(readEnabled())
      setInfo(null)
      setCurrentPointerInfo(null)
    }
    document.addEventListener(TOGGLE_EVENT, onToggle)
    if (!enabled) return () => document.removeEventListener(TOGGLE_EVENT, onToggle)

    let styleIndex = buildStyleIndex(document)
    let frame = 0
    let lastEvent = null
    let lastKey = ''
    const flush = () => {
      frame = 0
      if (!lastEvent) return
      const next = inspectTarget(lastEvent.target, styleIndex, lastEvent.clientX, lastEvent.clientY)
      if (!next) {
        lastKey = ''
        setInfo(null)
        setCurrentPointerInfo(null)
        return
      }
      const viewportWidth = document.documentElement?.clientWidth || 1024
      const viewportHeight = document.documentElement?.clientHeight || 768
      const maxOverlayHeight = Math.min(320, Math.max(120, viewportHeight - 16))
      next.left = Math.min(Math.max(8, next.left), Math.max(8, viewportWidth - 398))
      next.top = Math.min(Math.max(8, next.top), Math.max(8, viewportHeight - maxOverlayHeight - 8))
      if (next.key !== lastKey) {
        lastKey = next.key
        setCurrentPointerInfo(next)
        setInfo(next)
      }
    }
    const schedule = () => {
      if (frame) return
      if (typeof requestAnimationFrame === 'function') frame = requestAnimationFrame(flush)
      else frame = setTimeout(flush, 0)
    }
    const onMove = event => {
      lastEvent = event
      schedule()
    }
    const onOut = event => {
      if (!event.relatedTarget) {
        setInfo(null)
        setCurrentPointerInfo(null)
      }
    }
    document.addEventListener('pointermove', onMove, true)
    document.addEventListener('pointerout', onOut, true)

    let styleObserver
    if (typeof MutationObserver === 'function' && document.head) {
      styleObserver = new MutationObserver(() => { styleIndex = buildStyleIndex(document) })
      styleObserver.observe(document.head, { subtree: true, childList: true, characterData: true })
    }
    return () => {
      document.removeEventListener(TOGGLE_EVENT, onToggle)
      document.removeEventListener('pointermove', onMove, true)
      document.removeEventListener('pointerout', onOut, true)
      styleObserver?.disconnect()
      if (frame) {
        if (typeof cancelAnimationFrame === 'function') cancelAnimationFrame(frame)
        else clearTimeout(frame)
      }
      setCurrentPointerInfo(null)
    }
  }, [enabled])

  const banner = createElement(StartupGuardBanner, {
    t,
    notice,
    diagnosticState,
    onOpen: () => {
      try { document.dispatchEvent(new Event(OPEN_DIAGNOSTICS_EVENT)) } catch { /* minimal DOM fixture */ }
    },
    onDismiss: () => {
      dismissStartupGuardNotice()
      setNotice(null)
    },
  })
  if (!enabled || !info) return banner
  const sourceRows = info.sources.map((source, index) => createElement(
    'div',
    { key: `${source.plugin}-${source.module}-${index}`, style: styles.overlaySource },
    `${source.plugin} / ${source.module}`,
  ))
  return createElement(
    'div',
    { style: styles.shellOverlay },
    banner,
    createElement(
      'div',
      {
        'data-dsh-source-inspector': 'overlay',
        style: { ...styles.overlay, left: `${info.left}px`, top: `${info.top}px` },
      },
      createElement('strong', { style: styles.overlayTitle }, t('titleOverlay')),
      createElement('div', { style: styles.overlayRow }, `${t('plugin')}: ${info.plugin || t('unknown')}`),
      createElement('div', { style: styles.overlayRow }, `${t('module')}: ${info.module || t('unknown')}`),
      info.slot ? createElement('div', { style: styles.overlayRow }, `${t('slot')}: ${info.slot}`) : null,
      createElement('div', { style: styles.overlayRow }, `${t('evidence')}: ${info.evidence}`),
      createElement('div', { style: styles.overlayRow }, `${t('node')}: ${info.node}`),
      createElement('div', { style: styles.overlayConfidence }, confidenceLabel(t, info.confidence)),
      info.confidence === 'none' ? createElement('div', { style: styles.overlayRow }, t('unknownSource')) : null,
      sourceRows.length > 1 ? createElement('div', { style: styles.overlaySources }, sourceRows) : null,
    ),
  )
}

function metricRow(label, value) {
  return createElement(
    'div',
    { key: label, style: styles.metric },
    createElement('dt', { style: styles.metricLabel }, label),
    createElement('dd', { style: styles.metricValue }, String(value)),
  )
}

function runtimeMetricValue(t, value) {
  return value === 'present' || value === 'ready'
    ? t('present')
    : value === 'missing' || value === 'not-observed'
      ? t('missing')
      : t('unavailable')
}

function runtimeItemText(item) {
  if (item.kind === 'permission-default-full-access') return `permission default=${item.defaultPreset || 'unknown'}, sandbox=${item.sandboxMode || 'unknown'}, approval=${item.approvalPolicy || 'unknown'}; review whether the model is requesting escalation before a real denial`
  if (item.kind === 'runtime-plugin-failed') return `${item.moduleName || item.entryId}: ${item.fiberPhase || 'failed'}`
  if (item.kind === 'runtime-plugin-disabled') return `${item.moduleName || item.entryId}: disabled`
  if (item.kind === 'slot-entry-render-error') return `${item.slot}: ${item.registrant || 'unknown registrant'} — ${item.error?.message || 'render error'}`
  if (item.kind === 'tool-result-error') return `${item.callId || 'unknown call'}: ${item.error?.code || item.error?.message || 'tool result error'}`
  if (item.kind === 'turn-error') return `turn ${item.turn ?? '?'} / step ${item.step ?? '?'}: ${item.message || 'turn error'}`
  if (item.kind === 'dynamic-plugin-run-error') return `${item.pluginId}: ${item.error?.message || item.reason || 'run error'}`
  if (item.kind === 'dynamic-plugin-render-error') return `${item.pluginId} / ${item.slot || 'unknown slot'}: ${item.error?.message || 'render error'}`
  if (item.kind === 'slot-single-multiple-occupants') return `${item.name}: ${item.occupants.length} occupants in a single Slot`
  if (item.kind === 'slot-duplicate-cell') return `${item.name} / ${item.cell}: ${item.occupants.length} occupants at the same priority`
  if (item.error?.message) return `${item.kind}: ${item.error.message}`
  return item.kind || 'runtime clue'
}

function DiagnosticsPanel({ t, report, onRescan, onCopy, onDownload, onClear, copyState, downloadState }) {
  const moduleLoader = report.runtime.moduleLoader === 'present'
    ? t('present')
    : report.runtime.moduleLoader === 'missing'
      ? t('missing')
      : t('unavailable')
  const copyLabel = copyState === 'copied'
    ? t('copied')
    : copyState === 'failed'
      ? t('copyFailed')
      : t('copyReport')
  const downloadLabel = downloadState === 'downloaded'
    ? t('downloaded')
    : downloadState === 'failed'
      ? t('downloadFailed')
      : t('downloadReport')
  const conflictItems = [
    ...report.cssConflicts.slice(0, 6).map(item => `${item.className}: ${item.sources.map(source => `${source.plugin} / ${source.module}`).join(' | ')}`),
    ...report.markerConflicts.slice(0, 6).map(item => `${item.node}: ${item.plugin} != ${item.cssSources.map(source => source.plugin).join(', ')}`),
    ...report.moduleOwnershipClues.slice(0, 6).map(item => `${item.module}: ${item.plugins.join(' | ')} (${item.occurrences} markers)`),
    ...report.slotHints.slice(0, 6).map(item => `${item.value}: ${item.count} mounts`),
  ]
  const runtimeItems = report.clues
    .filter(item => !['css-class-multiple-sources', 'dom-css-source-mismatch', 'module-multiple-plugin-owners', 'slot-multiple-mounts'].includes(item.kind))
    .slice(0, 12)
    .map(runtimeItemText)
  const toolItems = [
    ...report.toolCalls.resultErrors.slice(0, 8).map(item => runtimeItemText({ kind: 'tool-result-error', ...item })),
    ...report.toolCalls.turnErrors.slice(0, 8).map(item => runtimeItemText({ kind: 'turn-error', ...item })),
    ...report.toolCalls.running.slice(0, 8).map(item => `${item.name || 'unknown tool'} (${item.callId || 'unknown call'}): ${t('runningToolCall')}`),
  ]
  return createElement(
    'div',
    { style: styles.diagnostics },
    createElement('h3', { style: styles.subTitle }, t('diagnosticsTitle')),
    createElement('p', { style: styles.muted }, t('diagnosticsHint')),
    createElement('div', { style: styles.toolbar },
      createElement('button', { type: 'button', onClick: onRescan, style: styles.button }, t('rescan')),
      createElement('button', { type: 'button', onClick: onCopy, style: styles.button }, copyLabel),
      createElement('button', { type: 'button', onClick: onDownload, style: styles.button }, downloadLabel),
      report.counts.clientErrors > 0 ? createElement('button', { type: 'button', onClick: onClear, style: styles.button }, t('clearErrors')) : null,
    ),
    createElement('h4', { style: styles.sectionLabel }, t('runtime')),
    createElement('dl', { style: styles.metrics },
      metricRow(t('page'), report.page),
      metricRow(t('moduleLoader'), moduleLoader),
      metricRow(t('moduleSystem'), runtimeMetricValue(t, report.runtime.moduleSystem)),
      metricRow(t('slotRegistry'), runtimeMetricValue(t, report.runtime.slotRegistry)),
      metricRow(t('hostStatus'), `${runtimeMetricValue(t, report.runtime.hostStatus)} / ${report.host.connectionState}`),
      metricRow(t('modelRoute'), `${report.host.description?.provider || t('unknown')} / ${report.host.description?.model || t('unknown')}`),
      metricRow(t('permissionStatus'), runtimeMetricValue(t, report.runtime.permissionStatus)),
      metricRow(t('permissionDefault'), report.permission.defaultPreset || t('unknown')),
      metricRow(t('sandboxMode'), report.permission.sandboxMode || t('unknown')),
      metricRow(t('approvalPolicy'), report.permission.approvalPolicy || t('unknown')),
      metricRow(t('sessionStatus'), runtimeMetricValue(t, report.runtime.sessionStatus)),
      metricRow(t('pluginInventory'), runtimeMetricValue(t, report.runtime.hostPluginInventory)),
      metricRow(t('dynamicCordis'), runtimeMetricValue(t, report.runtime.dynamicCordis)),
      metricRow(t('clientErrors'), report.counts.clientErrors),
      metricRow(t('pointerEvidence'), report.pointer?.current?.confidence || t('unknown')),
    ),
    createElement('h4', { style: styles.sectionLabel }, t('runtimeSignals')),
    createElement('dl', { style: styles.metrics },
      metricRow(t('runningCalls'), report.toolCalls.running.length),
      metricRow(t('toolResultErrors'), report.toolCalls.resultErrors.length),
      metricRow(t('turnErrors'), report.toolCalls.turnErrors.length),
      metricRow(t('slotErrors'), report.slotErrors.length),
      metricRow(t('loadedPackages'), report.dynamicCordis.loaded.length),
      metricRow(t('failedPlugins'), report.counts.failedPlugins),
    ),
    runtimeItems.length === 0
      ? createElement('p', { style: styles.muted }, t('noConflicts'))
      : createElement('ul', { style: styles.diagnosticsList }, runtimeItems.map((item, index) => createElement('li', { key: `${item}-${index}` }, item))),
    createElement('p', { style: styles.muted }, t('runtimeFailureHint')),
    createElement('h4', { style: styles.sectionLabel }, t('counts')),
    createElement('dl', { style: styles.metrics },
      metricRow(t('pluginMarkers'), report.counts.pluginMarkers),
      metricRow(t('moduleMarkers'), report.counts.moduleMarkers),
      metricRow(t('slotMarkers'), report.counts.slotMarkers),
      metricRow(t('styleNodes'), report.counts.styleNodes),
      metricRow(t('cssClasses'), report.counts.cssClasses),
      metricRow(t('cssConflicts'), report.counts.cssConflicts),
      metricRow(t('markerConflicts'), report.counts.markerConflicts),
      metricRow(t('slotHints'), report.counts.slotHints),
      metricRow(t('moduleOwnershipClues'), report.counts.moduleOwnershipClues),
    ),
    createElement('h4', { style: styles.sectionLabel }, t('cluesTitle')),
    conflictItems.length === 0
      ? createElement('p', { style: styles.muted }, t('noConflicts'))
      : createElement('ul', { style: styles.diagnosticsList }, conflictItems.map((item, index) => createElement('li', { key: `${item}-${index}` }, item))),
    createElement('p', { style: styles.muted }, t('conflictHint')),
    createElement('h4', { style: styles.sectionLabel }, t('clientErrors')),
    report.errors.length === 0
      ? createElement('p', { style: styles.muted }, t('noErrors'))
      : createElement('ul', { style: styles.diagnosticsList }, report.errors.map((error, index) => createElement('li', { key: `${error.time}-${index}` }, `${error.time} [${error.kind}] ${error.message}`))),
    createElement('p', { style: styles.muted }, t('clientErrorHint')),
    createElement('h4', { style: styles.sectionLabel }, t('toolCallBoundary')),
    toolItems.length === 0
      ? createElement('p', { style: styles.muted }, report.toolCalls.status === 'no-session' ? t('noSession') : t('noToolCallErrors'))
      : createElement('ul', { style: styles.diagnosticsList }, toolItems.map((item, index) => createElement('li', { key: `${item}-${index}` }, item))),
    createElement('p', { style: styles.muted }, t('toolCallHint')),
    createElement('p', { style: styles.muted }, t('reportPrivacy')),
    createElement('details', { style: styles.reportDetails },
      createElement('summary', { style: styles.reportSummary }, t('reportPreview')),
      createElement('pre', { style: styles.report }, formatDiagnosticsReport(report)),
    ),
  )
}

function ProvenanceSettings({ t }) {
  const [enabled, setEnabledState] = useState(readEnabled)
  const [view, setView] = useState('inspector')
  const [report, setReport] = useState(() => scanDiagnostics(typeof document === 'undefined' ? null : document))
  const [copyState, setCopyState] = useState('idle')
  const [downloadState, setDownloadState] = useState('idle')

  useEffect(() => {
    installClientErrorCapture()
    if (typeof document === 'undefined') return undefined
    const onToggle = () => setEnabledState(readEnabled())
    const refresh = () => setReport(scanDiagnostics(document))
    const onStartupGuard = () => refresh()
    const onOpenDiagnostics = () => setView('diagnostics')
    document.addEventListener(TOGGLE_EVENT, onToggle)
    document.addEventListener(DIAGNOSTICS_EVENT, refresh)
    document.addEventListener(STARTUP_GUARD_EVENT, onStartupGuard)
    document.addEventListener(OPEN_DIAGNOSTICS_EVENT, onOpenDiagnostics)
    refresh()
    void maybeCreateStartupDiagnosticSession(runtimeContext)
    return () => {
      document.removeEventListener(TOGGLE_EVENT, onToggle)
      document.removeEventListener(DIAGNOSTICS_EVENT, refresh)
      document.removeEventListener(STARTUP_GUARD_EVENT, onStartupGuard)
      document.removeEventListener(OPEN_DIAGNOSTICS_EVENT, onOpenDiagnostics)
    }
  }, [])

  const toggle = () => {
    const next = !enabled
    setEnabled(next)
    setEnabledState(next)
  }
  const rescan = () => setReport(scanDiagnostics(typeof document === 'undefined' ? null : document))
  const copy = async () => {
    try {
      await copyDiagnosticsReport(report)
      setCopyState('copied')
    } catch {
      setCopyState('failed')
    }
    setTimeout(() => setCopyState('idle'), 2200)
  }
  const download = async () => {
    try {
      await downloadDiagnosticsReport(report)
      setDownloadState('downloaded')
    } catch {
      setDownloadState('failed')
    }
    setTimeout(() => setDownloadState('idle'), 2200)
  }
  const clear = () => {
    clearClientErrors()
    rescan()
  }
  return createElement(
    'section',
    {
      style: styles.section,
      'data-dsh-plugin': PLUGIN_ID,
      'data-dsh-module': 'ProvenanceSettings',
      'data-dsh-provenance-api': '1',
    },
    createElement('h2', { style: styles.title }, t('title')),
    createElement('div', { style: styles.tabBar },
      createElement('button', {
        type: 'button',
        onClick: () => setView('inspector'),
        style: view === 'inspector' ? styles.tabButtonActive : styles.tabButton,
        'aria-pressed': view === 'inspector',
      }, t('inspectorTab')),
      createElement('button', {
        type: 'button',
        onClick: () => setView('diagnostics'),
        style: view === 'diagnostics' ? styles.tabButtonActive : styles.tabButton,
        'aria-pressed': view === 'diagnostics',
      }, t('diagnosticsTab')),
    ),
    view === 'diagnostics'
      ? createElement(DiagnosticsPanel, { t, report, onRescan: rescan, onCopy: copy, onDownload: download, onClear: clear, copyState, downloadState })
      : createElement('div', { style: styles.inspector },
        createElement('p', { style: styles.muted }, t('hint')),
        createElement('button', {
          type: 'button',
          onClick: toggle,
          style: enabled ? styles.primary : styles.button,
          'aria-pressed': enabled,
        }, enabled ? t('disable') : t('enable')),
        createElement('p', { role: 'status', style: styles.status }, enabled ? t('enabled') : t('disabled')),
        createElement('h3', { style: styles.subTitle }, t('nodeTypes')),
        createElement('ul', { style: styles.list },
          createElement('li', null, t('high')),
          createElement('li', null, t('medium')),
          createElement('li', null, t('low')),
          createElement('li', null, t('none')),
        ),
        createElement('p', { style: styles.muted }, t('limitation')),
      ),
  )
}

function apply(ctx) {
  ctx.effect(() => ctx.locale.register(NS, { zh, en }), `${PLUGIN_ID}: dictionaries`)
  // Keep the read-only browser bridge for the lifetime of this loaded client
  // module. Some host versions execute an effect's returned function as an
  // immediate disposer when the bundle is mounted, which would remove the
  // bridge while the visible settings UI remains active.
  installProvenanceApi()
  installRuntimeDiagnostics(ctx)
  const t = ctx.locale.bind(NS)
  ctx.slots.inject('settings.plugins.tab', () => ctx.slots.register({
    name: 'settings.plugins.tab',
    id: PLUGIN_ID,
    order: 30,
    label: () => t('tab'),
    locale: NS,
    inject: () => ({ t }),
  }, ProvenanceSettings))
  ctx.slots.inject('shell.overlay', () => ctx.slots.register({
    name: 'shell.overlay',
    id: `${PLUGIN_ID}.overlay`,
    order: 90,
    locale: NS,
    inject: () => ({ t }),
  }, ProvenanceOverlay))
}

const styles = {
  shellOverlay: { position: 'fixed', inset: 0, zIndex: 2147483647, pointerEvents: 'none' },
  notice: { position: 'fixed', top: '12px', right: '12px', zIndex: 2147483647, width: 'min(430px, calc(100vw - 24px))', boxSizing: 'border-box', padding: '12px 14px', border: '1px solid var(--dsw-alias-state-danger-primary)', borderRadius: '8px', color: 'var(--dsw-alias-label-primary)', background: 'var(--dsw-alias-bg-layer-3)', boxShadow: '0 8px 28px rgba(0, 0, 0, .24)', pointerEvents: 'auto', fontSize: '12px', lineHeight: '18px' },
  noticeTitle: { display: 'block', marginBottom: '5px', fontSize: '13px' },
  noticeText: { display: 'block', marginBottom: '8px', color: 'var(--dsw-alias-label-secondary)', overflowWrap: 'anywhere' },
  noticeButton: { border: '1px solid var(--dsw-alias-border-l2)', borderRadius: '6px', padding: '6px 9px', color: 'inherit', background: 'transparent', cursor: 'pointer', font: 'inherit', fontSize: '11px', pointerEvents: 'auto' },
  startupBanner: { position: 'fixed', top: '12px', right: '12px', zIndex: 2147483647, width: 'min(430px, calc(100vw - 24px))', boxSizing: 'border-box', padding: '12px 14px', border: '1px solid var(--dsw-alias-state-danger-primary)', borderRadius: '8px', color: 'var(--dsw-alias-label-primary)', background: 'var(--dsw-alias-bg-layer-3)', boxShadow: '0 8px 28px rgba(0, 0, 0, .24)', pointerEvents: 'auto', fontSize: '12px', lineHeight: '18px' },
  startupBannerTitle: { display: 'block', marginBottom: '5px', fontSize: '13px' },
  startupBannerText: { margin: '4px 0', color: 'var(--dsw-alias-label-secondary)', overflowWrap: 'anywhere' },
  startupBannerActions: { display: 'flex', flexWrap: 'wrap', gap: '7px', marginTop: '9px' },
  startupBannerButton: { border: '1px solid var(--dsw-alias-border-l2)', borderRadius: '6px', padding: '6px 9px', color: 'inherit', background: 'transparent', cursor: 'pointer', font: 'inherit', fontSize: '11px', pointerEvents: 'auto' },
  section: { width: '100%', maxWidth: '720px', color: 'var(--dsw-alias-label-primary)', display: 'flex', flexDirection: 'column', gap: '12px' },
  title: { margin: 0, fontSize: '16px' },
  inspector: { display: 'flex', flexDirection: 'column', gap: '12px' },
  tabBar: { display: 'flex', flexWrap: 'wrap', gap: '6px', paddingBottom: '2px', borderBottom: '1px solid var(--dsw-alias-border-l2)' },
  tabButton: { border: '1px solid var(--dsw-alias-border-l2)', borderRadius: '6px', padding: '6px 10px', color: 'var(--dsw-alias-label-secondary)', background: 'transparent', cursor: 'pointer', font: 'inherit', fontSize: '12px' },
  tabButtonActive: { border: '1px solid var(--dsw-alias-state-business-primary)', borderRadius: '6px', padding: '6px 10px', color: 'var(--dsw-alias-state-business-primary)', background: 'var(--dsw-alias-bg-layer-1)', cursor: 'pointer', font: 'inherit', fontSize: '12px' },
  subTitle: { margin: '8px 0 0', fontSize: '13px' },
  list: { margin: 0, paddingLeft: '20px', color: 'var(--dsw-alias-label-secondary)', fontSize: '12px', lineHeight: '20px' },
  button: { alignSelf: 'flex-start', border: '1px solid var(--dsw-alias-border-l2)', borderRadius: '6px', padding: '7px 11px', color: 'inherit', background: 'transparent', cursor: 'pointer', font: 'inherit', fontSize: '12px' },
  primary: { alignSelf: 'flex-start', border: 0, borderRadius: '6px', padding: '8px 12px', color: 'white', background: 'var(--dsw-alias-state-business-primary)', cursor: 'pointer', font: 'inherit', fontSize: '12px' },
  status: { margin: 0, color: 'var(--dsw-alias-label-secondary)', fontSize: '12px' },
  muted: { margin: 0, color: 'var(--dsw-alias-label-tertiary)', fontSize: '12px', lineHeight: '18px' },
  diagnostics: { display: 'flex', flexDirection: 'column', gap: '10px' },
  toolbar: { display: 'flex', flexWrap: 'wrap', gap: '7px', alignItems: 'center' },
  sectionLabel: { margin: '8px 0 0', fontSize: '12px' },
  metrics: { display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))', gap: '7px', margin: 0 },
  metric: { display: 'grid', gridTemplateColumns: 'minmax(0, 1fr) auto', gap: '8px', padding: '7px 8px', borderRadius: '6px', background: 'var(--dsw-alias-bg-layer-1)' },
  metricLabel: { color: 'var(--dsw-alias-label-tertiary)', fontSize: '11px' },
  metricValue: { margin: 0, maxWidth: '260px', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', color: 'var(--dsw-alias-label-secondary)', fontSize: '11px' },
  diagnosticsList: { margin: 0, paddingLeft: '20px', color: 'var(--dsw-alias-label-secondary)', fontSize: '11px', lineHeight: '17px', overflowWrap: 'anywhere' },
  reportDetails: { marginTop: '3px', borderTop: '1px solid var(--dsw-alias-border-l2)', paddingTop: '8px' },
  reportSummary: { color: 'var(--dsw-alias-label-secondary)', cursor: 'pointer', fontSize: '11px' },
  report: { maxHeight: '280px', margin: '8px 0 0', padding: '8px', overflow: 'auto', borderRadius: '6px', background: 'var(--dsw-alias-bg-layer-1)', color: 'var(--dsw-alias-label-secondary)', fontSize: '10px', lineHeight: '15px', whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' },
  overlay: { position: 'fixed', zIndex: 2147483647, width: 'min(390px, calc(100vw - 28px))', maxHeight: 'min(320px, calc(100vh - 16px))', boxSizing: 'border-box', padding: '10px 12px', border: '1px solid var(--dsw-alias-border-l2)', borderRadius: '8px', color: 'var(--dsw-alias-label-primary)', background: 'var(--dsw-alias-bg-layer-3)', boxShadow: '0 8px 28px rgba(0, 0, 0, .24)', pointerEvents: 'none', fontSize: '11px', lineHeight: '16px', overflow: 'auto', overflowWrap: 'anywhere' },
  overlayTitle: { display: 'block', marginBottom: '4px', fontSize: '12px' },
  overlayRow: { color: 'var(--dsw-alias-label-secondary)' },
  overlayConfidence: { marginTop: '4px', color: 'var(--dsw-alias-state-business-primary)' },
  overlaySources: { marginTop: '5px', paddingTop: '5px', borderTop: '1px solid var(--dsw-alias-border-l2)', color: 'var(--dsw-alias-label-tertiary)' },
  overlaySource: { whiteSpace: 'normal' },
}

module.exports = {
  PLUGIN_ID,
  NS,
  POINTER_EVENT,
  DEBUG_GLOBAL,
  LEGACY_PROVENANCE_GLOBAL,
  BRIDGE_SELECTOR,
  inject,
  apply,
  ProvenanceSettings,
  ProvenanceOverlay,
  buildStyleIndex,
  extractCssClassNames,
  inspectTarget,
  scanDiagnostics,
  formatDiagnosticsReport,
  downloadDiagnosticsReport,
  installClientErrorCapture,
  getClientErrors,
  clearClientErrors,
  readEnabled,
  setEnabled,
  installProvenanceApi,
  uninstallProvenanceApi,
  getCurrentPointerInfo: () => clonePointerInfo(currentPointerInfo),
  getBridgeSnapshot,
  collectRuntimeDiagnostics,
  snapshotModuleSystem,
  snapshotSlotRegistry,
  snapshotHostStatus,
  snapshotPermissionStatus,
  snapshotSessionStatus,
  snapshotDynamicCordis,
  snapshotPluginInventory,
  refreshPluginInventory,
  recordSlotError,
  readStartupGuardNotice,
  dismissStartupGuardNotice,
  getStartupDiagnosticState,
  startupDiagnosticPrompt,
  maybeCreateStartupDiagnosticSession,
  buildCapabilityStatus,
  CAPABILITY_SCHEMA_VERSION,
}
