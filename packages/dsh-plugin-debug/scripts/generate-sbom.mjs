import { existsSync } from 'node:fs'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const packageRoot = resolve(fileURLToPath(new URL('..', import.meta.url)))
const sbomRoot = resolve(packageRoot, 'sbom')
const outputFiles = {
  spdx: resolve(sbomRoot, 'dsh-plugin-debug.spdx.json'),
  cdx: resolve(sbomRoot, 'dsh-plugin-debug.cdx.json'),
}
const checkOnly = process.argv.slice(2).includes('--check')

const pluginManifestPath = resolve(packageRoot, 'package.json')
const pluginLockPath = resolve(packageRoot, 'package-lock.json')
const runtimeRoot = resolve(packageRoot, 'tools', 'runtime')
const runtimeManifestPath = resolve(runtimeRoot, 'package.json')
const runtimeLockPath = resolve(runtimeRoot, 'package-lock.json')

async function readJson(file, label) {
  const text = await readFile(file, 'utf8')
  try { return JSON.parse(text) } catch (error) { throw new Error(`${label} is not valid JSON: ${error.message}`) }
}

function packageNameFromLockKey(key) {
  const marker = 'node_modules/'
  const markerIndex = key.lastIndexOf(marker)
  const installedPath = markerIndex < 0 ? key : key.slice(markerIndex + marker.length)
  const segments = installedPath.split('/')
  if (segments[0]?.startsWith('@')) return `${segments[0]}/${segments[1]}`
  return segments[0]
}

function encodePurlName(name) {
  return name.split('/').map(part => encodeURIComponent(part)).join('/')
}

function purlFor(name, version) {
  return `pkg:npm/${encodePurlName(name)}@${encodeURIComponent(version)}`
}

function stableObject(value) {
  return Object.fromEntries(Object.entries(value || {}).sort(([left], [right]) => left.localeCompare(right)))
}

function normalizeLicense(value) {
  if (typeof value === 'string' && value.trim()) return value.trim()
  if (value && typeof value === 'object') {
    if (typeof value.name === 'string' && value.name.trim()) return value.name.trim()
    if (typeof value.type === 'string' && value.type.trim()) return value.type.trim()
  }
  return 'NOASSERTION'
}

function checksumFromIntegrity(integrity) {
  if (typeof integrity !== 'string') return null
  const match = /^(sha512|sha384|sha256)-(.+)$/u.exec(integrity)
  if (!match) return null
  const algorithm = { sha512: 'SHA512', sha384: 'SHA384', sha256: 'SHA256' }[match[1]]
  const cdxAlgorithm = { sha512: 'SHA-512', sha384: 'SHA-384', sha256: 'SHA-256' }[match[1]]
  return { algorithm, cdxAlgorithm, value: match[2] }
}

function* lockKeyCandidate(parentKey, dependencyName) {
  const suffix = `node_modules/${dependencyName}`
  let cursor = parentKey
  while (cursor) {
    const candidate = `${cursor}/${suffix}`
    yield candidate
    const slash = cursor.lastIndexOf('/node_modules/')
    if (slash < 0) break
    cursor = cursor.slice(0, slash)
  }
  yield suffix
}

function resolveDependencyKey(lockPackages, ownerKey, dependencyName) {
  for (const candidate of lockKeyCandidate(ownerKey, dependencyName)) {
    if (lockPackages[candidate]) return candidate
  }
  return null
}

function addComponent(components, record) {
  const existing = components.get(record.purl)
  if (existing) {
    if (existing.properties?.[0]?.value !== record.source) {
      existing.properties = [{ name: 'dsh:lockfiles', value: 'plugin,runtime' }]
    }
    return existing
  }
  const component = {
    name: record.name,
    version: record.version,
    type: 'library',
    'bom-ref': record.purl,
    purl: record.purl,
    licenses: [{ license: record.license === 'NOASSERTION' ? { name: 'NOASSERTION' } : { id: record.license } }],
    properties: [{ name: 'dsh:lockfile', value: record.source }],
  }
  const checksum = checksumFromIntegrity(record.integrity)
  if (checksum) component.hashes = [{ alg: checksum.cdxAlgorithm, content: checksum.value }]
  if (record.resolved) component.externalReferences = [{ type: 'distribution', url: record.resolved }]
  components.set(record.purl, component)
  return component
}

function addSpdxPackage(packages, record) {
  const existing = packages.get(record.purl)
  if (existing) return existing
  const id = `SPDXRef-Package-${record.purl.replace(/[^A-Za-z0-9.-]/gu, '-').slice(0, 180)}`
  const item = {
    SPDXID: id,
    name: record.name,
    versionInfo: record.version,
    downloadLocation: record.resolved || 'NOASSERTION',
    filesAnalyzed: false,
    licenseConcluded: record.license,
    licenseDeclared: record.license,
    copyrightText: 'NOASSERTION',
    externalRefs: [{
      referenceCategory: 'PACKAGE-MANAGER',
      referenceType: 'purl',
      referenceLocator: record.purl,
    }],
  }
  const checksum = checksumFromIntegrity(record.integrity)
  if (checksum) item.checksums = [{ algorithm: checksum.algorithm, checksumValue: checksum.value }]
  packages.set(record.purl, item)
  return item
}

function recordFromEntry({ key, entry, source, rootManifest }) {
  const name = key === '' ? rootManifest.name : (entry.name || packageNameFromLockKey(key))
  const version = key === '' ? rootManifest.version : entry.version
  if (typeof name !== 'string' || typeof version !== 'string') return null
  return {
    key,
    name,
    version,
    purl: purlFor(name, version),
    license: normalizeLicense(key === '' ? rootManifest.license : entry.license),
    integrity: entry.integrity,
    resolved: entry.resolved,
    // Keep declared development and peer edges in the SBOM as well. The
    // plugin is intentionally shipped as a source release rather than an npm
    // runtime install, so omitting the root dev/peer edges would make the
    // committed inventory look smaller than the lockfile it claims to cover.
    dependencies: stableObject({
      ...(entry.dependencies || {}),
      ...(entry.optionalDependencies || {}),
      ...(entry.devDependencies || {}),
      ...(entry.peerDependencies || {}),
    }),
    source,
  }
}

function collectLockRecords(lock, source, rootManifest) {
  return Object.entries(lock.packages || {})
    .filter(([key, entry]) => key === '' || (key.startsWith('node_modules/') && entry && entry.link !== true))
    .map(([key, entry]) => recordFromEntry({ key, entry, source, rootManifest }))
    .filter(Boolean)
    .sort((left, right) => left.purl.localeCompare(right.purl))
}

function relationshipKey(left, right, relation) { return `${left}|${relation}|${right}` }

const pluginManifest = await readJson(pluginManifestPath, 'plugin package.json')
const runtimeManifest = await readJson(runtimeManifestPath, 'runtime package.json')
const pluginLock = await readJson(pluginLockPath, 'plugin package-lock.json')
const runtimeLock = await readJson(runtimeLockPath, 'runtime package-lock.json')
const pluginRecords = collectLockRecords(pluginLock, 'plugin', pluginManifest)
const runtimeRecords = collectLockRecords(runtimeLock, 'runtime', runtimeManifest)
const allRecords = [...pluginRecords, ...runtimeRecords]
const components = new Map()
const spdxPackages = new Map()
for (const record of allRecords) {
  addComponent(components, record)
  addSpdxPackage(spdxPackages, record)
}

const directRoots = [
  { source: 'plugin', lock: pluginLock, records: pluginRecords },
  { source: 'runtime', lock: runtimeLock, records: runtimeRecords },
]
const recordsByKey = new Map(directRoots.flatMap(({ records }) => records.map(record => [`${record.source}:${record.key}`, record])))
const relationships = new Set()
const cdxDependencies = new Map()
for (const { source, lock } of directRoots) {
  const lockPackages = lock.packages || {}
  for (const record of (source === 'plugin' ? pluginRecords : runtimeRecords)) {
    const dependencyRefs = []
    for (const dependencyName of Object.keys(record.dependencies)) {
      const targetKey = resolveDependencyKey(lockPackages, record.key, dependencyName)
      const target = targetKey ? recordsByKey.get(`${source}:${targetKey}`) : null
      if (!target) continue
      dependencyRefs.push(target.purl)
      relationships.add(relationshipKey(record.purl, target.purl, 'DEPENDS_ON'))
    }
    cdxDependencies.set(record.purl, new Set([...(cdxDependencies.get(record.purl) || []), ...dependencyRefs]))
  }
}

const pluginRoot = pluginRecords.find(record => record.key === '' && record.source === 'plugin')
const runtimeRootRecord = runtimeRecords.find(record => record.key === '' && record.source === 'runtime')
const allSpdxPackages = [...spdxPackages.values()].sort((left, right) => left.SPDXID.localeCompare(right.SPDXID))
const spdxRelationships = [
  { spdxElementId: 'SPDXRef-DOCUMENT', relationshipType: 'DESCRIBES', relatedSpdxElement: spdxPackages.get(pluginRoot.purl).SPDXID },
  { spdxElementId: 'SPDXRef-DOCUMENT', relationshipType: 'DESCRIBES', relatedSpdxElement: spdxPackages.get(runtimeRootRecord.purl).SPDXID },
  ...[...relationships].sort().map(value => {
    const [left, , right] = value.split('|')
    return {
      spdxElementId: spdxPackages.get(left).SPDXID,
      relationshipType: 'DEPENDS_ON',
      relatedSpdxElement: spdxPackages.get(right).SPDXID,
    }
  }),
]
const spdx = {
  SPDXID: 'SPDXRef-DOCUMENT',
  spdxVersion: 'SPDX-2.3',
  dataLicense: 'CC0-1.0',
  name: `dsh-plugin-debug-${pluginManifest.version}`,
  documentNamespace: `https://github.com/shine-233/dsh-plugin-debug/sbom/${pluginManifest.version}`,
  creationInfo: {
    created: '1970-01-01T00:00:00Z',
    creators: ['Tool: dsh-plugin-debug-sbom'],
  },
  packages: allSpdxPackages,
  relationships: spdxRelationships,
}

const cdxComponentList = [...components.values()]
  .sort((left, right) => left.purl.localeCompare(right.purl))
const cdxDependenciesList = [...cdxDependencies.entries()]
  .sort(([left], [right]) => left.localeCompare(right))
  .map(([ref, dependsOn]) => ({ ref, dependsOn: [...dependsOn].sort() }))
const cdx = {
  bomFormat: 'CycloneDX',
  specVersion: '1.5',
  version: 1,
  metadata: {
    component: {
      type: 'application',
      name: pluginManifest.name,
      version: pluginManifest.version,
      'bom-ref': pluginRoot.purl,
      purl: pluginRoot.purl,
    },
    tools: [{ vendor: 'shine-233', name: 'dsh-plugin-debug-sbom', version: pluginManifest.version }],
  },
  components: cdxComponentList,
  dependencies: cdxDependenciesList,
}

const serializations = {
  spdx: `${JSON.stringify(spdx, null, 2)}\n`,
  cdx: `${JSON.stringify(cdx, null, 2)}\n`,
}
if (checkOnly) {
  const mismatches = []
  for (const [kind, file] of Object.entries(outputFiles)) {
    if (!existsSync(file)) mismatches.push(`${kind}: missing ${file}`)
    else if (await readFile(file, 'utf8') !== serializations[kind]) mismatches.push(`${kind}: stale or non-deterministic content`)
  }
  if (mismatches.length > 0) {
    for (const mismatch of mismatches) console.error(`SBOM check failed: ${mismatch}`)
    process.exitCode = 1
  } else {
    console.log(`SBOM check passed: ${cdxComponentList.length} CycloneDX components and ${allSpdxPackages.length} SPDX packages`)
  }
} else {
  await mkdir(sbomRoot, { recursive: true })
  await writeFile(outputFiles.spdx, serializations.spdx, 'utf8')
  await writeFile(outputFiles.cdx, serializations.cdx, 'utf8')
  console.log(`SBOM generated: ${outputFiles.spdx}`)
  console.log(`SBOM generated: ${outputFiles.cdx}`)
}
