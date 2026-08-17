import { existsSync } from 'node:fs'
import { readFile } from 'node:fs/promises'
import { resolve, sep } from 'node:path'
import { fileURLToPath } from 'node:url'

const packageRoot = resolve(fileURLToPath(new URL('..', import.meta.url)))
const runtimeRoot = resolve(packageRoot, 'tools', 'runtime')
const packageManifestPath = resolve(runtimeRoot, 'package.json')
const lockPath = resolve(runtimeRoot, 'package-lock.json')
const checkInstalled = process.argv.slice(2).includes('--installed')

function stableDependencies(value) {
  return Object.fromEntries(Object.entries(value || {}).sort(([left], [right]) => left.localeCompare(right)))
}

function readJson(file, label) {
  return readFile(file, 'utf8').then(text => {
    try { return JSON.parse(text) } catch (error) { throw new Error(`${label} is not valid JSON: ${error.message}`) }
  })
}

function packagePathFromLockKey(lockKey) {
  const relative = lockKey.replaceAll('/', sep)
  return resolve(runtimeRoot, relative, 'package.json')
}

try {
  for (const [file, label] of [[packageManifestPath, 'runtime package.json'], [lockPath, 'runtime package-lock.json']]) {
    if (!existsSync(file)) throw new Error(`${label} is missing: ${file}`)
  }
  const packageManifest = await readJson(packageManifestPath, 'runtime package.json')
  const lock = await readJson(lockPath, 'runtime package-lock.json')
  if (lock.lockfileVersion !== 3) throw new Error(`runtime lockfileVersion must be 3, got ${lock.lockfileVersion}`)
  if (!lock.packages || typeof lock.packages !== 'object') throw new Error('runtime lockfile has no packages map')

  const root = lock.packages['']
  if (!root || typeof root !== 'object') throw new Error('runtime lockfile has no root package entry')
  if (root.name !== packageManifest.name) throw new Error(`runtime package name drift: package.json=${packageManifest.name} lock=${root.name}`)
  if (root.version !== packageManifest.version) throw new Error(`runtime package version drift: package.json=${packageManifest.version} lock=${root.version}`)

  const expectedDependencies = stableDependencies({
    ...(packageManifest.dependencies || {}),
    ...(packageManifest.optionalDependencies || {}),
  })
  const lockedDependencies = stableDependencies({
    ...(root.dependencies || {}),
    ...(root.optionalDependencies || {}),
  })
  if (JSON.stringify(expectedDependencies) !== JSON.stringify(lockedDependencies)) {
    throw new Error(`runtime root dependency drift:\npackage.json=${JSON.stringify(expectedDependencies)}\npackage-lock=${JSON.stringify(lockedDependencies)}`)
  }

  const lockedEntries = Object.entries(lock.packages)
    .filter(([key]) => key.startsWith('node_modules/'))
    .sort(([left], [right]) => left.localeCompare(right))
  let checked = 0
  let optionalMissing = 0
  if (checkInstalled) {
    const nodeModulesRoot = resolve(runtimeRoot, 'node_modules')
    if (!existsSync(nodeModulesRoot)) throw new Error('runtime node_modules is missing; run npm ci --prefix tools/runtime --omit=dev --ignore-scripts first')
  }
  for (const [lockKey, entry] of lockedEntries) {
    if (!entry || typeof entry !== 'object' || entry.link === true) continue
    if (typeof entry.version !== 'string' || entry.version.length === 0) continue
    checked += 1
    if (!checkInstalled) continue
    const installedPackagePath = packagePathFromLockKey(lockKey)
    if (!existsSync(installedPackagePath)) {
      if (entry.optional === true) { optionalMissing += 1; continue }
      throw new Error(`installed runtime tree is missing locked package: ${lockKey}`)
    }
    const installed = await readJson(installedPackagePath, `installed ${lockKey}/package.json`)
    if (installed.version !== entry.version) {
      throw new Error(`installed runtime version drift: ${lockKey} expected ${entry.version} got ${installed.version}`)
    }
  }

  const mode = checkInstalled ? 'installed-tree' : 'lockfile-only'
  console.log(JSON.stringify({
    result: 'PASS',
    mode,
    package: packageManifest.name,
    version: packageManifest.version,
    lockfileVersion: lock.lockfileVersion,
    lockedPackages: lockedEntries.length,
    checkedPackages: checked,
    optionalMissing,
  }, null, 2))
} catch (error) {
  console.error(`runtime lock check failed: ${error.message}`)
  process.exitCode = 1
}
