import { lstat, readFile, readdir, realpath } from 'node:fs/promises'
import { isAbsolute, join, relative, resolve, sep } from 'node:path'

const MAX_FILE_BYTES = 2 * 1024 * 1024
const MAX_FILES = 500
const MAX_TOTAL_BYTES = 8 * 1024 * 1024
const MAX_REPOSITORIES = 50
const MAX_TS_CONFIG_DEPTH = 5
const CORE_ROW_IDS = new Set(['tools', 'session', 'llm', 'web', 'permission'])
const BUNDLE_KINDS = Object.freeze(['bundle', 'tool-bundle'])
export const REPORT_SCHEMA_VERSION = 2

export const CHECK_SCHEMA = Object.freeze([
  { code: 'no-manifest', severity: 'error', description: 'package.json is missing or invalid', appliesTo: ['unknown'] },
  { code: 'invalid-name', severity: 'error', description: 'package.json name is missing or not a DSH plugin name', appliesTo: BUNDLE_KINDS },
  { code: 'missing-main-or-types', severity: 'error', description: 'package.json needs a main or types entry inside the repository', appliesTo: BUNDLE_KINDS },
  { code: 'no-patch', severity: 'error', description: 'dsh bundle patch is missing or unsafe', appliesTo: BUNDLE_KINDS },
  { code: 'no-bundle-decl', severity: 'warning', description: 'package.json does not declare dsh.bundle.patch', appliesTo: BUNDLE_KINDS },
  { code: 'invalid-bundle-decl', severity: 'error', description: 'package.json dsh.bundle.patch is not a non-empty string', appliesTo: BUNDLE_KINDS },
  { code: 'malformed-patch', severity: 'error', description: 'cordis.patch.yml has invalid sections or entries', appliesTo: BUNDLE_KINDS },
  { code: 'patch-name-mismatch', severity: 'error', description: 'patch identity does not match the package name', appliesTo: ['tool-bundle'] },
  { code: 'duplicate-row-id', severity: 'error', description: 'cordis.patch.yml contains duplicate row ids', appliesTo: BUNDLE_KINDS },
  { code: 'core-row-id', severity: 'error', description: 'cordis.patch.yml attempts to use a protected DSH core row id', appliesTo: BUNDLE_KINDS },
  { code: 'unexpected-fields', severity: 'warning', description: 'cordis.patch.yml contains fields outside the limited checker grammar', appliesTo: BUNDLE_KINDS },
  { code: 'no-source-entry', severity: 'error', description: 'src/index.js or src/index.ts is missing', appliesTo: BUNDLE_KINDS },
  { code: 'lib-layout-mismatch', severity: 'error', description: 'the declared main/types file or build output is outside the expected layout', appliesTo: BUNDLE_KINDS },
  { code: 'stale-ts-imports', severity: 'error', description: 'built JavaScript still imports TypeScript files', appliesTo: BUNDLE_KINDS },
  { code: 'missing-build-script', severity: 'warning', description: 'package.json has no build or prepare script', appliesTo: BUNDLE_KINDS },
  { code: 'missing-prepack-script', severity: 'warning', description: 'a published build bundle has no prepack script to refresh its output', appliesTo: BUNDLE_KINDS },
  { code: 'lifecycle-script', severity: 'warning', description: 'package.json contains an install lifecycle script', appliesTo: BUNDLE_KINDS },
  { code: 'incomplete-files', severity: 'warning', description: 'the declared files allowlist omits a required published artifact', appliesTo: BUNDLE_KINDS },
  { code: 'missing-tsconfig', severity: 'error', description: 'TypeScript sources need a readable tsconfig.json', appliesTo: BUNDLE_KINDS },
  { code: 'tsconfig-extends-unresolved', severity: 'warning', description: 'tsconfig extends could not be resolved inside the repository', appliesTo: BUNDLE_KINDS },
  { code: 'missing-ts-ext-imports', severity: 'error', description: 'TypeScript extension imports lack allowImportingTsExtensions', appliesTo: BUNDLE_KINDS },
  { code: 'missing-rewrite-imports', severity: 'error', description: 'TypeScript extension imports lack rewriteRelativeImportExtensions', appliesTo: BUNDLE_KINDS },
  { code: 'implicit-node-types', severity: 'warning', description: 'Node APIs are used without explicit types: [node]', appliesTo: BUNDLE_KINDS },
  { code: 'no-build-entry', severity: 'error', description: 'there is no built entry and no build or prepare script for a clean checkout', appliesTo: BUNDLE_KINDS },
  { code: 'missing-profile-install-example', severity: 'error', description: 'README lacks a standard Profile Bundle install example', appliesTo: BUNDLE_KINDS },
  { code: 'manual-install-only', severity: 'warning', description: 'the repository does not prove that it can be installed through the standard Profile Bundle path', appliesTo: BUNDLE_KINDS },
  { code: 'core-modification-required', severity: 'warning', description: 'the default install path appears to modify DSH core files', appliesTo: BUNDLE_KINDS },
  { code: 'malformed-registry-manifest', severity: 'error', description: 'dsh.plugin.json is missing or invalid', appliesTo: ['registry'] },
  { code: 'invalid-registry-id', severity: 'error', description: 'registry id is invalid', appliesTo: ['registry'] },
  { code: 'invalid-registry-version', severity: 'warning', description: 'registry version is not semver', appliesTo: ['registry'] },
  { code: 'registry-main-missing', severity: 'error', description: 'registry main is missing, unsafe, or absent', appliesTo: ['registry'] },
  { code: 'registry-client-main', severity: 'warning', description: 'registry client.main is missing or unsafe', appliesTo: ['registry'] },
  { code: 'registry-client-contract', severity: 'warning', description: 'registry client.inject is not a string array', appliesTo: ['registry'] },
  { code: 'invalid-engines-dsh', severity: 'warning', description: 'registry engines.dsh is not a supported semver range', appliesTo: ['registry'] },
  { code: 'malformed-contributes', severity: 'warning', description: 'registry contributes.tools or contributes.skills is not an array', appliesTo: ['registry'] },
  { code: 'malformed-skill', severity: 'error', description: 'SKILL.md is missing required frontmatter', appliesTo: ['skill'] },
  { code: 'malformed-collection', severity: 'error', description: 'catalog.json is missing the collection/plugins shape', appliesTo: ['collection'] },
  { code: 'unsupported-kind', severity: 'warning', description: 'repository form is not recognized by the checker', appliesTo: ['infra', 'unknown'] },
  { code: 'hub-skipped', severity: 'info', description: 'Hub registration was not checked because this checker is offline-only', appliesTo: ['registry', 'skill', 'collection', 'tool-bundle', 'bundle'] },
  { code: 'scan-truncated', severity: 'error', description: 'repository scan exceeded its bounded resource budget', appliesTo: ['registry', 'skill', 'collection', 'tool-bundle', 'bundle', 'infra', 'unknown'] },
].map(item => Object.freeze({ ...item, appliesTo: Object.freeze([...item.appliesTo]) })))

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
  if (typeof name !== 'string' || name.length === 0 || name.length > 214) return false
  if (name.startsWith('.') || name.startsWith('_')) return false
  const scoped = /^@[a-z0-9][a-z0-9._~-]*\/dsh-[a-z0-9][a-z0-9._~-]*$/.test(name)
  const unscoped = /^dsh-[a-z0-9][a-z0-9._~-]*$/.test(name)
  return scoped || unscoped
}

function isPathInside(parent, child) {
  const rel = relative(parent, child)
  return rel === '' || (rel !== '..' && !rel.startsWith(`..${sep}`) && !rel.startsWith(sep))
}

function createBudget() {
  return { files: 0, bytes: 0, truncated: false }
}

async function resolveDeclaredFile(root, target) {
  if (typeof target !== 'string' || target.trim() === '') return { ok: false, reason: 'empty path' }
  if (isAbsolute(target)) return { ok: false, reason: `absolute path is not allowed: ${target}` }
  const rootResolved = resolve(root)
  const full = resolve(root, target)
  if (!isPathInside(rootResolved, full)) return { ok: false, reason: `path escapes repository root: ${target}` }
  let stat
  try {
    stat = await lstat(full)
  } catch {
    return { ok: false, reason: `file does not exist: ${target}` }
  }
  if (stat.isSymbolicLink()) return { ok: false, reason: `symbolic link is not allowed: ${target}` }
  if (!stat.isFile()) return { ok: false, reason: `not a regular file: ${target}` }
  try {
    const rootReal = await realpath(rootResolved)
    const targetReal = await realpath(full)
    if (!isPathInside(rootReal, targetReal)) return { ok: false, reason: `real path escapes repository root: ${target}` }
  } catch {
    return { ok: false, reason: `real path could not be verified: ${target}` }
  }
  return { ok: true, path: full }
}

async function readBounded(path, limitations, budget = undefined) {
  const stat = await lstat(path)
  if (!stat.isFile()) throw new Error('not a regular file')
  if (stat.size > MAX_FILE_BYTES) {
    if (budget) budget.truncated = true
    limitations.push('skipped oversized file')
    return null
  }
  if (budget) {
    if (budget.files >= MAX_FILES || budget.bytes + stat.size > MAX_TOTAL_BYTES) {
      budget.truncated = true
      limitations.push('repository scan budget reached')
      return null
    }
    budget.files += 1
    budget.bytes += stat.size
  }
  return readFile(path, 'utf8')
}

async function readJsonFile(path, limitations, budget) {
  try {
    const text = await readBounded(path, limitations, budget)
    if (text === null) return null
    const parsed = JSON.parse(text)
    return isObject(parsed) ? parsed : null
  } catch {
    return null
  }
}

async function readPackage(root, limitations, budget) {
  return readJsonFile(join(root, 'package.json'), limitations, budget)
}

async function exists(path) {
  try {
    await lstat(path)
    return true
  } catch {
    return false
  }
}

async function isRegularFile(path) {
  try {
    const stat = await lstat(path)
    return stat.isFile() && !stat.isSymbolicLink()
  } catch {
    return false
  }
}

async function collectTextFiles(root, extensions, limitations, budget, maxDepth = 8) {
  const texts = []
  try {
    const rootStat = await lstat(root)
    if (!rootStat.isDirectory() || rootStat.isSymbolicLink()) {
      limitations.push('skipped symbolic-link or non-directory scan root')
      return texts
    }
  } catch {
    return texts
  }
  const walk = async (directory, depth) => {
    if (depth > maxDepth || budget.truncated) return
    let entries
    try {
      entries = await readdir(directory, { withFileTypes: true })
    } catch {
      return
    }
    for (const entry of entries) {
      if (budget.truncated || entry.name === 'node_modules' || entry.name === '.git' || entry.name.startsWith('.')) continue
      const path = join(directory, entry.name)
      let stat
      try { stat = await lstat(path) } catch { continue }
      if (stat.isSymbolicLink()) continue
      if (stat.isDirectory()) {
        await walk(path, depth + 1)
        continue
      }
      if (!extensions.some(extension => entry.name.endsWith(extension))) continue
      try {
        const text = await readBounded(path, limitations, budget)
        if (text !== null) texts.push(text)
      } catch { /* unreadable files are represented by the bounded limitation */ }
    }
  }
  await walk(root, 0)
  return texts
}

function codeLines(texts) {
  return texts.flatMap(text => text.split('\n').filter(line => {
    const trimmed = line.trim()
    return !trimmed.startsWith('//') && !trimmed.startsWith('/*') && !trimmed.startsWith('*')
  }))
}

function hasTypeScriptImport(texts) {
  const pattern = /(?:(?:from|import)\s+|import\s*\(|require\s*\()['"]((?:\.\.?\/)[^'"]+\.(?:ts|tsx|mts|cts))['"]/g
  return codeLines(texts).some(line => {
    pattern.lastIndex = 0
    return pattern.test(line)
  })
}

function hasTypeScriptUrl(texts) {
  const pattern = /new URL\s*\(\s*['"]((?:\.\.?\/)[^'"]+\.(?:ts|tsx|mts|cts))['"]/g
  return codeLines(texts).some(line => {
    pattern.lastIndex = 0
    return pattern.test(line)
  })
}

function usesNodeApi(texts) {
  return texts.some(text => /\bBuffer\./.test(text) || /\bfrom\s+['"]node:/.test(text))
}

function isSemver(value) {
  return typeof value === 'string' && /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/.test(value)
}

function isSemverRange(value) {
  if (typeof value !== 'string') return false
  const trimmed = value.trim()
  if (trimmed === '' || trimmed === '*') return true
  return trimmed.split(/\s*\|\|\s*/).every(part => /^(?:\^|~|>=|<=|>|<)?\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/.test(part.trim()))
}

async function resolveTsconfig(root, limitations, budget) {
  const configPath = await resolveDeclaredFile(root, 'tsconfig.json')
  if (!configPath.ok) return { status: 'missing', reason: configPath.reason }
  const visited = new Set()
  const readConfig = async (path, depth) => {
    if (depth > MAX_TS_CONFIG_DEPTH) return { status: 'unresolved', reason: 'tsconfig extends depth exceeded' }
    const identity = resolve(path)
    if (visited.has(identity)) return { status: 'unresolved', reason: 'tsconfig extends cycle detected' }
    visited.add(identity)
    let text
    try { text = await readBounded(path, limitations, budget) } catch { return { status: 'unresolved', reason: 'tsconfig is unreadable' } }
    if (text === null) return { status: 'unresolved', reason: 'tsconfig scan budget reached' }
    let parsed
    try { parsed = JSON.parse(text) } catch { return { status: 'unresolved', reason: 'tsconfig is not valid JSON' } }
    if (!isObject(parsed)) return { status: 'unresolved', reason: 'tsconfig must be an object' }
    let options = {}
    if (typeof parsed.extends === 'string') {
      if (!parsed.extends.startsWith('.')) return { status: 'unresolved', reason: `package extends is not resolved offline: ${parsed.extends}` }
      const candidate = resolve(path, '..', parsed.extends)
      const candidates = [candidate, candidate.endsWith('.json') ? candidate : `${candidate}.json`]
      let parent = null
      for (const candidatePath of candidates) {
        const relativePath = relative(root, candidatePath)
        const checked = await resolveDeclaredFile(root, relativePath)
        if (checked.ok) { parent = checked.path; break }
      }
      if (!parent) return { status: 'unresolved', reason: 'tsconfig extends target is missing or outside the repository' }
      const parentResult = await readConfig(parent, depth + 1)
      if (parentResult.status !== 'resolved') return parentResult
      options = { ...parentResult.options }
    }
    if (isObject(parsed.compilerOptions)) options = { ...options, ...parsed.compilerOptions }
    return { status: 'resolved', options }
  }
  return readConfig(configPath.path, 0)
}

function stripInlineComment(line) {
  let single = false
  let double = false
  for (let index = 0; index < line.length; index += 1) {
    const character = line[index]
    if (character === "'" && !double) single = !single
    else if (character === '"' && !single) double = !double
    else if (character === '#' && !single && !double && (index === 0 || /\s/.test(line[index - 1]))) return line.slice(0, index).trimEnd()
  }
  return line.trimEnd()
}

function stripQuotes(value) {
  const match = /^(['"])(.*)\1$/.exec(value.trim())
  return match ? match[2] : value.trim()
}

function parsePatch(text) {
  const sections = []
  const ids = []
  const names = []
  const errors = []
  let section
  let entry
  let nestedFieldIndent = -1

  const addEntry = () => {
    entry = { id: '', name: '', fields: [] }
    section.entries.push(entry)
    return entry
  }

  for (const raw of text.split('\n')) {
    const line = stripInlineComment(raw)
    if (line.trim() === '') continue
    if (/^\s*\t/.test(line)) errors.push('tabs are not supported for patch indentation')
    const indent = line.length - line.trimStart().length
    const content = line.trim()
    const sectionMatch = /^-\s+(insert|update|disable):\s*$/.exec(content)
    if (sectionMatch && indent === 0) {
      section = { op: sectionMatch[1], entries: [], errors: [] }
      sections.push(section)
      entry = undefined
      nestedFieldIndent = -1
      continue
    }
    if (indent === 0 && /^-\s+id:\s*(.+)$/.test(content)) {
      const match = /^-\s+id:\s*(.+)$/.exec(content)
      section = { op: 'update', entries: [], errors: [] }
      sections.push(section)
      entry = { id: stripQuotes(match[1]), name: '', fields: [] }
      section.entries.push(entry)
      nestedFieldIndent = -1
      continue
    }
    if (indent === 0 && content.startsWith('- ')) {
      section = { op: 'unknown', entries: [], errors: [`unknown top-level section: ${content.slice(0, 60)}`] }
      sections.push(section)
      entry = undefined
      nestedFieldIndent = -1
      continue
    }
    if (!section) {
      errors.push(`content before first section: ${content.slice(0, 60)}`)
      continue
    }
    if (nestedFieldIndent >= 0 && indent >= nestedFieldIndent) continue

    const entryMatch = /^-\s+([A-Za-z][\w-]*):\s*(.*)$/.exec(content)
    if (entryMatch) {
      entry = addEntry()
      const key = entryMatch[1]
      const value = stripQuotes(entryMatch[2])
      if (key === 'id') entry.id = value
      else if (key === 'name') entry.name = value
      else entry.fields.push(key)
      nestedFieldIndent = key === 'config' && value === '' ? indent + 2 : -1
      continue
    }
    const fieldMatch = /^([A-Za-z][\w-]*):\s*(.*)$/.exec(content)
    if (!fieldMatch) {
      section.errors.push(`unparseable line: ${content.slice(0, 60)}`)
      continue
    }
    if (!entry) entry = addEntry()
    const key = fieldMatch[1]
    const value = stripQuotes(fieldMatch[2])
    if (key === 'id') entry.id = value
    else if (key === 'name') entry.name = value
    else entry.fields.push(key)
    nestedFieldIndent = key === 'config' && value === '' ? indent + 2 : -1
  }

  for (const current of sections) {
    for (const currentEntry of current.entries) {
      if (currentEntry.id === '') current.errors.push('entry missing id')
      if (currentEntry.id !== '') ids.push(currentEntry.id)
      if (currentEntry.name !== '') names.push(currentEntry.name)
    }
  }
  return { sections, ids, names, errors }
}

async function checkPatch(root, pkg, kind, findings, limitations, budget) {
  const declaration = pkg?.dsh?.bundle?.patch
  if (declaration === undefined) {
    findings.push(issue('no-bundle-decl'))
  } else if (typeof declaration !== 'string' || declaration.trim() === '') {
    findings.push(issue('invalid-bundle-decl', 'dsh.bundle.patch must be a non-empty string'))
    return { entries: [], patchUsable: false }
  }
  const target = declaration === undefined ? './cordis.patch.yml' : declaration
  const checked = await resolveDeclaredFile(root, target)
  if (!checked.ok) {
    findings.push(issue('no-patch', `patch file is unavailable: ${checked.reason}`))
    return { entries: [], patchUsable: false }
  }
  let text
  try { text = await readBounded(checked.path, limitations, budget) } catch { text = null }
  if (text === null) {
    findings.push(issue('no-patch', 'patch file is unreadable or exceeds the scan budget'))
    return { entries: [], patchUsable: false }
  }
  const parsed = parsePatch(text)
  const allErrors = [...parsed.errors, ...parsed.sections.flatMap(current => current.errors)]
  const entries = parsed.sections.flatMap(current => current.entries)
  if (allErrors.length > 0 || parsed.ids.length === 0) {
    findings.push(issue('malformed-patch', allErrors.slice(0, 3).join('; ') || 'patch must contain at least one entry with id'))
  }
  const seen = new Set()
  for (const id of parsed.ids) {
    if (seen.has(id)) findings.push(issue('duplicate-row-id', `duplicate patch row id: ${id}`))
    seen.add(id)
    if (CORE_ROW_IDS.has(id)) findings.push(issue('core-row-id', `protected DSH core row id: ${id}`))
  }
  for (const entry of entries) {
    for (const field of entry.fields) {
      if (field !== 'config') findings.push(issue('unexpected-fields', `unsupported patch field: ${field}`))
    }
  }
  // A tool-bundle is conventionally one installable tool and must identify
  // itself in the patch. A general bundle may intentionally insert several
  // packages, so requiring one package name there would create false errors.
  if (kind === 'tool-bundle' && typeof pkg?.name === 'string' && !entries.some(entry => entry.id === pkg.name || entry.name === pkg.name)) {
    findings.push(issue('patch-name-mismatch', `package ${pkg.name} is absent from patch identities`))
  }
  return { entries, patchUsable: allErrors.length === 0 && parsed.ids.length > 0 }
}

async function checkBuild(root, pkg, findings, limitations, budget, sourceTextsOverride = undefined) {
  const sourceEntry = (await isRegularFile(join(root, 'src', 'index.js'))) || (await isRegularFile(join(root, 'src', 'index.ts')))
  if (!sourceEntry) findings.push(issue('no-source-entry'))
  if (typeof pkg?.main !== 'string' && typeof pkg?.types !== 'string') findings.push(issue('missing-main-or-types'))
  for (const declared of [pkg?.main, pkg?.types]) {
    if (typeof declared !== 'string') continue
    const checked = await resolveDeclaredFile(root, declared)
    if (!checked.ok) findings.push(issue('lib-layout-mismatch', `declared file is unsafe or missing: ${declared} (${checked.reason})`))
  }

  const scripts = isObject(pkg?.scripts) ? pkg.scripts : {}
  const hasBuildPath = typeof scripts.build === 'string' || typeof scripts.prepare === 'string'
  if (!hasBuildPath) findings.push(issue('missing-build-script'))
  if (Array.isArray(pkg?.files) && pkg.files.some(value => typeof value === 'string' && value.replace(/^[.][\\/]/, '').replace(/[\\/]$/, '') === 'lib') && hasBuildPath && typeof scripts.prepack !== 'string') {
    findings.push(issue('missing-prepack-script', 'package.json publishes lib but has no prepack script to refresh the built artifact'))
  }
  for (const lifecycle of ['preinstall', 'install', 'postinstall']) {
    if (typeof scripts[lifecycle] === 'string') findings.push(issue('lifecycle-script', `package.json contains ${lifecycle}; checker never executes it`))
  }
  if (Array.isArray(pkg?.files)) {
    const files = pkg.files
      .filter(value => typeof value === 'string')
      .map(value => value.replace(/^[.][\\/]/, '').replace(/[\\/]\*\*?$/, '').replace(/[\\/]$/, ''))
    if (!files.includes('lib')) findings.push(issue('incomplete-files', 'files allowlist does not include lib'))
    if (!files.includes('cordis.patch.yml')) findings.push(issue('incomplete-files', 'files allowlist does not include cordis.patch.yml'))
  }

  const sourceTexts = sourceTextsOverride ?? await collectTextFiles(join(root, 'src'), ['.js', '.ts', '.mts', '.cts', '.mjs', '.tsx'], limitations, budget)
  const sourceUsesTsImport = hasTypeScriptImport(sourceTexts)
  // A JavaScript repository can legitimately mention the words "type" or
  // "interface" in strings/comments. Use the source extension/actual import
  // form as the signal instead of guessing from arbitrary text.
  const sourceUsesTs = (await isRegularFile(join(root, 'src', 'index.ts'))) || sourceUsesTsImport
  if (sourceUsesTs || sourceUsesTsImport) {
    const tsconfig = await resolveTsconfig(root, limitations, budget)
    if (tsconfig.status === 'missing') {
      findings.push(issue('missing-tsconfig', tsconfig.reason))
    } else if (tsconfig.status !== 'resolved') {
      findings.push(issue('tsconfig-extends-unresolved', tsconfig.reason))
    } else {
      const options = tsconfig.options
      const allowTsExtensions = options.allowImportingTsExtensions === true
      const rewriteTsExtensions = options.rewriteRelativeImportExtensions === true
      if (sourceUsesTsImport && !allowTsExtensions) findings.push(issue('missing-ts-ext-imports'))
      if (sourceUsesTsImport && allowTsExtensions && !rewriteTsExtensions) findings.push(issue('missing-rewrite-imports'))
      if (usesNodeApi(sourceTexts) && !(Array.isArray(options.types) && options.types.includes('node'))) findings.push(issue('implicit-node-types'))
      if (typeof options.outDir === 'string' && typeof pkg?.main === 'string') {
        const output = resolve(root, options.outDir)
        const main = resolve(root, pkg.main)
        if (!isPathInside(output, main)) findings.push(issue('lib-layout-mismatch', `tsconfig outDir ${options.outDir} does not contain main ${pkg.main}`))
      }
    }
  }

  const libTexts = await collectTextFiles(join(root, 'lib'), ['.js', '.mjs', '.cjs'], limitations, budget)
  if (hasTypeScriptImport(libTexts) || hasTypeScriptUrl(libTexts)) findings.push(issue('stale-ts-imports', 'built lib contains a relative .ts import or worker URL'))
  if (libTexts.length === 0 && !hasBuildPath) findings.push(issue('no-build-entry'))
}

async function checkInstallDocs(root, findings, limitations, budget) {
  let text
  try { text = await readBounded(join(root, 'README.md'), limitations, budget) } catch { text = null }
  const profileInstallExample = text !== null && /dsh\s+plugin\s+--profile\s+\S+\s+add\b/i.test(text)
  if (!profileInstallExample) findings.push(issue('missing-profile-install-example'))
  if (text) {
    const legacyMarker = /手动安装|旧版本兼容|legacy|manual install/i.exec(text)
    const defaultFlow = legacyMarker ? text.slice(0, legacyMarker.index) : text
    if (/(?:git\s+apply|patch\s+-p\d|cp\s+-r|rsync).{0,120}(?:dsh[\\/]source|cordis\.yml|packages[\\/]|apps[\\/])/is.test(defaultFlow)) {
      findings.push(issue('core-modification-required', 'README default flow appears to patch or copy into DSH core'))
    }
  }
  return { profileInstallExample }
}

async function checkRegistry(root, findings, limitations, budget) {
  const manifest = await readJsonFile(join(root, 'dsh.plugin.json'), limitations, budget)
  if (!manifest) {
    findings.push(issue('malformed-registry-manifest'))
    return
  }
  if (typeof manifest.id !== 'string' || !/^[a-z0-9][a-z0-9-]*(\/[a-z0-9][a-z0-9-]*)?$/.test(manifest.id)) findings.push(issue('invalid-registry-id', `invalid registry id: ${String(manifest.id ?? '')}`))
  if (!isSemver(manifest.version)) findings.push(issue('invalid-registry-version', `invalid registry version: ${String(manifest.version ?? '')}`))
  if (typeof manifest.main !== 'string') {
    findings.push(issue('registry-main-missing', 'dsh.plugin.json main is missing'))
  } else {
    const checked = await resolveDeclaredFile(root, manifest.main)
    if (!checked.ok) findings.push(issue('registry-main-missing', `registry main is unsafe or missing: ${checked.reason}`))
  }
  if (isObject(manifest.client)) {
    if (manifest.client.main !== undefined) {
      const checked = typeof manifest.client.main === 'string' ? await resolveDeclaredFile(root, manifest.client.main) : { ok: false, reason: 'client.main is not a string' }
      if (!checked.ok) findings.push(issue('registry-client-main', `registry client.main is unsafe or missing: ${checked.reason}`))
    }
    if (manifest.client.inject !== undefined && (!Array.isArray(manifest.client.inject) || manifest.client.inject.some(value => typeof value !== 'string'))) {
      findings.push(issue('registry-client-contract'))
    }
  }
  if (isObject(manifest.engines) && manifest.engines.dsh !== undefined && !isSemverRange(manifest.engines.dsh)) findings.push(issue('invalid-engines-dsh'))
  if (isObject(manifest.contributes)) {
    for (const key of ['tools', 'skills']) if (manifest.contributes[key] !== undefined && !Array.isArray(manifest.contributes[key])) findings.push(issue('malformed-contributes', `contributes.${key} must be an array`))
  }
}

async function findSkillManifests(root) {
  const candidates = []
  const rootSkill = join(root, 'SKILL.md')
  if (await exists(rootSkill)) candidates.push(rootSkill)
  const skillsRoot = join(root, 'skills')
  let entries
  try {
    const skillsStat = await lstat(skillsRoot)
    if (!skillsStat.isDirectory() || skillsStat.isSymbolicLink()) return candidates
    entries = await readdir(skillsRoot, { withFileTypes: true })
  } catch { return candidates }
  for (const entry of entries) {
    if (candidates.length >= 50 || entry.name.startsWith('.') || entry.isSymbolicLink()) continue
    if (entry.isDirectory()) {
      const candidate = join(skillsRoot, entry.name, 'SKILL.md')
      if (await exists(candidate)) candidates.push(candidate)
    }
  }
  return candidates
}

async function checkSkill(root, findings, limitations, budget) {
  const manifests = await findSkillManifests(root)
  if (manifests.length === 0) {
    findings.push(issue('malformed-skill', 'SKILL.md is missing'))
    return
  }
  for (const manifestPath of manifests) {
    if (budget.truncated) break
    let text
    try { text = await readBounded(manifestPath, limitations, budget) } catch { text = null }
    const frontmatter = text && /^---\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)/.exec(text)
    if (!frontmatter || !/^name:\s*\S+/m.test(frontmatter[1]) || !/^description:\s*\S+/m.test(frontmatter[1])) {
      findings.push(issue('malformed-skill', `${manifestPath} needs YAML frontmatter with name and description`))
    }
  }
}

async function checkCollection(root, findings, limitations, budget) {
  const catalog = await readJsonFile(join(root, 'catalog.json'), limitations, budget)
  if (!catalog || typeof catalog.collection !== 'string' || !Array.isArray(catalog.plugins)) findings.push(issue('malformed-collection', 'catalog.json needs collection string and plugins array'))
}

async function detectKind(root, pkg, limitations, budget) {
  if (await exists(join(root, 'dsh.plugin.json'))) return { kind: 'registry' }
  if ((await findSkillManifests(root)).length > 0) return { kind: 'skill' }
  if (await exists(join(root, 'catalog.json'))) return { kind: 'collection' }
  if (pkg) {
    if (typeof pkg.main !== 'string' || pkg.main === '') return { kind: 'infra' }
    const sourceTexts = await collectTextFiles(join(root, 'src'), ['.js', '.ts', '.mts', '.cts', '.mjs', '.tsx'], limitations, budget)
    if (sourceTexts.some(text => /(?:from\s+|import\s*\(|require\s*\()['"]@deepseek-ai\/dsh-tools(?:\/[^'"]+)?['"]/.test(text))) return { kind: 'tool-bundle', sourceTexts }
    return { kind: 'bundle', sourceTexts }
  }
  return { kind: 'unknown' }
}

function reportFor(root, kind, findings, evidence, limitations, strict, budget) {
  const normalized = findings.map(item => ({ ...item, severity: item.severity ?? 'warning' }))
  const errors = normalized.filter(item => item.severity === 'error' || (strict && item.severity === 'warning'))
  const warnings = normalized.filter(item => item.severity === 'warning' && !errors.includes(item))
  const applicable = CHECK_SCHEMA.filter(item => item.appliesTo.includes(kind))
  const findingCodes = new Map()
  for (const finding of normalized) {
    const items = findingCodes.get(finding.code) ?? []
    items.push(finding)
    findingCodes.set(finding.code, items)
  }
  const results = applicable.map(item => {
    if (item.code === 'hub-skipped') return { code: item.code, status: 'skipped' }
    const hits = findingCodes.get(item.code) ?? []
    if (hits.length === 0) return { code: item.code, status: 'pass' }
    if (hits.some(hit => hit.severity === 'error') || (strict && hits.some(hit => hit.severity === 'warning'))) {
      return { code: item.code, status: 'fail' }
    }
    return { code: item.code, status: 'warn' }
  })
  const failed = results.filter(item => item.status === 'fail').length
  const warned = results.filter(item => item.status === 'warn').length
  return {
    schemaVersion: REPORT_SCHEMA_VERSION,
    repo: root,
    kind,
    mode: 'offline',
    networkAccessed: false,
    commandsExecuted: false,
    targetMutated: false,
    executesPluginCode: false,
    truncated: budget.truncated,
    verdict: errors.length > 0 ? 'fail' : warnings.length > 0 ? 'warn' : 'pass',
    checks: {
      total: results.length,
      passed: results.filter(item => item.status === 'pass').length,
      failed,
      warned,
      skipped: results.filter(item => item.status === 'skipped').length,
      findingCount: normalized.length,
      results,
    },
    findings: normalized,
    evidence,
    limitations,
    hub: {
      status: 'skipped',
      reason: 'offline-first: no gh, git, network, or local login state is consulted',
    },
  }
}

export async function checkRepository(directory, { strict = false } = {}) {
  const root = resolve(String(directory ?? ''))
  const findings = []
  const limitations = ['hub status skipped: repository check is offline-first']
  const evidence = ['read-only filesystem inspection', 'no package manager, build script, shell, git, or gh command executed']
  const budget = createBudget()
  try {
    const stat = await lstat(root)
    if (!stat.isDirectory() || stat.isSymbolicLink()) return reportFor(root, 'unknown', [issue('no-manifest', 'target is not a real directory')], evidence, limitations, strict, budget)
  } catch {
    return reportFor(root, 'unknown', [issue('no-manifest', 'target directory is not readable')], evidence, limitations, strict, budget)
  }

  const pkg = await readPackage(root, limitations, budget)
  const detection = await detectKind(root, pkg, limitations, budget)
  const kind = detection.kind
  evidence.push(`repository form: ${kind}`)
  if (kind === 'registry') await checkRegistry(root, findings, limitations, budget)
  else if (kind === 'skill') await checkSkill(root, findings, limitations, budget)
  else if (kind === 'collection') await checkCollection(root, findings, limitations, budget)
  else if (kind === 'unknown') findings.push(issue('no-manifest', 'no recognized DSH repository marker was found'))
  else if (kind === 'infra') findings.push(issue('unsupported-kind', 'package repository has no loadable main entry; detailed bundle checks skipped'))
  else if (!pkg) findings.push(issue('no-manifest'))
  else {
    if (!safeName(pkg.name)) findings.push(issue('invalid-name', `unsupported DSH package name: ${String(pkg.name ?? '')}`))
    const patchResult = await checkPatch(root, pkg, kind, findings, limitations, budget)
    await checkBuild(root, pkg, findings, limitations, budget, detection.sourceTexts)
    const installDocs = await checkInstallDocs(root, findings, limitations, budget)
    if (patchResult.patchUsable !== true || installDocs.profileInstallExample !== true) {
      findings.push(issue('manual-install-only', 'the repository is missing a usable patch or a standard Profile Bundle install example'))
    }
    evidence.push(`package: ${pkg.name}@${pkg.version ?? 'unknown'}`)
  }
  if (budget.truncated) findings.push(issue('scan-truncated', 'repository scan exceeded its bounded file/byte budget; verdict is fail-closed'))
  return reportFor(root, kind, findings, evidence, limitations, strict, budget)
}

export async function scanRepositories(parent, { strict = false, maxRepositories = MAX_REPOSITORIES } = {}) {
  const root = resolve(String(parent ?? ''))
  const reports = []
  let entries
  try {
    const rootStat = await lstat(root)
    if (!rootStat.isDirectory() || rootStat.isSymbolicLink()) throw new Error('scan root is not a real directory')
    entries = await readdir(root, { withFileTypes: true })
  } catch { throw new Error(`cannot read scan root: ${root}`) }
  const requestedLimit = Number.isFinite(Number(maxRepositories)) ? Math.floor(Number(maxRepositories)) : MAX_REPOSITORIES
  const limit = Math.min(MAX_REPOSITORIES, Math.max(1, requestedLimit))
  let candidateCount = 0
  for (const entry of entries) {
    if (!entry.name.startsWith('dsh-')) continue
    const candidate = join(root, entry.name)
    let stat
    try { stat = await lstat(candidate) } catch { continue }
    if (!stat.isDirectory() || stat.isSymbolicLink()) continue
    let nestedSkillMarker = false
    try {
      const skillsRoot = join(candidate, 'skills')
      const skillsStat = await lstat(skillsRoot)
      if (!skillsStat.isDirectory() || skillsStat.isSymbolicLink()) throw new Error('skills marker is not a real directory')
      const skillsEntries = await readdir(skillsRoot, { withFileTypes: true })
      for (const skill of skillsEntries) {
        if (!skill.isDirectory() || skill.isSymbolicLink() || skill.name.length === 0 || skill.name.length > 120) continue
        if (await exists(join(skillsRoot, skill.name, 'SKILL.md'))) {
          nestedSkillMarker = true
          break
        }
      }
    } catch { /* no nested skills directory */ }
    const marker = (await exists(join(candidate, 'package.json'))) || (await exists(join(candidate, 'dsh.plugin.json'))) || (await exists(join(candidate, 'SKILL.md'))) || nestedSkillMarker || (await exists(join(candidate, 'catalog.json')))
    if (!marker) continue
    candidateCount += 1
    if (reports.length < limit) reports.push(await checkRepository(candidate, { strict }))
  }
  const repositoryListTruncated = candidateCount > limit
  const reportsTruncated = reports.some(report => report.truncated)
  const truncated = repositoryListTruncated || reportsTruncated
  const limitations = []
  if (repositoryListTruncated) limitations.push('repository count budget reached; remaining dsh-* directories were not checked')
  if (reportsTruncated) limitations.push('one or more repository reports were truncated by file/byte budget')
  return {
    schemaVersion: REPORT_SCHEMA_VERSION,
    root,
    scanned: reports.length,
    reports,
    repositoryListTruncated,
    reportsTruncated,
    truncated,
    limitations,
  }
}

export function getCheckSchema() {
  return CHECK_SCHEMA.map(item => ({ schemaVersion: REPORT_SCHEMA_VERSION, ...item, appliesTo: [...item.appliesTo] }))
}
