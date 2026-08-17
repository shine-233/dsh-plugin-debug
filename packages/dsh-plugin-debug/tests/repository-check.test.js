import assert from 'node:assert/strict'
import { mkdtemp, mkdir, readFile, rm, symlink, writeFile } from 'node:fs/promises'
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
    assert.equal(report.schemaVersion, 2)
    assert.equal(report.checks.failed, 0)
    assert.ok(report.checks.total >= 1)
    assert.ok(report.checks.results.some(result => result.code === 'hub-skipped' && result.status === 'skipped'))
    assert.equal(getCheckSchema()[0].schemaVersion, 2)
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
    assert.ok(codes.includes('manual-install-only'))
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
    assert.equal(result.truncated, false)
    assert.equal(result.reports.length, 1)
    const schema = getCheckSchema()
    assert.ok(schema.some(item => item.code === 'no-patch'))
  } finally {
    await rm(parent, { recursive: true, force: true })
    await rm(valid, { recursive: true, force: true })
  }
})

test('scanRepositories discovers skill repositories with skills/*/SKILL.md markers', async () => {
  const parent = await mkdtemp(join(tmpdir(), 'dsh-debug-skill-scan-'))
  try {
    const skillRoot = join(parent, 'dsh-skill-pack')
    await mkdir(join(skillRoot, 'skills', 'hello'), { recursive: true })
    await writeFile(join(skillRoot, 'skills', 'hello', 'SKILL.md'), '---\nname: hello\ndescription: test\n---\n')
    const result = await scanRepositories(parent)
    assert.equal(result.scanned, 1)
    assert.equal(result.reports[0].kind, 'skill')
  } finally {
    await rm(parent, { recursive: true, force: true })
  }
})

test('checkRepository rejects manifest and patch paths that escape the repository', async () => {
  const root = await makeRepo()
  try {
    const pkg = JSON.parse(await readFile(join(root, 'package.json'), 'utf8'))
    pkg.main = '../outside.js'
    pkg.dsh.bundle.patch = '../outside.patch.yml'
    await writeFile(join(root, 'package.json'), JSON.stringify(pkg, null, 2))
    const report = await checkRepository(root)
    const codes = report.findings.map(finding => finding.code)
    assert.ok(codes.includes('no-patch'))
    assert.ok(codes.includes('lib-layout-mismatch'))
    assert.ok(report.evidence.includes('no package manager, build script, shell, git, or gh command executed'))
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('checkRepository fails closed when a checked file exceeds the per-file budget', async () => {
  const root = await makeRepo()
  try {
    await writeFile(join(root, 'src', 'oversized.js'), Buffer.alloc(2 * 1024 * 1024 + 1, 97))
    const report = await checkRepository(root)
    assert.equal(report.truncated, true)
    assert.equal(report.verdict, 'fail')
    assert.ok(report.limitations.includes('skipped oversized file'))
    assert.ok(report.findings.some(finding => finding.code === 'scan-truncated'))
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('checkRepository rejects a non-file source entry', async () => {
  const root = await makeRepo()
  try {
    await rm(join(root, 'src', 'index.js'), { force: true })
    await mkdir(join(root, 'src', 'index.js'))
    const report = await checkRepository(root)
    assert.ok(report.findings.some(finding => finding.code === 'no-source-entry'))
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('repository checker does not follow symlinked source or scan roots', async (t) => {
  const root = await makeRepo()
  const outside = await mkdtemp(join(tmpdir(), 'dsh-debug-outside-source-'))
  const scanLink = join(tmpdir(), `dsh-debug-scan-link-${Date.now()}-${Math.random().toString(16).slice(2)}`)
  try {
    await writeFile(join(outside, 'outside.js'), 'export const leaked = true\n')
    await rm(join(root, 'src'), { recursive: true, force: true })
    try {
      await symlink(outside, join(root, 'src'), 'junction')
      await symlink(root, scanLink, 'junction')
    } catch {
      t.skip('directory junctions are unavailable in this environment')
      return
    }
    const report = await checkRepository(root)
    assert.ok(report.limitations.includes('skipped symbolic-link or non-directory scan root'))
    await assert.rejects(scanRepositories(scanLink), /cannot read scan root/)
  } finally {
    await rm(root, { recursive: true, force: true })
    await rm(outside, { recursive: true, force: true })
    await rm(scanLink, { recursive: true, force: true })
  }
})

test('checkRepository rejects a non-string dsh.bundle.patch declaration', async () => {
  const root = await makeRepo()
  try {
    const pkg = JSON.parse(await readFile(join(root, 'package.json'), 'utf8'))
    pkg.dsh.bundle.patch = false
    await writeFile(join(root, 'package.json'), JSON.stringify(pkg, null, 2))
    const report = await checkRepository(root)
    assert.ok(report.findings.some(finding => finding.code === 'invalid-bundle-decl'))
    assert.ok(!report.findings.some(finding => finding.code === 'no-patch'))
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('checkRepository understands update/disable sections and protects core row ids', async () => {
  const root = await makeRepo()
  try {
    await writeFile(join(root, 'cordis.patch.yml'), `- insert:\n    - id: tool-fixture\n      name: dsh-plugin-fixture\n      config:\n        nested:\n          value: true\n- update:\n    - id: tool-fixture\n      name: dsh-plugin-fixture\n- disable:\n    - id: tools\n`)
    const report = await checkRepository(root)
    const codes = report.findings.map(finding => finding.code)
    assert.equal(report.kind, 'bundle')
    assert.ok(codes.includes('duplicate-row-id'))
    assert.ok(codes.includes('core-row-id'))
    assert.ok(!codes.includes('malformed-patch'))
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('checkRepository reports TypeScript extension build traps without executing a build', async () => {
  const root = await makeRepo()
  try {
    await writeFile(join(root, 'src', 'index.ts'), `import value from './value.ts'\nexport default value\n`)
    await writeFile(join(root, 'tsconfig.json'), JSON.stringify({ compilerOptions: { allowImportingTsExtensions: true } }, null, 2))
    const report = await checkRepository(root)
    assert.ok(report.findings.some(finding => finding.code === 'missing-rewrite-imports'))
    assert.ok(!report.findings.some(finding => finding.code === 'stale-ts-imports'))
    assert.equal(report.evidence.includes('no package manager, build script, shell, git, or gh command executed'), true)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('checkRepository scans .cts sources for TypeScript extension traps', async () => {
  const root = await makeRepo()
  try {
    await writeFile(join(root, 'src', 'index.js'), 'export const name = "fixture"\n')
    await writeFile(join(root, 'src', 'worker.cts'), `import value from './value.cts'\nexport default value\n`)
    await writeFile(join(root, 'tsconfig.json'), JSON.stringify({ compilerOptions: { allowImportingTsExtensions: true } }, null, 2))
    const report = await checkRepository(root)
    assert.ok(report.findings.some(finding => finding.code === 'missing-rewrite-imports'))
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('checkRepository reports missing prepack for a published build allowlist', async () => {
  const root = await makeRepo()
  try {
    const pkg = JSON.parse(await readFile(join(root, 'package.json'), 'utf8'))
    pkg.files = ['lib', 'cordis.patch.yml']
    await writeFile(join(root, 'package.json'), JSON.stringify(pkg, null, 2))
    const report = await checkRepository(root)
    assert.ok(report.findings.some(finding => finding.code === 'missing-prepack-script'))
    assert.equal(report.verdict, 'warn')
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('checkRepository fails closed when the bounded scan budget is exhausted', async () => {
  const root = await makeRepo()
  try {
    const sourceRoot = join(root, 'src', 'many')
    await mkdir(sourceRoot, { recursive: true })
    await Promise.all(Array.from({ length: 510 }, (_, index) => writeFile(join(sourceRoot, `file-${index}.js`), 'export default 1\n')))
    const report = await checkRepository(root)
    assert.equal(report.truncated, true)
    assert.equal(report.verdict, 'fail')
    assert.ok(report.findings.some(finding => finding.code === 'scan-truncated'))
    assert.equal(report.networkAccessed, false)
    assert.equal(report.commandsExecuted, false)
    assert.equal(report.targetMutated, false)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('checkRepository does not read a tsconfig extends target outside the repository', async () => {
  const root = await makeRepo()
  const outside = join(root, '..', `dsh-debug-outside-${Date.now()}-${Math.random().toString(16).slice(2)}.json`)
  try {
    await writeFile(join(root, 'src', 'index.ts'), `import value from './value.ts'\nexport default value\n`)
    await writeFile(outside, JSON.stringify({ compilerOptions: { allowImportingTsExtensions: true, rewriteRelativeImportExtensions: true } }))
    await writeFile(join(root, 'tsconfig.json'), JSON.stringify({ extends: '../' + outside.split(/[\\/]/).pop() }, null, 2))
    const report = await checkRepository(root)
    assert.ok(report.findings.some(finding => finding.code === 'tsconfig-extends-unresolved'))
    assert.ok(!report.findings.some(finding => finding.code === 'missing-rewrite-imports'))
  } finally {
    await rm(root, { recursive: true, force: true })
    await rm(outside, { force: true })
  }
})

test('checkRepository routes registry, skill, and collection forms to their own contracts', async () => {
  const registry = await mkdtemp(join(tmpdir(), 'dsh-debug-registry-'))
  const skill = await mkdtemp(join(tmpdir(), 'dsh-debug-skill-'))
  const collection = await mkdtemp(join(tmpdir(), 'dsh-debug-collection-'))
  try {
    await mkdir(join(registry, 'lib'), { recursive: true })
    await writeFile(join(registry, 'lib', 'index.js'), 'export default {}\n')
    await writeFile(join(registry, 'dsh.plugin.json'), JSON.stringify({ id: 'fixture/registry', version: '1.0.0', main: 'lib/index.js' }, null, 2))
    await writeFile(join(skill, 'SKILL.md'), '---\nname: fixture-skill\ndescription: a valid fixture\n---\n\n# Skill\n')
    await writeFile(join(collection, 'catalog.json'), JSON.stringify({ collection: 'fixture', plugins: [] }, null, 2))

    const [registryReport, skillReport, collectionReport] = await Promise.all([
      checkRepository(registry),
      checkRepository(skill),
      checkRepository(collection),
    ])
    assert.equal(registryReport.kind, 'registry')
    assert.equal(registryReport.verdict, 'pass')
    assert.equal(skillReport.kind, 'skill')
    assert.equal(skillReport.verdict, 'pass')
    assert.equal(collectionReport.kind, 'collection')
    assert.equal(collectionReport.verdict, 'pass')
    const applicableRegistryChecks = getCheckSchema().filter(item => item.appliesTo.includes('registry'))
    assert.equal(registryReport.checks.total, applicableRegistryChecks.length)
    assert.equal(registryReport.checks.skipped, 1)
    assert.equal(registryReport.checks.passed + registryReport.checks.skipped, applicableRegistryChecks.length)
    assert.ok(registryReport.checks.total < getCheckSchema().length)
  } finally {
    await rm(registry, { recursive: true, force: true })
    await rm(skill, { recursive: true, force: true })
    await rm(collection, { recursive: true, force: true })
  }
})

test('checkRepository accepts a skills directory with valid SKILL.md frontmatter', async () => {
  const root = await mkdtemp(join(tmpdir(), 'dsh-debug-skills-'))
  try {
    await mkdir(join(root, 'skills', 'fixture'), { recursive: true })
    await writeFile(join(root, 'skills', 'fixture', 'SKILL.md'), '---\nname: fixture\ndescription: valid\n---\n\n# Fixture\n')
    const report = await checkRepository(root)
    assert.equal(report.kind, 'skill')
    assert.equal(report.verdict, 'pass')
    assert.ok(!report.findings.some(finding => finding.code === 'malformed-skill'))
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('checkRepository does not require a single package identity for a general bundle patch', async () => {
  const root = await makeRepo()
  try {
    await writeFile(join(root, 'cordis.patch.yml'), '- insert:\n    - id: another-row\n      name: dsh-another-plugin\n')
    const report = await checkRepository(root)
    assert.equal(report.kind, 'bundle')
    assert.ok(!report.findings.some(finding => finding.code === 'patch-name-mismatch'))
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('checkRepository treats prepare as a reproducible build entry', async () => {
  const root = await makeRepo()
  try {
    const pkg = JSON.parse(await readFile(join(root, 'package.json'), 'utf8'))
    pkg.scripts = { prepare: 'node scripts/build.mjs' }
    await writeFile(join(root, 'package.json'), JSON.stringify(pkg, null, 2))
    const report = await checkRepository(root)
    const codes = report.findings.map(finding => finding.code)
    assert.ok(!codes.includes('missing-build-script'))
    assert.ok(!codes.includes('no-build-entry'))
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('scanRepositories normalizes non-finite repository limits', async () => {
  const parent = await mkdtemp(join(tmpdir(), 'dsh-debug-limit-'))
  const valid = await makeRepo()
  try {
    await mkdir(join(parent, 'dsh-one'), { recursive: true })
    for (const name of ['package.json', 'cordis.patch.yml', 'README.md']) {
      await writeFile(join(parent, 'dsh-one', name), await readFile(join(valid, name)))
    }
    const result = await scanRepositories(parent, { maxRepositories: Number.NaN })
    assert.equal(result.scanned, 1)
    assert.equal(result.truncated, false)
  } finally {
    await rm(parent, { recursive: true, force: true })
    await rm(valid, { recursive: true, force: true })
  }
})

test('scanRepositories propagates truncation from a child repository report', async () => {
  const parent = await mkdtemp(join(tmpdir(), 'dsh-debug-child-truncated-'))
  const valid = await makeRepo()
  try {
    const target = join(parent, 'dsh-big')
    await mkdir(target, { recursive: true })
    for (const name of ['package.json', 'cordis.patch.yml', 'README.md']) {
      await writeFile(join(target, name), await readFile(join(valid, name)))
    }
    await mkdir(join(target, 'src', 'many'), { recursive: true })
    await Promise.all(Array.from({ length: 510 }, (_, index) => writeFile(join(target, 'src', 'many', `file-${index}.js`), 'export default 1\n')))
    const result = await scanRepositories(parent)
    assert.equal(result.scanned, 1)
    assert.equal(result.repositoryListTruncated, false)
    assert.equal(result.reportsTruncated, true)
    assert.equal(result.truncated, true)
    assert.ok(result.limitations.includes('one or more repository reports were truncated by file/byte budget'))
  } finally {
    await rm(parent, { recursive: true, force: true })
    await rm(valid, { recursive: true, force: true })
  }
})
