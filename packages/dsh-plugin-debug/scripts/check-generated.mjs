import { readdir, readFile } from 'node:fs/promises'
import { createHash } from 'node:crypto'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { renderClient } from './build-client.mjs'

const root = resolve(fileURLToPath(new URL('..', import.meta.url)))
const manifestPath = resolve(root, 'bundle-manifest.json')
const manifest = JSON.parse(await readFile(manifestPath, 'utf8'))

if (manifest.package !== 'dsh-plugin-debug') {
  throw new Error(`bundle manifest package mismatch: ${manifest.package}`)
}
if (!manifest.files || typeof manifest.files !== 'object') {
  throw new Error('bundle manifest has no files map')
}

const sourcePairs = [
  ['src/index.js', 'lib/index.js'],
  ['src/hotswap-check.js', 'lib/hotswap-check.js'],
  ['src/agent-report.js', 'lib/agent-report.js'],
  ['src/repository-check.js', 'lib/repository-check.js'],
  ['src/tool-adapter.js', 'lib/tool-adapter.js'],
  ['src/task-guardian.js', 'lib/task-guardian.js'],
]

const expectedLibFiles = new Set([
  'client.js',
  ...sourcePairs.map(([, generated]) => generated.slice('lib/'.length)),
])
const libEntries = await readdir(resolve(root, 'lib'), { withFileTypes: true })
const unexpectedLibFiles = libEntries
  .filter(entry => !entry.isFile() || !expectedLibFiles.has(entry.name))
  .map(entry => entry.name)
if (unexpectedLibFiles.length > 0) {
  throw new Error(`lib contains unexpected generated artifacts: ${unexpectedLibFiles.join(', ')}`)
}

for (const [sourceRelative, generatedRelative] of sourcePairs) {
  const source = await readFile(resolve(root, sourceRelative))
  const generated = await readFile(resolve(root, generatedRelative))
  if (!source.equals(generated)) {
    throw new Error(`generated artifact differs from source: ${sourceRelative} != ${generatedRelative}`)
  }
}

const clientSource = await readFile(resolve(root, 'src', 'client-factory.cjs'), 'utf8')
const generatedClient = await readFile(resolve(root, 'lib', 'client.js'), 'utf8')
if (generatedClient !== renderClient(clientSource)) {
  throw new Error('generated artifact differs from source: src/client-factory.cjs != lib/client.js')
}

const expectedManifestFiles = [
  'package.json',
  'cordis.patch.yml',
  ...sourcePairs.map(([, generated]) => generated),
  'lib/client.js',
]
const manifestKeys = Object.keys(manifest.files).sort()
const expectedManifestKeys = expectedManifestFiles.slice().sort()
if (JSON.stringify(manifestKeys) !== JSON.stringify(expectedManifestKeys)) {
  throw new Error(`bundle manifest file set mismatch: expected ${expectedManifestKeys.join(', ')}, got ${manifestKeys.join(', ')}`)
}
for (const relative of expectedManifestFiles) {
  const entry = manifest.files[relative]
  if (!entry || !Number.isInteger(entry.bytes) || typeof entry.sha256 !== 'string') {
    throw new Error(`bundle manifest is missing generated file entry: ${relative}`)
  }
  const contents = await readFile(resolve(root, relative))
  const sha256 = createHash('sha256').update(contents).digest('hex')
  if (entry.bytes !== contents.byteLength || entry.sha256 !== sha256) {
    throw new Error(`bundle manifest hash mismatch: ${relative}`)
  }
}

console.log(`generated artifacts verified: ${expectedManifestFiles.length} manifest entries`)
