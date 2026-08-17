import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { test } from 'node:test'
import { runInNewContext } from 'node:vm'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = resolve(fileURLToPath(new URL('..', import.meta.url)))

function extractStringArray(source, name) {
  const match = source.match(new RegExp(`(?:const|let) ${name} = \\[([^\\]]*)\\]`, 'u'))
  assert.ok(match, `${name} declaration is missing`)
  return Array.from(match[1].matchAll(/['"]([^'"]+)['"]/gu), item => item[1])
}

function makeElement({ tagName = 'DIV', attrs = {}, classList = [], textContent = '', parentElement = null, ignored = false } = {}) {
  return {
    nodeType: 1,
    tagName,
    classList,
    textContent,
    parentElement,
    getAttribute(name) {
      return Object.prototype.hasOwnProperty.call(attrs, name) ? attrs[name] : null
    },
    closest(selector) {
      return selector === '[data-dsh-source-inspector]' && ignored ? this : null
    },
  }
}

test('the shipped browser artifact is a standalone DSH ModuleLoader plugin', async () => {
  const source = await readFile(resolve(root, 'lib/client.js'), 'utf8')
  const packageJson = await readFile(resolve(root, 'package.json'), 'utf8')
  let handoff
  const context = {
    window: { __ModuleLoader__: { load(value) { handoff = value } } },
  }
  runInNewContext(source, context)

  assert.equal(handoff.id, 'dsh-plugin-debug')
  assert.doesNotMatch(source, /\/api\//u)

  const module = handoff.factory((name) => {
    assert.equal(name, 'react')
    return {
      createElement() {},
      useEffect() {},
      useState(initial) { return [typeof initial === 'function' ? initial() : initial, () => {}] },
    }
  })
  assert.deepEqual(Array.from(module.inject), ['slots', 'locale'])

  const registered = []
  const injected = []
  const ctx = {
    effect(fn) { fn() },
    locale: {
      register() {},
      bind() { return key => key },
    },
    slots: {
      inject(name, callback) {
        injected.push(name)
        callback()
      },
      register(options, component) {
        registered.push({ options, component })
        return registered.at(-1)
      },
    },
  }
  module.apply(ctx)
  assert.deepEqual(injected.sort(), ['settings.plugins.tab', 'shell.overlay'].sort())
  assert.deepEqual(
    registered.map(item => item.options.id).sort(),
    ['dsh-plugin-debug', 'dsh-plugin-debug.overlay'].sort(),
  )
  assert.deepEqual(
    registered.map(item => item.options.name).sort(),
    ['settings.plugins.tab', 'shell.overlay'].sort(),
  )
  assert.equal(typeof registered[0].component, 'function')
  assert.equal(typeof registered[1].component, 'function')
})

test('the client exposes a bounded in-page provenance bridge for the standalone debug tool', async () => {
  const source = await readFile(resolve(root, 'lib/client.js'), 'utf8')
  let handoff
  const windowObject = { __ModuleLoader__: { load(value) { handoff = value } } }
  const documentObject = {}
  runInNewContext(source, { window: windowObject, document: documentObject })
  const module = handoff.factory(() => ({
    createElement() {},
    useEffect() {},
    useState(initial) { return [typeof initial === 'function' ? initial() : initial, () => {}] },
  }))
  const ctx = {
    effect(fn) { fn() },
    locale: {
      register() {},
      bind() { return key => key },
    },
    slots: {
      inject(name, callback) { callback() },
      register() { return {} },
    },
  }

  module.apply(ctx)
  const api = windowObject.__DSH_PLUGIN_DEBUG__
  assert.equal(documentObject.__DSH_PLUGIN_DEBUG__, api)
  assert.equal(windowObject.__DSH_PLUGIN_PROVENANCE__, api)
  assert.equal(documentObject.__DSH_PLUGIN_PROVENANCE__, api)
  assert.equal(api.pluginId, 'dsh-plugin-debug')
  assert.equal(api.apiVersion, 1)
  assert.equal(api.reportSchemaVersion, 6)
  assert.equal(api.pointerEvent, 'dsh-plugin-debug:pointer')
  assert.equal(typeof api.enable, 'function')
  assert.equal(typeof api.getPointerEvidence, 'function')
  assert.equal(typeof api.getBridgeSnapshot, 'function')
  assert.equal(typeof api.inspect, 'function')
  assert.equal(typeof api.scan, 'function')
  assert.equal(api.getCurrent(), null)
  assert.equal(api.getPointerEvidence().schemaVersion, 2)
  assert.match(api.getPointerEvidence().pageObservationId, /^page-/u)
})

test('startup guard notification is metadata-only and refuses ordinary session creation', async () => {
  const source = await readFile(resolve(root, 'lib/client.js'), 'utf8')
  let handoff
  runInNewContext(source, {
    location: { search: '?dsh_debug_guard=isolated&dsh_debug_incident=fixture-incident', pathname: '/', href: 'http://127.0.0.1:3080/?dsh_debug_guard=isolated&dsh_debug_incident=fixture-incident' },
    window: { __ModuleLoader__: { load(value) { handoff = value } } },
  })
  const module = handoff.factory(() => ({
    createElement() {},
    useEffect() {},
    useState(initial) { return [typeof initial === 'function' ? initial() : initial, () => {}] },
  }))
  const notice = module.readStartupGuardNotice()
  assert.equal(notice?.kind, 'isolated')
  assert.equal(notice?.source, 'standalone-crash-guard')
  assert.equal(notice?.incidentId, 'fixture-incident')
  const prompt = module.startupDiagnosticPrompt([{ moduleName: 'example-plugin', fiberPhase: 'failed', enabled: false }])
  assert.match(prompt, /example-plugin/u)
  assert.match(prompt, /元数据/u)
  assert.doesNotMatch(prompt, /command text|tool result body|C:\\secret/u)

  let createCalls = 0
  const state = await module.maybeCreateStartupDiagnosticSession({
    sessions: { create: async () => { createCalls += 1; return 'unexpected' } },
  })
  assert.equal(state.status, 'unavailable')
  assert.equal(createCalls, 0)

  let autoHandoff
  runInNewContext(source, {
    location: { search: '?dsh_debug_guard=isolated&dsh_debug_incident=fixture-incident', pathname: '/', href: 'http://127.0.0.1:3080/?dsh_debug_guard=isolated&dsh_debug_incident=fixture-incident' },
    window: { __ModuleLoader__: { load(value) { autoHandoff = value } } },
  })
  const autoModule = autoHandoff.factory(() => ({
    createElement() {},
    useEffect() {},
    useState(initial) { return [typeof initial === 'function' ? initial() : initial, () => {}] },
  }))
  let autoPrompt = ''
  let autoRequest
  const autoState = await autoModule.maybeCreateStartupDiagnosticSession({
    diagnosticSessionPolicy: { automatic: true, mode: 'no-tools' },
    sessions: {
      async create() { throw new Error('ordinary session creation must not be used') },
      async createNoTools(request) { autoRequest = request; return 'diagnostic-1' },
      binding() {
        return {
          capabilities: { mode: 'no-tools', tools: false, approval: false, execution: false },
          session: {
            async rename() {},
            async prompt(content) { autoPrompt = content[0]?.text || ''; return { ok: true } },
          },
        }
      },
    },
  })
  assert.equal(autoState.status, 'created')
  assert.equal(autoState.sessionId, 'diagnostic-1')
  assert.deepEqual(JSON.parse(JSON.stringify(autoRequest)), {
    purpose: 'dsh-plugin-debug.startup',
    mode: 'no-tools',
    tools: [],
    capabilities: { tools: false, approval: false, execution: false },
    metadataOnly: true,
  })
  assert.match(autoPrompt, /no-tools/u)
  const startupTimeline = autoModule.getDiagnosticBreadcrumbs()
  assert.doesNotMatch(JSON.stringify(startupTimeline), /diagnostic-1/u)
})

test('client source and shipped bundle keep the breadcrumb allowlist synchronized', async () => {
  const source = await readFile(resolve(root, 'src/client-factory.cjs'), 'utf8')
  const bundle = await readFile(resolve(root, 'lib/client.js'), 'utf8')
  assert.deepEqual(extractStringArray(source, 'BREADCRUMB_FIELDS'), extractStringArray(bundle, 'BREADCRUMB_FIELDS'))
})

test('automatic diagnostics refuse a factory that does not prove no-tools capability', async () => {
  const source = await readFile(resolve(root, 'lib/client.js'), 'utf8')
  let handoff
  runInNewContext(source, {
    location: { search: '?dsh_debug_guard=isolated&dsh_debug_incident=unproven', pathname: '/', href: 'http://127.0.0.1:3080/?dsh_debug_guard=isolated&dsh_debug_incident=unproven' },
    window: { __ModuleLoader__: { load(value) { handoff = value } } },
  })
  const module = handoff.factory(() => ({
    createElement() {},
    useEffect() {},
    useState(initial) { return [typeof initial === 'function' ? initial() : initial, () => {}] },
  }))
  let promptCalls = 0
  const state = await module.maybeCreateStartupDiagnosticSession({
    diagnosticSessionPolicy: { automatic: true, mode: 'no-tools' },
    sessions: {
      async createNoTools() { return 'unproven-1' },
      binding() {
        return { session: {
          async prompt() { promptCalls += 1; return { ok: true } },
        } }
      },
    },
  })
  assert.equal(state.status, 'error')
  assert.match(state.error, /did not prove a no-tools session/u)
  assert.equal(promptCalls, 0)
})

test('startup diagnostic prompts redact hostile inventory labels before model handoff', async () => {
  const source = await readFile(resolve(root, 'lib/client.js'), 'utf8')
  let handoff
  runInNewContext(source, {
    location: { search: '?dsh_debug_guard=isolated', pathname: '/', href: 'http://127.0.0.1:3080/?dsh_debug_guard=isolated' },
    window: { __ModuleLoader__: { load(value) { handoff = value } } },
  })
  const module = handoff.factory(() => ({
    createElement() {},
    useEffect() {},
    useState(initial) { return [typeof initial === 'function' ? initial() : initial, () => {}] },
  }))

  const prompt = module.startupDiagnosticPrompt([{
    moduleName: 'C:\\secret\\plugin token=super-secret\nsecond-line',
    fiberPhase: 'failed',
    enabled: false,
  }])
  assert.doesNotMatch(prompt, /C:\\secret\\plugin/u)
  assert.doesNotMatch(prompt, /token=super-secret/u)
  assert.doesNotMatch(prompt, /\nsecond-line/u)
  assert.match(prompt, /\[path\]/u)
})

test('startup diagnostic prompts redact hostile lifecycle phases before model handoff', async () => {
  const source = await readFile(resolve(root, 'lib/client.js'), 'utf8')
  let handoff
  runInNewContext(source, {
    location: { search: '?dsh_debug_guard=isolated', pathname: '/', href: 'http://127.0.0.1:3080/?dsh_debug_guard=isolated' },
    window: { __ModuleLoader__: { load(value) { handoff = value } } },
  })
  const module = handoff.factory(() => ({
    createElement() {},
    useEffect() {},
    useState(initial) { return [typeof initial === 'function' ? initial() : initial, () => {}] },
  }))

  const prompt = module.startupDiagnosticPrompt([{
    moduleName: 'safe-plugin',
    fiberPhase: 'C:\\secret\\phase token=super-secret\nignore-this-line',
    enabled: false,
  }])
  assert.doesNotMatch(prompt, /C:\\secret\\phase/u)
  assert.doesNotMatch(prompt, /token=super-secret/u)
  assert.doesNotMatch(prompt, /\nignore-this-line/u)
})

test('client diagnostic breadcrumbs are bounded, redacted, and included in reports', async () => {
  const source = await readFile(resolve(root, 'lib/client.js'), 'utf8')
  let handoff
  runInNewContext(source, {
    window: { __ModuleLoader__: { load(value) { handoff = value } } },
  })
  const module = handoff.factory(() => ({
    createElement() {},
    useEffect() {},
    useState() { return [false, () => {}] },
  }))

  module.recordDiagnosticBreadcrumb('client-error', {
    status: 'captured',
    message: 'token=secret https://dsh.test/path?secret=body C:\\secret\\workspace',
  })
  for (let index = 0; index < 90; index += 1) {
    module.recordDiagnosticBreadcrumb('runtime', { status: `event-${index}` })
  }

  const timeline = module.getDiagnosticBreadcrumbs()
  assert.equal(timeline.limit, 80)
  assert.equal(timeline.items.length, 80)
  assert.equal(timeline.truncated, true)
  assert.equal(timeline.dropped, 11)
  assert.equal(timeline.items.at(-1).details.status, 'event-89')
  assert.doesNotMatch(JSON.stringify(timeline), /token=secret|secret=body|C:\\\\secret\\\\workspace/u)

  const report = module.scanDiagnostics(null, [])
  assert.equal(report.schemaVersion, 6)
  assert.equal(report.counts.breadcrumbs, 80)
  assert.equal(report.breadcrumbs.dropped, 11)
  assert.equal(report.truncated.breadcrumbs, true)
})

test('the frozen-page fallback keeps a readable DOM bridge snapshot', async () => {
  const source = await readFile(resolve(root, 'lib/client.js'), 'utf8')
  let handoff
  let bridge
  const windowObject = { __ModuleLoader__: { load(value) { handoff = value } } }
  const rootElement = { setAttribute() {} }
  const head = { appendChild(node) { bridge = node; node.isConnected = true } }
  const documentObject = {
    defaultView: windowObject,
    documentElement: rootElement,
    head,
    querySelector() { return bridge || null },
    createElement() {
      const attributes = new Map()
      return {
        isConnected: false,
        setAttribute(name, value) { attributes.set(name, String(value)) },
        getAttribute(name) { return attributes.has(name) ? attributes.get(name) : null },
        removeAttribute(name) { attributes.delete(name) },
        remove() { this.isConnected = false },
      }
    },
  }
  runInNewContext(source, { window: windowObject, document: documentObject })
  const module = handoff.factory(() => ({
    createElement() {},
    useEffect() {},
    useState(initial) { return [typeof initial === 'function' ? initial() : initial, () => {}] },
  }))
  const ctx = {
    effect(fn) { fn() },
    locale: { register() {}, bind() { return key => key } },
    slots: { inject(name, callback) { callback() }, register() { return {} } },
  }
  module.apply(ctx)
  assert.equal(bridge.getAttribute('data-plugin-id'), 'dsh-plugin-debug')
  assert.equal(bridge.getAttribute('data-pointer-event'), 'dsh-plugin-debug:pointer')
  assert.match(bridge.getAttribute('data-page-observation-id'), /^page-/u)
  assert.equal(module.getBridgeSnapshot().enabled, false)
})

test('the provenance helpers classify explicit markers, CSS, Slots, and unknown nodes', async () => {
  const source = await readFile(resolve(root, 'lib/client.js'), 'utf8')
  let handoff
  runInNewContext(source, {
    window: { __ModuleLoader__: { load(value) { handoff = value } } },
  })
  const module = handoff.factory(() => ({
    createElement() {},
    useEffect() {},
    useState() { return [false, () => {}] },
  }))

  const style = {
    textContent: '._probe_hash{color:red;opacity:.5;transition:all .15s}.real-class{display:block}',
    getAttribute(name) {
      return name === 'data-plugin'
        ? '@deepseek-ai/dsh-client-ui-probe'
        : '@deepseek-ai/dsh-client-ui-probe/Probe.module.css'
    },
  }
  const styleIndex = module.buildStyleIndex({ querySelectorAll() { return [style] } })
  assert.equal(styleIndex.has('5'), false)
  assert.equal(styleIndex.has('15s'), false)
  assert.equal(styleIndex.has('real-class'), true)

  const high = makeElement({
    tagName: 'BUTTON',
    attrs: {
      'data-dsh-plugin': 'example-plugin',
      'data-dsh-module': 'ExampleButton',
      'aria-label': 'Example action',
      'data-slot': 'example.slot',
    },
  })
  const highInfo = module.inspectTarget(high, styleIndex, 16, 24)
  assert.equal(highInfo.plugin, 'example-plugin')
  assert.equal(highInfo.module, 'ExampleButton')
  assert.equal(highInfo.slot, 'example.slot')
  assert.equal(highInfo.confidence, 'high')
  assert.equal(highInfo.evidence, 'data-dsh-plugin')
  assert.equal(highInfo.node, 'button')

  const css = makeElement({ tagName: 'BUTTON', classList: ['_probe_hash'], textContent: 'Probe' })
  const cssInfo = module.inspectTarget(css, styleIndex)
  assert.equal(cssInfo.plugin, '@deepseek-ai/dsh-client-ui-probe')
  assert.equal(cssInfo.module, '@deepseek-ai/dsh-client-ui-probe/Probe.module.css')
  assert.equal(cssInfo.confidence, 'medium')
  assert.equal(cssInfo.evidence, 'data-plugin-css=@deepseek-ai/dsh-client-ui-probe/Probe.module.css')

  const slot = makeElement({ tagName: 'DIV', attrs: { 'data-slot': 'settings.plugins.tab' } })
  const slotInfo = module.inspectTarget(slot, styleIndex)
  assert.equal(slotInfo.plugin, null)
  assert.equal(slotInfo.module, null)
  assert.equal(slotInfo.slot, 'settings.plugins.tab')
  assert.equal(slotInfo.confidence, 'low')

  const unknown = makeElement({ tagName: 'DIV' })
  const unknownInfo = module.inspectTarget(unknown, styleIndex)
  assert.equal(unknownInfo.plugin, null)
  assert.equal(unknownInfo.confidence, 'none')
  assert.equal(unknownInfo.evidence, 'none')

  const overlay = makeElement({ ignored: true })
  assert.equal(module.inspectTarget(overlay, styleIndex), null)
})

test('pointer provenance reports when ancestor source search is incomplete', async () => {
  const source = await readFile(resolve(root, 'lib/client.js'), 'utf8')
  let handoff
  runInNewContext(source, {
    window: { __ModuleLoader__: { load(value) { handoff = value } } },
  })
  const module = handoff.factory(() => ({
    createElement() {},
    useEffect() {},
    useState() { return [false, () => {}] },
  }))

  let parent = makeElement({ attrs: { 'data-dsh-plugin': 'deep-plugin' } })
  let target = null
  for (let index = 0; index < 70; index += 1) {
    target = makeElement({ tagName: 'DIV', parentElement: parent })
    parent = target
  }
  const info = module.inspectTarget(target, new Map())
  assert.equal(info.plugin, null)
  assert.equal(info.confidence, 'none')
  assert.equal(info.ancestorLimitReached, true)
  assert.equal(info.sourceSearchIncomplete, true)
  assert.equal(info.ancestorCount, 64)
})

test('the diagnostics scanner reports CSS, marker, Slot, and client-error clues', async () => {
  const source = await readFile(resolve(root, 'lib/client.js'), 'utf8')
  let handoff
  runInNewContext(source, {
    window: { __ModuleLoader__: { load(value) { handoff = value } } },
  })
  const module = handoff.factory(() => ({
    createElement() {},
    useEffect() {},
    useState() { return [false, () => {}] },
  }))

  const styleA = {
    textContent: '._shared{color:red;opacity:.5}',
    getAttribute(name) {
      return name === 'data-plugin' ? 'plugin-a' : 'module-a.css'
    },
  }
  const styleB = {
    textContent: '._shared{color:blue}',
    getAttribute(name) {
      return name === 'data-plugin' ? 'plugin-b' : 'module-b.css'
    },
  }
  const pluginA = makeElement({
    tagName: 'SECTION',
    attrs: { 'data-dsh-plugin': 'plugin-a', 'data-dsh-module': 'module-a' },
    classList: ['_shared'],
  })
  const slotA = makeElement({ tagName: 'DIV', attrs: { 'data-slot': 'shell.overlay' } })
  const slotB = makeElement({ tagName: 'DIV', attrs: { 'data-slot': 'shell.overlay' } })
  const documentObject = {
    title: 'DSH diagnostics fixture',
    querySelectorAll(selector) {
      if (selector === '[data-dsh-plugin]') return [pluginA]
      if (selector === '[data-dsh-module]') return [pluginA]
      if (selector === '[data-slot]') return [slotA, slotB]
      if (selector === 'style[data-plugin]') return [styleA, styleB]
      return []
    },
  }
  const report = module.scanDiagnostics(documentObject, [{
    kind: 'error',
    message: 'fixture client failure',
    time: '2026-01-01T00:00:00.000Z',
  }])

  assert.equal(report.runtime.moduleLoader, 'present')
  assert.equal(report.counts.pluginMarkers, 1)
  assert.equal(report.counts.moduleMarkers, 1)
  assert.equal(report.counts.slotMarkers, 2)
  assert.equal(report.counts.styleNodes, 2)
  assert.equal(report.counts.cssConflicts, 1)
  assert.equal(report.counts.markerConflicts, 1)
  assert.equal(report.counts.slotHints, 1)
  assert.equal(report.counts.clientErrors, 1)
  assert.equal(report.cssConflicts[0].className, '_shared')
  assert.equal(report.markerConflicts[0].plugin, 'plugin-a')
  assert.equal(report.slotHints[0].value, 'shell.overlay')
  assert.equal(report.errors[0].message, undefined)
  assert.equal(report.errors[0].messagePresent, true)
  assert.match(module.formatDiagnosticsReport(report), /messagePresent/u)
  assert.doesNotMatch(module.formatDiagnosticsReport(report), /fixture client failure/u)
})

test('the diagnostics scanner relates modules to plugin owners without claiming a confirmed load conflict', async () => {
  const source = await readFile(resolve(root, 'lib/client.js'), 'utf8')
  let handoff
  runInNewContext(source, {
    window: { __ModuleLoader__: { load(value) { handoff = value } } },
  })
  const module = handoff.factory(() => ({
    createElement() {},
    useEffect() {},
    useState() { return [false, () => {}] },
  }))

  const sharedA = makeElement({
    attrs: { 'data-dsh-plugin': 'plugin-a', 'data-dsh-module': 'SharedModule' },
  })
  const sharedB = makeElement({
    attrs: { 'data-dsh-plugin': 'plugin-b', 'data-dsh-module': 'SharedModule' },
  })
  const documentObject = {
    querySelectorAll(selector) {
      if (selector === '[data-dsh-plugin]') return [sharedA, sharedB]
      if (selector === '[data-dsh-module]') return [sharedA, sharedB]
      return []
    },
  }
  const report = module.scanDiagnostics(documentObject, [])

  assert.deepEqual(JSON.parse(JSON.stringify(report.pluginModuleRelations)), [
    { plugin: 'plugin-a', module: 'SharedModule', count: 1 },
    { plugin: 'plugin-b', module: 'SharedModule', count: 1 },
  ])
  assert.deepEqual(JSON.parse(JSON.stringify(report.moduleOwnershipClues)), [{
    kind: 'module-multiple-plugin-owners',
    severity: 'review',
    module: 'SharedModule',
    plugins: ['plugin-a', 'plugin-b'],
    occurrences: 2,
  }])
  assert.equal(report.boundaries.toolCall, 'not-observed')
  assert.equal(report.truncated.clues, false)
})

test('diagnostic reports expose a stable Client versus Host Guard capability boundary', async () => {
  const source = await readFile(resolve(root, 'lib/client.js'), 'utf8')
  let handoff
  runInNewContext(source, {
    window: { __ModuleLoader__: { load(value) { handoff = value } } },
  })
  const module = handoff.factory(() => ({
    createElement() {},
    useEffect() {},
    useState() { return [false, () => {}] },
  }))

  const pluginNode = makeElement({ attrs: { 'data-dsh-plugin': 'plugin-a' } })
  const report = module.scanDiagnostics({
    querySelectorAll(selector) {
      if (selector === '[data-dsh-plugin]') return [pluginNode]
      return []
    },
  }, [])
  const capabilities = JSON.parse(JSON.stringify(report.capabilities))

  assert.equal(report.schemaVersion, 6)
  assert.equal(report.pointer.schemaVersion, 2)
  assert.equal(report.pointer.current, null)
  assert.equal(capabilities.schemaVersion, 1)
  assert.equal(capabilities.clientMode, 'read-only')
  assert.equal(capabilities.conversationSession.client.status, 'not-observed')
  assert.equal(capabilities.workspaceFile.client.status, 'not-observed')
  assert.equal(capabilities.pluginEnablement.client.status, 'partial-read-only')
  assert.equal(capabilities.crashQuarantine.client.status, 'not-observed')
  assert.equal(capabilities.toolCallObservation.client.status, 'not-observed')
  for (const capability of Object.values(capabilities).filter(value => value && typeof value === 'object' && value.client)) {
    assert.equal(capability.hostGuard.status, 'required')
    assert.equal(capability.hostGuard.observed, false)
  }
  assert.deepEqual(capabilities.workspaceFile.client.cannotProvide.includes('file-rollback'), true)
  assert.deepEqual(capabilities.toolCallObservation.client.cannotProvide.includes('tool-call-success-claim'), true)
  assert.deepEqual(capabilities.pluginEnablement.hostGuard.provides.includes('plugin-configuration-changes'), true)
  assert.deepEqual(capabilities.crashQuarantine.hostGuard.provides.includes('crash-quarantine-and-isolation'), true)
})

test('runtime diagnostics use read-only DSH snapshots and omit tool arguments/output bodies', async () => {
  const source = await readFile(resolve(root, 'lib/client.js'), 'utf8')
  let handoff
  let slotErrorHandler
  const hostListener = new Set()
  const listListener = new Set()
  const modules = {
    version: 'client',
    factories: new Map([['failed-plugin', () => {}]]),
    loadCache: new Map([['loaded-plugin', { id: 'loaded-plugin', styles: ['loaded.css'], edges: new Set(['react']) }]]),
    seed: new Map([['react', {}]]),
    statics: new Map([['app-shell', {}]]),
    graphRows: new Map([['failed-plugin', { id: 'failed-plugin', url: 'https://dsh.test/assets/failed.js?token=secret', immediately: true }]]),
    pendingArrival: new Map([['pending-plugin', Promise.resolve()]]),
    materializing: new Set(['materializing-plugin']),
  }
  const currentSnapshot = {
    running: true,
    openState: 'open',
    runningCalls: [{ callId: 'call-running', name: 'bash', argsRaw: 'echo secret-tool-arguments', turn: 2, step: 1, time: 100 }],
    nodes: [
      ...Array.from({ length: 81 }, (_, index) => ({
        kind: 'tool-result',
        callId: `call-failed-${index}`,
        time: 120,
        callTime: 110,
        isError: true,
        error: { name: 'PermissionError', code: 'PERMISSION_DENIED', message: 'sandbox_permissions=danger-full-access token=secret' },
        content: [{ type: 'text', text: 'tool output secret-body' }],
      })),
      { kind: 'turn-error', time: 130, turn: 2, step: 1, code: 'AGENT_ERROR', message: 'agent failed token=secret' },
    ],
    openError: null,
    promptError: null,
    lastAgentError: null,
  }
  runInNewContext(source, {
    window: {
      __ModuleLoader__: { load(value) { handoff = value } },
      __DSH_MODULES__: modules,
    },
    document: { dispatchEvent() {}, querySelectorAll() { return [] } },
  })
  const module = handoff.factory(() => ({
    createElement() {},
    useEffect() {},
    useState() { return [false, () => {}] },
  }))
  const slots = {
    snapshot() {
      return [{
        name: 'single.slot',
        kind: 'single',
        scope: 'root',
        declaredBy: 'framework',
        occupants: [
          { registrant: 'plugin-a', id: 'same', priority: 1, active: true },
          { registrant: 'plugin-b', id: 'same', priority: 1, active: false },
        ],
        children: [],
      }]
    },
    onEntryError(handler) { slotErrorHandler = handler; return () => {} },
    inject() {},
    register() { return {} },
  }
  const ctx = {
    effect(fn) { return fn() },
    slots,
    locale: { register() {}, bind() { return key => key } },
    get(name) {
      if (name === 'slots') return slots
      if (name === 'permissionPresets') return { defaultPreset: 'danger-full-access', names: ['workspace-write', 'danger-full-access'] }
      if (name === 'approval') return { config: { policy: 'never' } }
      if (name === 'shell') return { sandboxMode: 'danger-full-access' }
      if (name === 'connection') return {
        hostDescription: {
          getSnapshot() {
            return { version: '0.1.0-rc.6', cwd: 'C:/secret/workspace', provider: 'picpi', model: 'gpt-5.6-sol', attachedSessions: 1, canOpenPath: true }
          },
          subscribe(handler) { hostListener.add(handler); return () => hostListener.delete(handler) },
        },
      }
      if (name === 'sessions') return {
        list: {
          getSnapshot() { return { current: 'session-1', byId: { 'session-1': { displayTitle: 'Fixture', running: true, blank: false } } } },
          subscribe(handler) { listListener.add(handler); return () => listListener.delete(handler) },
        },
        binding() { return { session: { getSnapshot() { return currentSnapshot } } } },
      }
      if (name === 'dynamicCordisRunner') return {
        getSnapshot() { return [{ pluginId: 'dynamic-a', packageId: 'package-a', pluginRunId: 'run-a', name: 'Dynamic A', slots: ['tool.view.cordis'], styleCount: 1 }] },
        activeRuns: { getSnapshot() { return new Map([['dynamic-b', { phase: 'orchestrating', packageId: 'package-b', agentId: 'session-1' }]]) }, subscribe() { return () => {} } },
        lastRunError: { getSnapshot() { return new Map([['dynamic-c', { packageId: 'package-c', reason: 'client-half-failed', message: 'client failed token=secret' }]]) }, subscribe() { return () => {} } },
        renderFailures: { getSnapshot() { return new Map([['dynamic-a', { slot: 'tool.view.cordis', message: 'render failed token=secret', abdicated: true }]]) }, subscribe() { return () => {} } },
      }
      if (name === 'remote.pluginInventory') return { list: async () => ({ ok: true, value: { entries: [{ entryId: 'failed-plugin', moduleName: 'failed-plugin', enabled: true, fiberPhase: 'failed' }] } }) }
      return null
    },
  }
  module.apply(ctx)
  slotErrorHandler('single.slot', { registrant: 'plugin-b', options: { id: 'same', priority: 1 } }, { message: 'slot crashed token=secret' }, { abdicate: true })
  await new Promise(resolve => setImmediate(resolve))
  const report = module.scanDiagnostics({ title: 'runtime fixture', querySelectorAll() { return [] } }, [])

  assert.equal(report.runtime.moduleSystem, 'present')
  assert.equal(report.moduleSystem.counts.loaded, 1)
  assert.equal(report.moduleSystem.counts.materializing, 1)
  assert.equal(report.runtime.slotRegistry, 'present')
  assert.equal(report.slotRegistry.counts.singleWithMultipleOccupants, 1)
  assert.equal(report.runtime.hostStatus, 'present')
  assert.equal(report.host.description.cwdPresent, true)
  assert.equal(report.host.description.cwd, undefined)
  assert.equal(report.runtime.permissionStatus, 'present')
  assert.equal(report.permission.defaultPreset, 'danger-full-access')
  assert.equal(report.permission.sandboxMode, 'danger-full-access')
  assert.equal(report.permission.approvalPolicy, 'never')
  assert.equal(report.runtime.toolCallDiagnostics, 'present')
  assert.equal(report.toolCalls.running[0].hasArguments, true)
  assert.equal(report.toolCalls.resultErrors[0].error.code, 'PERMISSION_DENIED')
  assert.equal(report.toolCalls.resultErrors.length, 80)
  assert.equal(report.toolCalls.totals.resultErrors, 81)
  assert.equal(report.toolCalls.truncated.resultErrors, true)
  assert.equal(report.truncated.toolCalls, true)
  assert.equal(report.counts.slotErrors, 1)
  assert.equal(report.runtime.hostPluginInventory, 'present')
  assert.equal(report.counts.failedPlugins, 1)
  assert.equal(report.dynamicCordis.renderFailures[0].abdicated, true)
  assert.equal(report.clues.some(item => item.kind === 'permission-default-full-access'), true)
  assert.equal(report.boundaries.toolCall, 'observed-read-only')
  assert.equal(report.capabilities.conversationSession.client.status, 'observed-read-only')
  assert.equal(report.capabilities.workspaceFile.client.status, 'partial-read-only')
  assert.equal(report.capabilities.pluginEnablement.client.status, 'observed-read-only')
  assert.equal(report.capabilities.crashQuarantine.client.status, 'partial-read-only')
  assert.equal(report.capabilities.toolCallObservation.client.status, 'observed-read-only')
  assert.equal(report.capabilities.toolCallObservation.client.evidence.includes('redacted-session-tool-call-snapshot'), true)
  assert.equal(report.capabilities.workspaceFile.client.evidence.includes('host-workspace-presence'), true)
  assert.equal(report.capabilities.conversationSession.hostGuard.status, 'required')
  assert.doesNotMatch(module.formatDiagnosticsReport(report), /secret-tool-arguments|tool output secret-body|C:\/secret\/workspace|token=secret/u)
  assert.equal(report.session.current.sessionId, undefined)
  assert.equal(report.session.toolCalls.sessionId, undefined)
  assert.equal(report.startupGuard.diagnosticSession.sessionId, undefined)
  assert.equal(report.dynamicCordis.activeRuns[0].agentId, undefined)
  assert.equal(report.dynamicCordis.loaded[0].pluginRunId, undefined)
  assert.doesNotMatch(JSON.stringify(report), /session-1|call-running|call-failed-0|run-a|secret-body|token=secret/u)
})

test('caller-supplied diagnostic errors stay metadata-only in reports and exports', async () => {
  const source = await readFile(resolve(root, 'lib/client.js'), 'utf8')
  let handoff
  runInNewContext(source, {
    window: { __ModuleLoader__: { load(value) { handoff = value } } },
  })
  const module = handoff.factory(() => ({
    createElement() {},
    useEffect() {},
    useState() { return [false, () => {}] },
  }))
  const report = module.scanDiagnostics(null, [{
    message: 'raw result body token=secret',
    argsRaw: 'danger-full-access secret-tool-arguments',
    result: { body: 'secret-body' },
    stack: 'Error: secret-body',
    code: 'PERMISSION_DENIED',
  }])
  assert.equal(report.errors[0].code, 'PERMISSION_DENIED')
  assert.equal(report.errors[0].message, undefined)
  assert.equal(report.errors[0].messagePresent, true)
  assert.equal(report.errors[0].stackPresent, true)
  assert.doesNotMatch(JSON.stringify(report), /raw result body|danger-full-access secret-tool-arguments|secret-body|token=secret/u)
  assert.doesNotMatch(module.formatDiagnosticsReport(report), /raw result body|danger-full-access secret-tool-arguments|secret-body|token=secret/u)
})

test('CSS extraction ignores comments, strings, decimals, and asset suffixes', async () => {
  const source = await readFile(resolve(root, 'lib/client.js'), 'utf8')
  let handoff
  runInNewContext(source, {
    window: { __ModuleLoader__: { load(value) { handoff = value } } },
  })
  const module = handoff.factory(() => ({
    createElement() {},
    useEffect() {},
    useState() { return [false, () => {}] },
  }))

  assert.deepEqual(
    Array.from(module.extractCssClassNames('/* .comment */ .real-class{content:".string";opacity:.5;background:url(asset.png)}')).sort(),
    ['real-class'],
  )
})

test('client error capture redacts URLs and sensitive-looking text', async () => {
  const source = await readFile(resolve(root, 'lib/client.js'), 'utf8')
  let handoff
  let errorHandler
  let rejectionHandler
  runInNewContext(source, {
    window: {
      __ModuleLoader__: { load(value) { handoff = value } },
      addEventListener(type, handler) {
        if (type === 'error') errorHandler = handler
        if (type === 'unhandledrejection') rejectionHandler = handler
      },
    },
    document: { dispatchEvent() {} },
  })
  const module = handoff.factory(() => ({
    createElement() {},
    useEffect() {},
    useState() { return [false, () => {}] },
  }))

  module.installClientErrorCapture()
  errorHandler({
    error: { message: 'apiKey=secret-value Authorization: Bearer bearer-secret {"authorization":"json-secret"}', stack: 'Error: apiKey=secret-value\n Authorization: Bearer bearer-secret\n at https://example.test/app.js?token=abc:3:4' },
    filename: 'https://example.test/app.js?token=abc',
    lineno: 3,
    colno: 4,
  })
  rejectionHandler({ reason: { message: 'request failed' } })

  const errors = module.getClientErrors()
  assert.equal(errors.length, 2)
  assert.equal(errors[0].filename, undefined)
  assert.equal(errors[0].filenamePresent, true)
  assert.equal(errors[0].message, undefined)
  assert.equal(errors[0].messagePresent, true)
  assert.equal(errors[0].stack, undefined)
  assert.equal(errors[0].stackPresent, true)
  assert.equal(errors[0].capturePhase, 'settings-mounted')
  assert.equal(errors[1].kind, 'unhandledrejection')
})

test('diagnostic reports can be downloaded through injected browser primitives', async () => {
  const source = await readFile(resolve(root, 'lib/client.js'), 'utf8')
  let handoff
  runInNewContext(source, {
    window: { __ModuleLoader__: { load(value) { handoff = value } } },
    setTimeout,
  })
  const module = handoff.factory(() => ({
    createElement() {},
    useEffect() {},
    useState() { return [false, () => {}] },
  }))

  let clicked = false
  let createdBlob
  let revokedUrl
  const anchor = {
    style: {},
    click() { clicked = true },
    remove() {},
  }
  const documentObject = {
    body: { appendChild() {} },
    createElement() { return anchor },
  }
  class FakeBlob {
    constructor(parts, options) {
      this.parts = parts
      this.options = options
      createdBlob = this
    }
  }
  const urlObject = {
    createObjectURL() { return 'blob:diagnostics' },
    revokeObjectURL(value) { revokedUrl = value },
  }
  await module.downloadDiagnosticsReport({ scannedAt: '2026-08-14T01:02:03.000Z' }, documentObject, urlObject, FakeBlob)
  assert.equal(clicked, true)
  assert.equal(anchor.download, 'dsh-plugin-debug-diagnostics-2026-08-14T01-02-03-000Z.json')
  assert.equal(createdBlob.options.type, 'application/json;charset=utf-8')
  assert.equal(revokedUrl, undefined)
})
