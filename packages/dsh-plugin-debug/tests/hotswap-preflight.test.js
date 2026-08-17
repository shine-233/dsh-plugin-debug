import assert from 'node:assert/strict'
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import {
  HOTSWAP_PREFLIGHT_SCHEMA_VERSION,
  getHotswapPreflightSchema,
  preflightHotswapSource,
} from '../src/hotswap-preflight.js'

async function makeCandidate({ dangerous = false, mature = true } = {}) {
  const root = await mkdtemp(join(tmpdir(), 'dsh-hotswap-preflight-'))
  await writeFile(join(root, 'package.json'), JSON.stringify({
    name: 'dsh-hotswap-fixture',
    version: '1.0.0',
    license: mature ? 'MIT' : undefined,
    main: 'lib/index.js',
  }, null, 2))
  await mkdir(join(root, 'src'), { recursive: true })
  await writeFile(join(root, 'src', 'index.js'), dangerous
    ? [
        "import { execSync } from 'node:child_process'",
        "const command = 'rm -rf /'",
        "const route = '/_dsh/hotswap/restart'",
        'if (origin === undefined) return true',
        "await entry._dispose()",
        "await entry.refresh()",
        "writeFileSync('cordis.patch.yml', body)",
        "watchFile('package.json', reload)",
        'delete require.cache[moduleId]',
        'execSync(command)',
      ].join('\n')
    : 'export const name = "safe"\n')
  if (mature) {
    await writeFile(join(root, 'LICENSE'), 'MIT\n')
    await mkdir(join(root, 'tests'), { recursive: true })
    await writeFile(join(root, 'tests', 'smoke.test.js'), 'test("fixture", () => {})\n')
    await mkdir(join(root, '.github', 'workflows'), { recursive: true })
    await writeFile(join(root, '.github', 'workflows', 'ci.yml'), 'name: CI\n')
  }
  return root
}

test('safe mature candidate has no static hotswap red flags within the scan budget', async () => {
  const root = await makeCandidate()
  try {
    const report = await preflightHotswapSource(root)
    assert.equal(report.schemaVersion, HOTSWAP_PREFLIGHT_SCHEMA_VERSION)
    assert.equal(report.verdict, 'PASS')
    assert.equal(report.source.packageName, 'dsh-hotswap-fixture')
    assert.equal(report.source.testsDetected, true)
    assert.equal(report.source.ciDetected, true)
    assert.equal(report.networkAccessed, false)
    assert.equal(report.commandsExecuted, false)
    assert.equal(report.executesPluginCode, false)
    assert.equal(report.targetMutated, false)
    assert.equal(report.execution, 'NOT_ATTEMPTED')
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('preflight exposes shell, unauthenticated control-plane, private API, and missing-safeguard findings', async () => {
  const root = await makeCandidate({ dangerous: true, mature: false })
  try {
    const report = await preflightHotswapSource(root)
    const codes = report.findings.map(item => item.code)
    assert.equal(report.verdict, 'MANUAL_REVIEW')
    assert.ok(codes.includes('shell-execution'))
    assert.ok(codes.includes('origin-only-control-plane'))
    assert.ok(codes.includes('private-lifecycle-api'))
    assert.ok(codes.includes('module-cache-eviction'))
    assert.ok(codes.includes('profile-patch-write'))
    assert.ok(codes.includes('non-atomic-patch-write'))
    assert.ok(codes.includes('missing-rollback'))
    assert.ok(codes.includes('missing-serial-queue'))
    assert.ok(codes.includes('missing-core-protection'))
    assert.ok(codes.includes('missing-tests'))
    assert.ok(codes.includes('missing-ci'))
    assert.ok(codes.includes('missing-license'))
    assert.equal(report.commandsExecuted, false)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('preflight fails closed when the bounded scan cannot observe the candidate', async () => {
  const root = await makeCandidate()
  try {
    const report = await preflightHotswapSource(root, { maxFileBytes: 10 })
    assert.equal(report.truncated, true)
    assert.ok(report.findings.some(item => item.code === 'scan-truncated'))
    assert.notEqual(report.verdict, 'PASS')
    assert.equal(report.networkAccessed, false)
    assert.equal(report.commandsExecuted, false)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('preflight reports an unavailable source instead of treating a missing path as safe', async () => {
  const report = await preflightHotswapSource(join(tmpdir(), `dsh-hotswap-missing-${Date.now()}-${Math.random().toString(16).slice(2)}`))
  assert.equal(report.verdict, 'UNAVAILABLE')
  assert.ok(report.findings.some(item => item.code === 'source-unavailable'))
  assert.equal(report.actualHotSwap, false)
})

test('preflight schema is versioned and exposes static-only findings', () => {
  const schema = getHotswapPreflightSchema()
  assert.ok(schema.length >= 10)
  assert.ok(schema.every(item => item.schemaVersion === HOTSWAP_PREFLIGHT_SCHEMA_VERSION))
  assert.ok(schema.some(item => item.code === 'shell-execution'))
  assert.ok(schema.some(item => item.code === 'origin-only-control-plane'))
})
