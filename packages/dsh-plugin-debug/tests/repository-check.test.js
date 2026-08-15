import assert from 'node:assert/strict'
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { checkRepository, getCheckSchema, scanRepositories } from '../src/repository-check.js'

async function makeRepo({ name = 'dsh-plugin-fixture', patch = true, readme = true, source = true } = {}) {
  const root = await mkdtemp(join(tmpdir(), 'dsh-debug-check-'))
  await writeFile(join(root, 'package.json'), JSON.stringify({
    name,
    version: '1.0.0',
    main: 'lib/index.js',
    scripts: { build: 'node scripts/build.mjs' },
    dsh: patch ? { bundle: { patch: './cordis.patch.yml' } } : undefined,
  }, null, 2))
  await mkdir(join(root, 'lib'), { recursive: true })
  await writeFile(join(root, 'lib', 'index.js'), 'export const name = "fixture"\n')
  if (source) {
    await mkdir(join(root, 'src'), { recursive: true })
    await writeFile(join(root, 'src', 'index.js'), 'export const name = "fixture"\n')
  }
  if (patch) {
    await writeFile(join(root, 'cordis.patch.yml'), `- insert:\n    - id: ${name}\n      name: ${name}\n`)
  }
  if (readme) await writeFile(join(root, 'README.md'), 'dsh plugin --profile web add ./fixture\n')
  return root
}

test('checkRepository returns a passing read-only report for a valid bundle', async () => {
  const root = await makeRepo()
  try {
    const report = await checkRepository(root)
    assert.equal(report.verdict, 'pass')
    assert.equal(report.checks.failed, 0)
    assert.ok(report.checks.total >= 1)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('checkRepository reports actionable errors for a malformed bundle', async () => {
  const root = await makeRepo({ patch: false, readme: false, source: false })
  try {
    const report = await checkRepository(root)
    assert.equal(report.verdict, 'fail')
    const codes = report.findings.map(finding => finding.code)
    assert.ok(codes.includes('no-patch'))
    assert.ok(codes.includes('no-source-entry'))
    assert.ok(codes.includes('missing-profile-install-example'))
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('strict mode promotes warnings without changing the read-only report shape', async () => {
  const root = await makeRepo({ readme: false })
  try {
    const report = await checkRepository(root, { strict: true })
    assert.equal(report.verdict, 'fail')
    assert.ok(report.checks.warned >= 0)
    assert.ok(Array.isArray(report.evidence))
    assert.ok(Array.isArray(report.limitations))
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('scanRepositories only scans bounded dsh-* directories and exposes schema', async () => {
  const parent = await mkdtemp(join(tmpdir(), 'dsh-debug-scan-'))
  const valid = await makeRepo()
  try {
    await mkdir(join(parent, 'dsh-one'), { recursive: true })
    for (const name of ['package.json', 'cordis.patch.yml', 'README.md']) {
      await writeFile(join(parent, 'dsh-one', name), await readFile(join(valid, name)))
    }
    await mkdir(join(parent, 'other-project'), { recursive: true })
    await writeFile(join(parent, 'other-project', 'package.json'), '{}')
    const result = await scanRepositories(parent)
    assert.equal(result.root, parent)
    assert.equal(result.scanned, 1)
    assert.equal(result.reports.length, 1)
    const schema = getCheckSchema()
    assert.ok(schema.some(item => item.code === 'no-patch'))
  } finally {
    await rm(parent, { recursive: true, force: true })
    await rm(valid, { recursive: true, force: true })
  }
})
