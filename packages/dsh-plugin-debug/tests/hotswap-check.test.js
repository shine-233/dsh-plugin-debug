import assert from 'node:assert/strict'
import test from 'node:test'
import {
  HOTSWAP_CHECK_SCHEMA_VERSION,
  getHotswapCheckSchema,
  inspectHotswapCapabilities,
} from '../src/hotswap-check.js'

function makeEntry({
  id = 'safe-entry',
  name = 'dsh-safe-plugin',
  options = {},
  ancestors = undefined,
  methods = true,
} = {}) {
  const entry = {
    options: { id, name, ...options },
    fiber: {},
  }
  if (ancestors) entry.ancestors = ancestors
  if (methods) {
    entry.update = async () => {}
    entry._dispose = async () => {}
    entry.refresh = async () => {}
  }
  return entry
}

const completeContract = {
  source: 'dsh-host',
  version: '1',
  official: true,
  stable: true,
  operations: ['entry.update', 'entry.dispose', 'entry.refresh'],
  serialQueue: true,
  coreProtection: true,
  rollback: true,
  dryRun: true,
}

test('hotswap capability check is unavailable without Host inventory or a public contract', () => {
  const report = inspectHotswapCapabilities()

  assert.equal(report.schemaVersion, HOTSWAP_CHECK_SCHEMA_VERSION)
  assert.equal(report.verdict, 'UNAVAILABLE')
  assert.equal(report.execution, 'NOT_ATTEMPTED')
  assert.equal(report.executionAttempted, false)
  assert.equal(report.executionVerified, false)
  assert.deepEqual(report.actionsExecuted, [])
  assert.equal(report.actualHotSwap, false)
  assert.equal(report.networkAccessed, false)
  assert.equal(report.commandsExecuted, false)
  assert.equal(report.targetMutated, false)
  assert.ok(report.findings.some(item => item.code === 'inventory-unavailable'))
  assert.ok(report.findings.some(item => item.code === 'lifecycle-contract-missing'))
})

test('official HMR observation does not become an unauthorized mutation contract', () => {
  const report = inspectHotswapCapabilities({
    inventory: [makeEntry()],
    hmr: { getLinked() {} },
  })

  assert.equal(report.verdict, 'UNAVAILABLE')
  assert.equal(report.host.officialHmr.status, 'present')
  assert.ok(report.findings.some(item => item.code === 'official-hmr-not-action-contract'))
  assert.ok(report.findings.some(item => item.code === 'internal-api-not-contract'))
})

test('an incomplete declared lifecycle contract is reported as partial', () => {
  const report = inspectHotswapCapabilities({
    inventory: [makeEntry()],
    lifecycleContract: {
      source: 'dsh-host',
      version: '1',
      official: true,
      stable: true,
      operations: ['entry.update'],
    },
    targetId: 'safe-entry',
  })

  assert.equal(report.verdict, 'PARTIAL')
  assert.deepEqual(report.host.lifecycleContract.missingOperations, ['entry.dispose', 'entry.refresh'])
  assert.deepEqual(report.host.lifecycleContract.missingSafety, ['serialQueue', 'coreProtection', 'rollback'])
})

test('an untrusted or unversioned lifecycle contract remains unavailable', () => {
  const untrusted = inspectHotswapCapabilities({
    inventory: [makeEntry({ methods: false })],
    lifecycleContract: {
      source: 'third-party-wrapper',
      version: '1',
      stable: true,
      operations: ['entry.update', 'entry.dispose', 'entry.refresh'],
      serialQueue: true,
      coreProtection: true,
      rollback: true,
    },
    targetId: 'safe-entry',
  })
  const unversioned = inspectHotswapCapabilities({
    inventory: [makeEntry({ methods: false })],
    lifecycleContract: {
      source: 'dsh-host',
      official: true,
      stable: true,
      operations: ['entry.update', 'entry.dispose', 'entry.refresh'],
      serialQueue: true,
      coreProtection: true,
      rollback: true,
    },
    targetId: 'safe-entry',
  })

  assert.equal(untrusted.verdict, 'UNAVAILABLE')
  assert.ok(untrusted.findings.some(item => item.code === 'lifecycle-contract-not-authoritative'))
  assert.equal(unversioned.verdict, 'UNAVAILABLE')
  assert.ok(unversioned.findings.some(item => item.code === 'lifecycle-contract-unversioned'))
})

test('a complete authoritative contract can report a safe candidate without executing it', () => {
  const report = inspectHotswapCapabilities({
    inventory: [makeEntry()],
    lifecycleContract: completeContract,
    hmr: { getLinked() {}, registerConfig() {} },
    targetId: 'safe-entry',
  })

  assert.equal(report.verdict, 'SUPPORTED')
  assert.equal(report.execution, 'NOT_ATTEMPTED')
  assert.equal(report.executionAttempted, false)
  assert.equal(report.executionVerified, false)
  assert.equal(report.actualHotSwap, false)
  assert.equal(report.target.entry.id, 'safe-entry')
  assert.equal(report.target.entry.name, 'dsh-safe-plugin')
  assert.equal(report.host.officialHmr.status, 'present')
  assert.equal(report.targetMutated, false)
})

test('core entries are protected even when a Host claims a complete contract', () => {
  for (const identity of [
    { id: 'web', name: '@deepseek-ai/dsh-web' },
    { id: 'client-runtime', name: '@deepseek-ai/dsh-client-runtime' },
    { id: 'include:core', name: 'include:core' },
    { id: 'web-client', name: 'web-client' },
  ]) {
    const report = inspectHotswapCapabilities({
      inventory: [makeEntry(identity)],
      lifecycleContract: completeContract,
      targetId: identity.id,
    })

    assert.equal(report.verdict, 'MANUAL_REVIEW')
    assert.equal(report.target.entry.protected, true)
    assert.ok(report.findings.some(item => item.code === 'protected-entry'))
  }
})

test('host-only capability reports stay partial when no concrete target is selected', () => {
  const report = inspectHotswapCapabilities({
    inventory: [makeEntry()],
    lifecycleContract: completeContract,
  })

  assert.equal(report.verdict, 'PARTIAL')
  assert.equal(report.target.requested, null)
  assert.equal(report.target.entry, null)
  assert.equal(report.target.matchCount, 0)
})

test('runtime-only, ancestor-disabled, and dynamic !!js entries fail closed', () => {
  const runtimeOnly = inspectHotswapCapabilities({
    inventory: [makeEntry({ options: { runtimeOnly: true } })],
    lifecycleContract: completeContract,
    targetId: 'safe-entry',
  })
  const ancestorDisabled = inspectHotswapCapabilities({
    inventory: [makeEntry({ ancestors: [{ options: { id: 'group', name: 'dsh-group', disabled: true } }] })],
    lifecycleContract: completeContract,
    targetId: 'safe-entry',
  })
  const dynamicDisabled = inspectHotswapCapabilities({
    inventory: [makeEntry({ options: { disabled: { __jsExpr: 'ctx.config.enabled' } } })],
    lifecycleContract: completeContract,
    targetId: 'safe-entry',
  })
  const functionDisabled = inspectHotswapCapabilities({
    inventory: [makeEntry({ options: { disabled: () => true } })],
    lifecycleContract: completeContract,
    targetId: 'safe-entry',
  })

  assert.equal(runtimeOnly.verdict, 'MANUAL_REVIEW')
  assert.ok(runtimeOnly.findings.some(item => item.code === 'runtime-only-entry'))
  assert.equal(ancestorDisabled.verdict, 'MANUAL_REVIEW')
  assert.ok(ancestorDisabled.findings.some(item => item.code === 'ancestor-disabled'))
  assert.equal(dynamicDisabled.verdict, 'MANUAL_REVIEW')
  assert.ok(dynamicDisabled.findings.some(item => item.code === 'dynamic-disabled-expression'))
  assert.equal(functionDisabled.verdict, 'MANUAL_REVIEW')
  assert.ok(functionDisabled.findings.some(item => item.code === 'dynamic-disabled-expression'))
})

test('ambiguous names and missing targets do not silently select an entry', () => {
  const ambiguous = inspectHotswapCapabilities({
    inventory: [makeEntry({ id: 'one', name: 'dsh-same' }), makeEntry({ id: 'two', name: 'dsh-same' })],
    lifecycleContract: completeContract,
    targetId: 'dsh-same',
  })
  const missing = inspectHotswapCapabilities({
    inventory: [makeEntry()],
    lifecycleContract: completeContract,
    targetId: 'dsh-missing',
  })

  assert.equal(ambiguous.verdict, 'MANUAL_REVIEW')
  assert.equal(ambiguous.target.matchCount, 2)
  assert.equal(ambiguous.target.entry, null)
  assert.ok(ambiguous.findings.some(item => item.code === 'target-ambiguous'))
  assert.equal(missing.verdict, 'UNAVAILABLE')
  assert.ok(missing.findings.some(item => item.code === 'target-not-found'))
})

test('schema exposes bounded, read-only hotswap findings', () => {
  const schema = getHotswapCheckSchema()
  assert.ok(schema.length >= 10)
  assert.ok(schema.every(item => item.schemaVersion === HOTSWAP_CHECK_SCHEMA_VERSION))
  assert.ok(schema.some(item => item.code === 'dynamic-disabled-expression'))
  assert.ok(schema.some(item => item.code === 'internal-api-not-contract'))
})
