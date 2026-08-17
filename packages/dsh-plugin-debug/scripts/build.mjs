import { cpSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { buildClient } from './build-client.mjs'

const root = resolve(fileURLToPath(new URL('..', import.meta.url)))
const POINTER_OBSERVATION_SCHEMA_VERSION = 2
mkdirSync(resolve(root, 'lib'), { recursive: true })
cpSync(resolve(root, 'src', 'index.js'), resolve(root, 'lib', 'index.js'))
  cpSync(resolve(root, 'src', 'hotswap-check.js'), resolve(root, 'lib', 'hotswap-check.js'))
  cpSync(resolve(root, 'src', 'agent-report.js'), resolve(root, 'lib', 'agent-report.js'))
cpSync(resolve(root, 'src', 'repository-check.js'), resolve(root, 'lib', 'repository-check.js'))
cpSync(resolve(root, 'src', 'tool-adapter.js'), resolve(root, 'lib', 'tool-adapter.js'))
cpSync(resolve(root, 'src', 'task-guardian.js'), resolve(root, 'lib', 'task-guardian.js'))
await buildClient()

const bundleFiles = [
  'package.json',
  'cordis.patch.yml',
  'lib/index.js',
  'lib/hotswap-check.js',
  'lib/agent-report.js',
  'lib/repository-check.js',
  'lib/tool-adapter.js',
  'lib/task-guardian.js',
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
    readOnlyPluginBisectPlan: true,
    readOnlyPluginPreflight: {
      standaloneTool: true,
      metadataOnly: true,
      dynamicAccessManualReview: true,
    },
    pluginRepositoryHealthCheck: {
      embedded: true,
      tool: 'plugin_check',
      actions: ['check', 'scan', 'schema'],
      reportSchemaVersion: 2,
      repositoryForms: ['registry', 'skill', 'collection', 'bundle', 'tool-bundle'],
      offlineOnly: true,
      executesPluginCode: false,
      manualInstallOnlyWarning: true,
      missingPrepackWarning: true,
      scannedSourceExtensions: ['.js', '.mjs', '.cjs', '.ts', '.mts', '.cts', '.tsx'],
    },
    pluginHotswapCapabilityCheck: {
      embedded: true,
      tool: 'plugin_hotswap_check',
      reportSchemaVersion: 1,
      readOnly: true,
      actualHotSwap: false,
      requiresAuthoritativeLifecycleContract: true,
      protectsCoreAndDynamicEntries: true,
      observesOfficialHmrWithoutInvokingIt: true,
      invokesInternalDisposeOrRefresh: false,
      rewritesProfile: false,
      installsDependencies: false,
    },
    deterministicAgentReport: {
      embedded: true,
      tool: 'dsh_agent_report',
      reportSchemaVersion: 1,
      readOnly: true,
      localDeterministicGeneration: true,
      generationTokens: 0,
      credentialReads: false,
      networkPricingFetch: false,
      rawCommandsInReport: false,
      rawSecretValuesInReport: false,
      dangerousTextDetectionOnly: true,
      executionEvidence: false,
      rawToolErrorsInReport: false,
      persistedHistoryWhenSessionQueryAvailable: true,
      liveSessionFallback: true,
      boundedSessions: 500,
      boundedEvents: 1000000,
      costIsEstimate: true,
    },
    readOnlyPluginDependencyGraph: {
      standaloneTool: true,
      metadataOnly: true,
      missingAndCycleWarnings: true,
    },
    readOnlyTraceLoopAnalysis: {
      standaloneTool: true,
      metadataOnly: true,
      slidingWindow: true,
      runtimeBlocking: false,
    },
    readOnlyTraceRecursionAnalysis: {
      standaloneTool: true,
      metadataOnly: true,
      boundedDepth: true,
      runtimeBlocking: false,
    },
    observerOnlyTaskGuardian: {
      embedded: true,
      statusPath: '/api/dsh-plugin-debug/guardian/status',
      liveLoopGuidance: true,
      liveRecursionGuidance: true,
      interruptionAwareness: true,
      boundedEventLog: {
        defaultMaxBytes: 262144,
        defaultMaxFiles: 3,
        configurableMaxBytes: [1024, 4194304],
        configurableMaxFiles: [2, 10],
      },
      taskTermination: false,
      processTermination: false,
      profileMutation: false,
    },
    diagnosticsDiff: {
      embedded: true,
      metadataOnly: true,
      manualReviewOnSensitiveInput: true,
    },
    boundedClientBreadcrumbs: {
      embedded: true,
      reportSchemaVersion: 6,
      maxItems: 80,
      metadataOnly: true,
    },
  },
  files,
}
writeFileSync(resolve(root, 'bundle-manifest.json'), `${JSON.stringify(bundleManifest, null, 2)}\n`, 'utf8')
