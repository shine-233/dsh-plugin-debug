import { cpSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { buildClient } from './build-client.mjs'

const root = resolve(fileURLToPath(new URL('..', import.meta.url)))
const POINTER_OBSERVATION_SCHEMA_VERSION = 2
mkdirSync(resolve(root, 'lib'), { recursive: true })
cpSync(resolve(root, 'src', 'index.js'), resolve(root, 'lib', 'index.js'))
cpSync(resolve(root, 'src', 'repository-check.js'), resolve(root, 'lib', 'repository-check.js'))
cpSync(resolve(root, 'src', 'tool-adapter.js'), resolve(root, 'lib', 'tool-adapter.js'))
await buildClient()

const bundleFiles = [
  'package.json',
  'cordis.patch.yml',
  'lib/index.js',
  'lib/client.js',
]
const files = Object.fromEntries(bundleFiles.map(relative => {
  const contents = readFileSync(resolve(root, relative))
  return [relative, {
    bytes: contents.byteLength,
    sha256: createHash('sha256').update(contents).digest('hex'),
  }]
}))
const bundleManifest = {
  schemaVersion: 1,
  package: 'dsh-plugin-debug',
  version: JSON.parse(readFileSync(resolve(root, 'package.json'), 'utf8')).version,
  bundleType: 'dsh-npm-bundle',
  independentRuntime: true,
  features: {
    pointerProvenance: {
      embedded: true,
      clientEntry: 'lib/client.js',
      global: '__DSH_PLUGIN_DEBUG__',
      legacyGlobal: '__DSH_PLUGIN_PROVENANCE__',
      bridgeSelector: 'meta[data-dsh-debug-bridge="1"]',
      pointerEvent: 'dsh-plugin-debug:pointer',
      observationSchemaVersion: POINTER_OBSERVATION_SCHEMA_VERSION,
      apiMethod: 'getPointerEvidence',
    },
    clientDiagnostics: true,
    hostPolicy: true,
    externalCrashGuard: true,
    metadataTraceAutopsy: true,
    boundedKnownGoodRecovery: true,
    localRpcFixture: true,
  },
  files,
}
writeFileSync(resolve(root, 'bundle-manifest.json'), `${JSON.stringify(bundleManifest, null, 2)}\n`, 'utf8')
