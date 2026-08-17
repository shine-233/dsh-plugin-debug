import { lstat, readdir, readFile } from 'node:fs/promises'
import { extname, join, relative, resolve } from 'node:path'

/**
 * Offline source-level preflight for hotswap candidates.
 *
 * This module deliberately reports static indicators only. It never imports a
 * candidate, starts its package scripts, calls a lifecycle method, writes a
 * Profile, or treats a missing string as proof that a security property is
 * present. The runtime capability report lives in hotswap-check.js; keeping
 * these surfaces separate prevents a source scan from becoming an execution
 * authorization.
 */

export const HOTSWAP_PREFLIGHT_SCHEMA_VERSION = 1

const MAX_FILES = 400
const MAX_FILE_BYTES = 512 * 1024
const MAX_TOTAL_BYTES = 4 * 1024 * 1024
const MAX_FINDINGS = 80
const MAX_FINDING_FILES = 5

const TEXT_EXTENSIONS = new Set([
  '.cjs', '.cts', '.js', '.json', '.md', '.mjs', '.mts', '.ts', '.tsx',
  '.toml', '.txt', '.yml', '.yaml',
])

const SKIP_DIRECTORIES = new Set([
  '.git', '.dsh', '.codex', 'coverage', 'dist', 'logs', 'node_modules', 'sbom', 'state',
])

const FINDING_DEFINITIONS = Object.freeze([
  { code: 'source-unavailable', severity: 'error', description: 'the candidate source directory could not be read' },
  { code: 'scan-truncated', severity: 'error', description: 'the bounded source scan stopped before the candidate was fully observed' },
  { code: 'read-error', severity: 'error', description: 'one or more candidate files could not be read without executing code' },
  { code: 'missing-package-manifest', severity: 'error', description: 'package.json was not found at the candidate root' },
  { code: 'shell-execution', severity: 'error', description: 'the source contains a static indicator of shell or package-manager execution' },
  { code: 'unauthenticated-control-plane', severity: 'error', description: 'a lifecycle-like control plane was found without an obvious authentication signal' },
  { code: 'origin-only-control-plane', severity: 'error', description: 'the control plane appears to rely on Origin or same-origin checks without a stronger authorization signal' },
  { code: 'private-lifecycle-api', severity: 'warning', description: 'the candidate references private or unstable loader lifecycle APIs' },
  { code: 'module-cache-eviction', severity: 'warning', description: 'the candidate attempts best-effort module cache eviction' },
  { code: 'profile-patch-write', severity: 'warning', description: 'the candidate appears to write a Profile patch or bundle patch file' },
  { code: 'non-atomic-patch-write', severity: 'warning', description: 'a patch write was found without an obvious atomic write or durability signal' },
  { code: 'file-watcher', severity: 'warning', description: 'the candidate watches files and may react to changes at runtime' },
  { code: 'watcher-without-queue', severity: 'warning', description: 'a runtime file watcher was found without an obvious serialized operation queue' },
  { code: 'missing-rollback', severity: 'warning', description: 'lifecycle or patch mutation was found without an obvious rollback or backup signal' },
  { code: 'missing-serial-queue', severity: 'warning', description: 'lifecycle mutation was found without an obvious serialized operation queue' },
  { code: 'missing-core-protection', severity: 'warning', description: 'lifecycle mutation was found without an obvious protected-core or allowlist signal' },
  { code: 'missing-tests', severity: 'warning', description: 'no test file or test directory was observed within the bounded scan' },
  { code: 'missing-ci', severity: 'warning', description: 'no GitHub Actions workflow was observed within the bounded scan' },
  { code: 'missing-license', severity: 'warning', description: 'no LICENSE file or package license field was observed' },
  { code: 'path-boundary-not-obvious', severity: 'warning', description: 'patch mutation was found but no obvious path containment check was observed' },
].map(item => Object.freeze({ ...item })))

const CODE_SIGNALS = {
  shellExecution: [
    /\b(?:node:)?child_process\b/i,
    /\b(?:exec|execSync|spawn|spawnSync|execFile|fork)\s*\(/i,
    /\b(?:npm|pnpm|yarn)\s+(?:install|uninstall|ci|run)\b/i,
    /\bshell\s*:\s*true\b/i,
  ],
  lifecycle: [
    /\b(?:entry\.)?(?:update|dispose|refresh)\s*\(/i,
    /\b_dispose\b/i,
    /\bloader\.internal\b/i,
  ],
  cacheEviction: [
    /\brequire\.cache\b/i,
    /\bloadCache\b/i,
    /\b(?:invalidate|evict)(?:Module|Cache|Code)\b/i,
  ],
  patchWrite: [
    /cordis\.patch\.ya?ml/i,
    /\b(?:writeFile|writeFileSync|appendFile|appendFileSync)\s*\(/i,
  ],
  atomicWrite: [
    /\b(?:rename|renameSync|mkstemp|fsync|atomic)\b/i,
  ],
  watcher: [
    /\b(?:watchFile|watch|chokidar)\s*\(/i,
    /\bchokidar\b/i,
  ],
  controlPlane: [
    /_dsh\/hotswap/i,
    /\b(?:hotswap|hot-swap|hotReload|hot-reload)\b/i,
    /\/(?:restart|reset|reload)\b/i,
    /\bwebServer\b/i,
  ],
  auth: [
    /\b(?:authorization|bearer|token|csrf|authenticate|authentication|acl|role)\b/i,
    /\b(?:permission|permissions|accessPolicy|access-control)\b/i,
  ],
  origin: [
    /\b(?:origin|sameOrigin|same-origin)\b/i,
  ],
  queue: [
    /\b(?:queue|mutex|semaphore|serial|serialized|p-queue|p-limit)\b/i,
  ],
  rollback: [
    /\b(?:rollback|backup|receipt|restore)\b/i,
  ],
  coreProtection: [
    /\b(?:protected|protectedCore|coreProtection|allowlist|denylist|protectedNames)\b/i,
  ],
  containment: [
    /\b(?:realpath|relative|contain|within|isInside|path\.resolve)\b/i,
  ],
}

function definitionOf(code) {
  return FINDING_DEFINITIONS.find(item => item.code === code)
}

function normalizedRelative(root, path) {
  const value = relative(root, path).replace(/\\/g, '/')
  return value || '.'
}

function isTextCandidate(path) {
  const name = path.split(/[\\/]/).pop()?.toLowerCase() ?? ''
  if (name === 'package.json' || name.startsWith('license') || name.startsWith('readme')) return true
  return TEXT_EXTENSIONS.has(extname(name))
}

function isCodePath(path) {
  return new Set(['.cjs', '.cts', '.js', '.mjs', '.mts', '.ts', '.tsx']).has(extname(path).toLowerCase())
    || path.toLowerCase() === 'package.json'
}

function hasSignal(text, patterns) {
  return patterns.some(pattern => pattern.test(text))
}

function normalizeLimit(value, fallback, maximum) {
  const number = Number(value)
  if (!Number.isFinite(number)) return fallback
  return Math.max(1, Math.min(maximum, Math.floor(number)))
}

function newState(root, options) {
  return {
    root,
    maxFiles: normalizeLimit(options.maxFiles, MAX_FILES, MAX_FILES),
    maxFileBytes: normalizeLimit(options.maxFileBytes, MAX_FILE_BYTES, MAX_FILE_BYTES),
    maxTotalBytes: normalizeLimit(options.maxTotalBytes, MAX_TOTAL_BYTES, MAX_TOTAL_BYTES),
    filesScanned: 0,
    bytesRead: 0,
    truncated: false,
    readErrors: [],
    limitations: [],
    documents: [],
    codeDocuments: [],
    packageManifest: null,
    testsDetected: false,
    ciDetected: false,
    licenseDetected: false,
    findings: [],
  }
}

function addFinding(state, code, detail = undefined, files = []) {
  if (state.findings.some(item => item.code === code)) return
  if (state.findings.length >= MAX_FINDINGS) {
    state.truncated = true
    return
  }
  const definition = definitionOf(code)
  state.findings.push({
    code,
    severity: definition?.severity ?? 'warning',
    detail: detail ?? definition?.description ?? code,
    files: files.slice(0, MAX_FINDING_FILES),
  })
}

function matchingFiles(state, patterns) {
  return state.codeDocuments
    .filter(item => hasSignal(item.text, patterns))
    .map(item => item.path)
    .slice(0, MAX_FINDING_FILES)
}

async function scanFile(state, absolute, relativePath, stat) {
  if (state.filesScanned >= state.maxFiles || state.bytesRead + stat.size > state.maxTotalBytes) {
    state.truncated = true
    state.limitations.push('bounded file/byte budget exhausted')
    return
  }
  if (stat.size > state.maxFileBytes) {
    state.truncated = true
    state.limitations.push(`skipped oversized file: ${relativePath}`)
    return
  }
  try {
    const text = await readFile(absolute, 'utf8')
    state.filesScanned += 1
    state.bytesRead += stat.size
    const document = { path: relativePath, text }
    state.documents.push(document)
    if (isCodePath(relativePath)) state.codeDocuments.push(document)
    const lower = relativePath.toLowerCase()
    const base = lower.split('/').pop() ?? ''
    if (base === 'package.json') {
      try { state.packageManifest = JSON.parse(text) } catch { state.packageManifest = null }
    }
    if (base.startsWith('license')) state.licenseDetected = true
    if (/(?:^|\/)(?:test|tests|__tests__)(?:\/|$)|\.(?:test|spec)\.[^.]+$/i.test(relativePath)) state.testsDetected = true
    if (/(?:^|\/)\.github\/workflows\//i.test(`/${relativePath}`)) state.ciDetected = true
  } catch (error) {
    state.readErrors.push(relativePath)
    state.limitations.push(`could not read ${relativePath}: ${error instanceof Error ? error.message : 'unknown read error'}`)
  }
}

async function scanDirectory(state, directory) {
  let entries
  try {
    entries = await readdir(directory, { withFileTypes: true })
  } catch (error) {
    state.readErrors.push(normalizedRelative(state.root, directory))
    state.limitations.push(`could not enumerate ${normalizedRelative(state.root, directory)}: ${error instanceof Error ? error.message : 'unknown read error'}`)
    return
  }
  entries.sort((left, right) => left.name.localeCompare(right.name))
  for (const entry of entries) {
    if (state.truncated) return
    const absolute = join(directory, entry.name)
    const relativePath = normalizedRelative(state.root, absolute)
    if (entry.isDirectory() && SKIP_DIRECTORIES.has(entry.name.toLowerCase())) continue
    let stat
    try { stat = await lstat(absolute) } catch {
      state.readErrors.push(relativePath)
      continue
    }
    if (stat.isSymbolicLink()) {
      state.limitations.push(`skipped symbolic link: ${relativePath}`)
      continue
    }
    if (stat.isDirectory()) {
      await scanDirectory(state, absolute)
      continue
    }
    if (stat.isFile() && isTextCandidate(relativePath)) await scanFile(state, absolute, relativePath, stat)
  }
}

function analyze(state, strict) {
  const codeText = state.codeDocuments.map(item => item.text).join('\n')
  const packageText = state.packageManifest ? JSON.stringify(state.packageManifest) : ''
  const observedText = `${codeText}\n${packageText}`
  const lifecycle = hasSignal(observedText, CODE_SIGNALS.lifecycle)
  const patchWrite = hasSignal(observedText, CODE_SIGNALS.patchWrite)
  const watcher = hasSignal(observedText, CODE_SIGNALS.watcher)
  const controlPlane = hasSignal(observedText, CODE_SIGNALS.controlPlane) && (lifecycle || watcher || patchWrite)
  const auth = hasSignal(observedText, CODE_SIGNALS.auth)
  const origin = hasSignal(observedText, CODE_SIGNALS.origin)
  const queue = hasSignal(observedText, CODE_SIGNALS.queue)
  const rollback = hasSignal(observedText, CODE_SIGNALS.rollback)
  const coreProtection = hasSignal(observedText, CODE_SIGNALS.coreProtection)
  const atomicWrite = hasSignal(observedText, CODE_SIGNALS.atomicWrite)
  const containment = hasSignal(observedText, CODE_SIGNALS.containment)

  const signalRules = [
    ['shell-execution', CODE_SIGNALS.shellExecution, 'static source scan found a shell/package-manager execution indicator'],
    ['private-lifecycle-api', CODE_SIGNALS.lifecycle, 'static source scan found lifecycle-shaped APIs; this is not proof that the API is supported'],
    ['module-cache-eviction', CODE_SIGNALS.cacheEviction, undefined],
    ['profile-patch-write', CODE_SIGNALS.patchWrite, undefined],
    ['file-watcher', CODE_SIGNALS.watcher, undefined],
  ]
  for (const [code, patterns, detail] of signalRules) {
    const files = matchingFiles(state, patterns)
    if (files.length > 0) addFinding(state, code, detail, files)
  }

  if (controlPlane && !auth) {
    addFinding(state, origin ? 'origin-only-control-plane' : 'unauthenticated-control-plane', undefined, matchingFiles(state, CODE_SIGNALS.controlPlane))
  }
  if (patchWrite && !atomicWrite) addFinding(state, 'non-atomic-patch-write', undefined, matchingFiles(state, CODE_SIGNALS.patchWrite))
  if (watcher && !queue) addFinding(state, 'watcher-without-queue', undefined, matchingFiles(state, CODE_SIGNALS.watcher))
  if ((lifecycle || patchWrite) && !rollback) addFinding(state, 'missing-rollback', undefined, matchingFiles(state, [...CODE_SIGNALS.lifecycle, ...CODE_SIGNALS.patchWrite]))
  if (lifecycle && !queue) addFinding(state, 'missing-serial-queue', undefined, matchingFiles(state, CODE_SIGNALS.lifecycle))
  if (lifecycle && !coreProtection) addFinding(state, 'missing-core-protection', undefined, matchingFiles(state, CODE_SIGNALS.lifecycle))
  if (patchWrite && !containment) addFinding(state, 'path-boundary-not-obvious', undefined, matchingFiles(state, CODE_SIGNALS.patchWrite))
  if (!state.testsDetected) addFinding(state, 'missing-tests')
  if (!state.ciDetected) addFinding(state, 'missing-ci')
  const packageLicense = state.packageManifest && typeof state.packageManifest.license === 'string' && state.packageManifest.license.trim() !== ''
  if (!state.licenseDetected && !packageLicense) addFinding(state, 'missing-license')
  if (!state.packageManifest) addFinding(state, 'missing-package-manifest')
  if (state.truncated) addFinding(state, 'scan-truncated')
  if (state.readErrors.length > 0) addFinding(state, 'read-error', undefined, state.readErrors)

  const hardReview = state.findings.some(item => item.severity === 'error')
    || (lifecycle && state.findings.some(item => ['private-lifecycle-api', 'missing-rollback', 'missing-serial-queue', 'missing-core-protection'].includes(item.code)))
  let verdict = 'PASS'
  if (state.findings.some(item => item.code === 'source-unavailable')) verdict = 'UNAVAILABLE'
  else if (state.readErrors.length > 0 && state.filesScanned === 0) verdict = 'UNAVAILABLE'
  else if (hardReview || (strict && state.findings.some(item => item.severity === 'warning'))) verdict = 'MANUAL_REVIEW'
  else if (state.findings.length > 0) verdict = 'PARTIAL'

  return {
    schemaVersion: HOTSWAP_PREFLIGHT_SCHEMA_VERSION,
    action: 'plugin_hotswap_preflight',
    mode: 'offline-static',
    verdict,
    root: state.root,
    source: {
      filesScanned: state.filesScanned,
      bytesRead: state.bytesRead,
      codeFilesScanned: state.codeDocuments.length,
      packageName: typeof state.packageManifest?.name === 'string' ? state.packageManifest.name : null,
      testsDetected: state.testsDetected,
      ciDetected: state.ciDetected,
      licenseDetected: state.licenseDetected || Boolean(packageLicense),
      lifecycleSignalsObserved: lifecycle,
      controlPlaneSignalsObserved: controlPlane,
      patchWriteSignalsObserved: patchWrite,
      watcherSignalsObserved: watcher,
    },
    findings: state.findings,
    limitations: [
      'static indicators are not a runtime exploit proof or a compatibility certification',
      'absence of a finding is not proof that a lifecycle or authorization property exists',
      ...state.limitations.slice(0, 20),
    ],
    truncated: state.truncated,
    networkAccessed: false,
    commandsExecuted: false,
    executesPluginCode: false,
    targetMutated: false,
    actualHotSwap: false,
    execution: 'NOT_ATTEMPTED',
  }
}

export const getHotswapPreflightSchema = () => FINDING_DEFINITIONS.map(item => ({
  ...item,
  schemaVersion: HOTSWAP_PREFLIGHT_SCHEMA_VERSION,
}))

export async function preflightHotswapSource(directory, { strict = false, ...options } = {}) {
  const root = resolve(String(directory ?? ''))
  const state = newState(root, options)
  try {
    const stat = await lstat(root)
    if (stat.isSymbolicLink() || !stat.isDirectory()) {
      addFinding(state, 'source-unavailable', 'candidate root must be a real directory, not a file or symbolic link')
      return analyze(state, strict)
    }
  } catch (error) {
    addFinding(state, 'source-unavailable', error instanceof Error ? error.message : 'candidate root could not be read')
    return analyze(state, strict)
  }
  await scanDirectory(state, root)
  return analyze(state, strict)
}
