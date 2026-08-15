import { lstat, readFile, readdir } from 'node:fs/promises'
import { join, relative, resolve } from 'node:path'

const MAX_FILE_BYTES = 2 * 1024 * 1024
const MAX_FILES = 500
const MAX_REPOSITORIES = 50

export const CHECK_SCHEMA = Object.freeze([
  { code: 'no-manifest', severity: 'error', description: 'package.json is missing or invalid' },
  { code: 'invalid-name', severity: 'error', description: 'package.json name is missing or not a DSH plugin name' },
  { code: 'missing-main-or-types', severity: 'error', description: 'package.json needs a main or types entry' },
  { code: 'no-patch', severity: 'error', description: 'dsh bundle patch is missing' },
  { code: 'no-bundle-decl', severity: 'warning', description: 'package.json does not declare dsh.bundle.patch' },
  { code: 'malformed-patch', severity: 'error', description: 'cordis.patch.yml has no readable id/name entries' },
  { code: 'patch-name-mismatch', severity: 'error', description: 'patch identity does not match the package name' },
  { code: 'duplicate-row-id', severity: 'error', description: 'cordis.patch.yml contains duplicate row ids' },
  { code: 'no-source-entry', severity: 'error', description: 'src/index.js or src/index.ts is missing' },
  { code: 'lib-layout-mismatch', severity: 'error', description: 'the declared main/types file is missing' },
  { code: 'stale-ts-imports', severity: 'error', description: 'built JavaScript still imports TypeScript files' },
  { code: 'missing-build-script', severity: 'warning', description: 'package.json has no build script' },
  { code: 'missing-profile-install-example', severity: 'error', description: 'README lacks a standard Profile Bundle install example' },
])

function issue(code, detail, extra = {}) {
  const definition = CHECK_SCHEMA.find(item => item.code === code)
  return {
    code,
    severity: definition?.severity ?? 'warning',
    detail: detail ?? definition?.description ?? code,
    ...extra,
  }
}

function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function safeName(name) {
  return typeof name === 'string' && (name.startsWith('dsh-') || /^@[^/]+\/dsh-/.test(name))
}

async function readBounded(path, limitations) {
  const stat = await lstat(path)
  if (!stat.isFile()) throw new Error('not a regular file')
  if (stat.size > MAX_FILE_BYTES) {
    limitations.push(`skipped oversized file: ${path}`)
    return null
  }
  return readFile(path, 'utf8')
}

async function readPackage(root, limitations) {
  try {
    const text = await readBounded(join(root, 'package.json'), limitations)
    if (text === null) return null
    const parsed = JSON.parse(text)
    return isObject(parsed) ? parsed : null
  } catch {
    return null
  }
}

function parsePatchIdentities(text) {
  const ids = []
  const names = []
  for (const match of text.matchAll(/^\s*-?\s*id:\s*["']?([^"'\s#]+)["']?\s*$/gmi)) ids.push(match[1])
  for (const match of text.matchAll(/^\s*name:\s*["']?([^"'\s#]+)["']?\s*$/gmi)) names.push(match[1])
  return { ids, names }
}

async function checkPatch(root, pkg, findings, limitations) {
  const declaration = pkg?.dsh?.bundle?.patch
  if (declaration === undefined) findings.push(issue('no-bundle-decl'))
  const patchPath = typeof declaration === 'string' ? resolve(root, declaration) : join(root, 'cordis.patch.yml')
  let text
  try {
    text = await readBounded(patchPath, limitations)
  } catch {
    findings.push(issue('no-patch', `patch file not found: ${relative(root, patchPath)}`))
    return
  }
  if (text === null) return
  const { ids, names } = parsePatchIdentities(text)
  if (ids.length === 0 || names.length === 0) {
    findings.push(issue('malformed-patch', 'patch must contain at least one id and name'))
    return
  }
  const seen = new Set()
  for (const id of ids) {
    if (seen.has(id)) findings.push(issue('duplicate-row-id', `duplicate patch row id: ${id}`))
    seen.add(id)
  }
  if (typeof pkg?.name === 'string' && !ids.includes(pkg.name) && !names.includes(pkg.name)) {
    findings.push(issue('patch-name-mismatch', `package ${pkg.name} is absent from patch identities`))
  }
}

async function checkLibrary(root, pkg, findings, limitations) {
  const sourcePaths = [join(root, 'src', 'index.js'), join(root, 'src', 'index.ts')]
  let sourceFound = false
  for (const path of sourcePaths) {
    try {
      const stat = await lstat(path)
      if (stat.isFile()) { sourceFound = true; break }
    } catch { /* continue */ }
  }
  if (!sourceFound) findings.push(issue('no-source-entry'))

  if (typeof pkg?.main !== 'string' && typeof pkg?.types !== 'string') {
    findings.push(issue('missing-main-or-types'))
  }
  for (const declared of [pkg?.main, pkg?.types]) {
    if (typeof declared !== 'string') continue
    try {
      const stat = await lstat(resolve(root, declared))
      if (!stat.isFile()) findings.push(issue('lib-layout-mismatch', `declared file is not regular: ${declared}`))
    } catch {
      findings.push(issue('lib-layout-mismatch', `declared file is missing: ${declared}`))
    }
  }

  if (!isObject(pkg?.scripts) || typeof pkg.scripts.build !== 'string') findings.push(issue('missing-build-script'))

  const libRoot = join(root, 'lib')
  let entries = []
  try { entries = await readdir(libRoot, { withFileTypes: true }) } catch { return }
  let inspected = 0
  for (const entry of entries) {
    if (inspected >= MAX_FILES) {
      limitations.push(`file budget reached under ${libRoot}`)
      break
    }
    if (!entry.isFile() || !entry.name.endsWith('.js')) continue
    inspected += 1
    try {
      const text = await readBounded(join(libRoot, entry.name), limitations)
      if (text !== null && /(?:from|require\()\s*[('\"](?:\.\/|\.\.\/)[^'\"]+\.ts['\"]/.test(text)) {
        findings.push(issue('stale-ts-imports', `built file imports TypeScript: ${entry.name}`))
      }
    } catch { /* unreadable file is represented by the limitation */ }
  }
}

async function checkInstallDocs(root, findings, limitations) {
  try {
    const text = await readBounded(join(root, 'README.md'), limitations)
    if (text === null || !/dsh\s+plugin\s+--profile\s+\S+\s+add/i.test(text)) findings.push(issue('missing-profile-install-example'))
  } catch {
    findings.push(issue('missing-profile-install-example'))
  }
}

function reportFor(root, findings, evidence, limitations, strict) {
  const normalized = findings.map(item => ({ ...item, severity: item.severity ?? 'warning' }))
  const errors = normalized.filter(item => item.severity === 'error').length
  const warnings = normalized.filter(item => item.severity === 'warning').length
  return {
    schemaVersion: 1,
    repo: root,
    verdict: errors > 0 || (strict && warnings > 0) ? 'fail' : warnings > 0 ? 'warn' : 'pass',
    checks: {
      total: CHECK_SCHEMA.length,
      passed: Math.max(0, CHECK_SCHEMA.length - errors - warnings),
      failed: errors,
      warned: warnings,
      skipped: limitations.length,
    },
    findings: normalized,
    evidence,
    limitations,
  }
}

export async function checkRepository(directory, { strict = false } = {}) {
  const root = resolve(String(directory ?? ''))
  const findings = []
  const limitations = ['hub status skipped: repository check is offline-first']
  const evidence = ['read-only filesystem inspection']
  try {
    const stat = await lstat(root)
    if (!stat.isDirectory() || stat.isSymbolicLink()) {
      findings.push(issue('no-manifest', 'target is not a real directory'))
      return reportFor(root, findings, evidence, limitations, strict)
    }
  } catch {
    findings.push(issue('no-manifest', 'target directory is not readable'))
    return reportFor(root, findings, evidence, limitations, strict)
  }

  const pkg = await readPackage(root, limitations)
  if (!pkg) {
    findings.push(issue('no-manifest'))
    return reportFor(root, findings, evidence, limitations, strict)
  }
  if (!safeName(pkg.name)) findings.push(issue('invalid-name', `unsupported DSH package name: ${String(pkg.name ?? '')}`))
  await checkPatch(root, pkg, findings, limitations)
  await checkLibrary(root, pkg, findings, limitations)
  await checkInstallDocs(root, findings, limitations)
  evidence.push(`package: ${pkg.name}@${pkg.version ?? 'unknown'}`)
  return reportFor(root, findings, evidence, limitations, strict)
}

export async function scanRepositories(parent, { strict = false, maxRepositories = MAX_REPOSITORIES } = {}) {
  const root = resolve(String(parent ?? ''))
  const reports = []
  let entries
  try { entries = await readdir(root, { withFileTypes: true }) } catch { throw new Error(`cannot read scan root: ${root}`) }
  for (const entry of entries) {
    if (reports.length >= Math.min(MAX_REPOSITORIES, Math.max(1, maxRepositories))) break
    if (!entry.isDirectory() || entry.isSymbolicLink() || !entry.name.startsWith('dsh-')) continue
    const candidate = join(root, entry.name)
    try { await lstat(join(candidate, 'package.json')) } catch { continue }
    reports.push(await checkRepository(candidate, { strict }))
  }
  return { schemaVersion: 1, root, scanned: reports.length, reports }
}

export function getCheckSchema() {
  return CHECK_SCHEMA.map(item => ({ ...item }))
}
