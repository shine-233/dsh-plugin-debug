import assert from 'node:assert/strict'
import { mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

import {
  GUARDIAN_STATUS_PATH,
  guardianToolFingerprint,
  normalizeGuardianConfig,
  registerTaskGuardian,
} from '../src/task-guardian.js'

function makeAgent(id, parentSession, delegationDepth) {
  const guided = []
  const injected = []
  const header = parentSession ? { parentSession } : {}
  if (delegationDepth !== undefined) header.delegationDepth = delegationDepth
  const session = { id, header }
  const agent = {
    id,
    session,
    status: 'idle',
    steer(message) { guided.push(message) },
    inject(message) { injected.push(message) },
  }
  return { agent, session, guided, injected }
}

function makeHarness(settingsOverride) {
  const listeners = new Map()
  const routes = []
  const agents = new Map()
  const logs = []
  const ctx = {
    agents: {
      get(id) { return agents.get(String(id)) },
      list() { return [...agents.values()] },
    },
    logger: { info(message) { logs.push(String(message)) } },
    on(name, handler) {
      if (!listeners.has(name)) listeners.set(name, [])
      listeners.get(name).push(handler)
      return () => {}
    },
    inject(services, callback) {
      const requested = new Set(services)
      let base = {}
      const scope = {
        get: () => ({ ...base, ...settingsOverride }),
        watch: () => () => {},
      }
      callback({
        settings: {
          register(_namespace, _schema, options) {
            base = options?.base ?? {}
            return scope
          },
        },
        webServer: {
          register(route) {
            routes.push(route)
            return () => {}
          },
        },
        effect(factory) { return factory() },
        requested,
      })
    },
  }
  return {
    ctx,
    routes,
    agents,
    logs,
    dispatch(name, ...args) {
      for (const listener of listeners.get(name) ?? []) listener(...args)
    },
  }
}

function callRoute(route, method = 'GET') {
  let status = 0
  let headers = {}
  let body = ''
  const response = {
    writeHead(value, nextHeaders) { status = value; headers = nextHeaders },
    end(value = '') { body = String(value) },
  }
  return Promise.resolve(route.handler({ method }, response)).then(() => ({ status, headers, body }))
}

test('guardian configuration is bounded and enabled by default', () => {
  const defaults = normalizeGuardianConfig()
  assert.equal(defaults.enabled, true)
  assert.equal(defaults.policy, 'auto')
  assert.equal(defaults.maxLoopRepeats, 5)
  assert.equal(defaults.maxSubagentDepth, 5)

  const bounded = normalizeGuardianConfig({ maxLoopRepeats: 99, loopWindowSize: 1, maxSubagentDepth: 0, policy: 'report' })
  assert.equal(bounded.maxLoopRepeats, 20)
  assert.equal(bounded.loopWindowSize, 20)
  assert.equal(bounded.maxSubagentDepth, 1)
  assert.equal(bounded.policy, 'report')
  assert.equal(bounded.eventLogMaxBytes, 262144)
  assert.equal(bounded.eventLogMaxFiles, 3)
})

test('guardian event log rotates into a bounded set of redacted files', () => {
  const home = mkdtempSync(join(tmpdir(), 'dsh-debug-guardian-'))
  try {
    const harness = makeHarness()
    const subject = makeAgent('rotation-session')
    subject.agent.status = 'running'
    harness.agents.set(subject.agent.id, subject.agent)
    const controller = registerTaskGuardian(harness.ctx, {
      policy: 'report',
      maxLoopRepeats: 2,
      loopWindowSize: 2,
      eventLogMaxBytes: 1024,
      eventLogMaxFiles: 3,
    }, { home })

    harness.dispatch('agent/created', { agent: subject.agent })
    for (let index = 0; index < 30; index += 1) {
      const event = {
        type: 'tool/call',
        data: { name: 'read', arguments: { path: `fixture-${index}`, token: 'secret-value' } },
      }
      harness.dispatch('session/event', subject.session, event)
      harness.dispatch('session/event', subject.session, event)
    }

    const guardianRoot = join(home, 'guardian')
    const files = readdirSync(guardianRoot).filter(name => name === 'events.jsonl' || /^events\.jsonl\.\d+$/u.test(name))
    assert.ok(files.includes('events.jsonl.1'))
    assert.ok(files.length <= 3)
    assert.equal(files.includes('events.jsonl.3'), false)
    for (const file of files) {
      const path = join(guardianRoot, file)
      assert.ok(statSync(path).size <= 1024)
      for (const line of readFileSync(path, 'utf8').trim().split(/\r?\n/u).filter(Boolean)) {
        const event = JSON.parse(line)
        assert.doesNotMatch(JSON.stringify(event), /secret-value|fixture-\d+/u)
      }
    }
    const snapshot = controller.snapshot()
    assert.deepEqual(snapshot.privacy.eventLogRetention, { maxBytes: 1024, maxFiles: 3 })
  } finally {
    rmSync(home, { recursive: true, force: true })
  }
})

test('guardian event log prunes stale archives and keeps oversized input out of reports', () => {
  const home = mkdtempSync(join(tmpdir(), 'dsh-debug-guardian-'))
  try {
    const guardianRoot = join(home, 'guardian')
    const eventFile = join(guardianRoot, 'events.jsonl')
    const staleArchive = join(guardianRoot, 'events.jsonl.3')
    const oversizedArchive = join(guardianRoot, 'events.jsonl.4')
    const subject = makeAgent('retention-session')
    subject.agent.status = 'running'
    const harness = makeHarness()
    harness.agents.set(subject.agent.id, subject.agent)
    const controller = registerTaskGuardian(harness.ctx, {
      policy: 'report',
      maxLoopRepeats: 2,
      loopWindowSize: 2,
      eventLogMaxBytes: 1024,
      eventLogMaxFiles: 3,
    }, { home })

    writeFileSync(eventFile, `${'x'.repeat(1010)}\n`, 'utf8')
    writeFileSync(staleArchive, 'stale\n', 'utf8')
    writeFileSync(oversizedArchive, 'stale\n', 'utf8')
    harness.dispatch('agent/created', { agent: subject.agent })
    const repeatedEvent = {
      type: 'tool/call',
      data: { name: 'read', arguments: { path: 'fixture', token: 'secret-value' } },
    }
    harness.dispatch('session/event', subject.session, repeatedEvent)
    harness.dispatch('session/event', subject.session, repeatedEvent)

    assert.equal(readdirSync(guardianRoot).includes('events.jsonl.3'), false)
    assert.equal(readdirSync(guardianRoot).includes('events.jsonl.4'), false)
    assert.ok(controller.snapshot().privacy.eventLogRetention.maxFiles === 3)

    const largeHome = mkdtempSync(join(tmpdir(), 'dsh-debug-guardian-large-'))
    try {
      const largeHarness = makeHarness()
      const largeSubject = makeAgent('oversized-session')
      largeSubject.agent.status = 'running'
      largeHarness.agents.set(largeSubject.agent.id, largeSubject.agent)
      registerTaskGuardian(largeHarness.ctx, {
        policy: 'report',
        eventLogMaxBytes: 1024,
        eventLogMaxFiles: 3,
      }, { home: largeHome })
      largeHarness.dispatch('agent/created', { agent: largeSubject.agent })
      const oversizedArguments = Object.fromEntries(Array.from({ length: 100 }, (_, index) => [`field-${index}`, 'x'.repeat(200)]))
      largeHarness.dispatch('session/event', largeSubject.session, {
        type: 'tool/call',
        data: { name: 'read', arguments: oversizedArguments },
      })
      const largeEventFile = join(largeHome, 'guardian', 'events.jsonl')
      assert.ok(statSync(largeEventFile).size <= 1024)
      assert.doesNotMatch(readFileSync(largeEventFile, 'utf8'), /field-\d+|x{50}/u)
    } finally {
      rmSync(largeHome, { recursive: true, force: true })
    }
  } finally {
    rmSync(home, { recursive: true, force: true })
  }
})

test('tool fingerprints are stable without returning raw arguments', () => {
  const first = guardianToolFingerprint({ data: { name: 'bash', arguments: { token: 'secret-a', cmd: 'echo ok', nested: { b: 2, a: 1 } } } })
  const second = guardianToolFingerprint({ data: { arguments: { nested: { a: 1, b: 2 }, cmd: 'echo ok', token: 'secret-b' }, name: 'bash' } })
  const third = guardianToolFingerprint({ data: { name: 'bash', arguments: '{"cmd":"echo ok","nested":{"a":1,"b":2},"token":"secret-c"}' } })
  assert.equal(first, second)
  assert.equal(first, third)
  assert.match(first, /^[a-f0-9]{64}$/u)
  assert.doesNotMatch(first, /secret|echo/u)
})

test('settings overrides are resolved through the official base-layer API', () => {
  const harness = makeHarness({ policy: 'report', maxLoopRepeats: 2 })
  const subject = makeAgent('settings-session')
  subject.agent.status = 'running'
  harness.agents.set(subject.agent.id, subject.agent)
  const controller = registerTaskGuardian(harness.ctx, {
    policy: 'auto',
    maxLoopRepeats: 5,
    eventLog: false,
  })

  assert.equal(controller.snapshot().policy, 'report')
  harness.dispatch('agent/created', { agent: subject.agent })
  harness.dispatch('session/event', subject.session, { type: 'tool/call', data: { name: 'read', arguments: '{}' } })
  harness.dispatch('session/event', subject.session, { type: 'tool/call', data: { name: 'read', arguments: '{}' } })
  assert.equal(subject.guided.length, 0)
  assert.equal(controller.snapshot().recentEvents.some(event => event.kind === 'LOOP_DETECTED'), true)
})

test('live loop detection steers once, reports metadata, and never exposes session IDs', () => {
  const home = mkdtempSync(join(tmpdir(), 'dsh-debug-guardian-'))
  let clock = 1000
  try {
    const harness = makeHarness()
    const subject = makeAgent('raw-session-secret')
    subject.agent.status = 'running'
    harness.agents.set(subject.agent.id, subject.agent)
    const controller = registerTaskGuardian(harness.ctx, {
      maxLoopRepeats: 3,
      loopWindowSize: 4,
      cooldownMs: 30000,
    }, { home, now: () => clock })

    harness.dispatch('agent/created', { agent: subject.agent })
    harness.dispatch('agent/status', { agent: subject.agent, status: 'running' })
    for (let index = 0; index < 3; index += 1) {
      harness.dispatch('session/event', subject.session, {
        type: 'tool/call',
        data: { name: 'bash', arguments: { cmd: 'echo repeated', password: 'fixture-secret' } },
      })
    }

    assert.equal(subject.guided.length, 1)
    assert.equal(subject.guided[0].source.plugin, 'dsh-plugin-debug-guardian')
    assert.match(subject.guided[0].content[0].text, /循环/u)
    const snapshot = controller.snapshot()
    assert.equal(snapshot.recentEvents.some(event => event.kind === 'LOOP_DETECTED'), true)
    assert.equal(snapshot.recentEvents.some(event => event.kind === 'LOOP_GUIDED'), true)
    assert.equal(snapshot.safety.terminatesTasks, false)
    assert.equal(snapshot.safety.restartsHost, false)
    assert.equal(snapshot.privacy.rawSessionIdsReturned, false)
    assert.doesNotMatch(JSON.stringify(snapshot), /raw-session-secret|fixture-secret|echo repeated/u)

    clock += 1
    for (let index = 0; index < 3; index += 1) {
      harness.dispatch('session/event', subject.session, { type: 'tool/call', data: { name: 'bash', arguments: { cmd: 'echo repeated' } } })
    }
    assert.equal(subject.guided.length, 1)

    const eventText = readFileSync(join(home, 'guardian', 'events.jsonl'), 'utf8')
    assert.match(eventText, /LOOP_DETECTED/u)
    assert.doesNotMatch(eventText, /raw-session-secret|fixture-secret|echo repeated/u)
  } finally {
    rmSync(home, { recursive: true, force: true })
  }
})

test('report policy detects without steering or injecting', () => {
  const harness = makeHarness()
  const subject = makeAgent('report-session')
  subject.agent.status = 'running'
  harness.agents.set(subject.agent.id, subject.agent)
  const controller = registerTaskGuardian(harness.ctx, {
    policy: 'report',
    maxLoopRepeats: 2,
    eventLog: false,
  })
  harness.dispatch('agent/created', { agent: subject.agent })
  harness.dispatch('session/event', subject.session, { type: 'tool/call', data: { name: 'read', arguments: '{}' } })
  harness.dispatch('session/event', subject.session, { type: 'tool/call', data: { name: 'read', arguments: '{}' } })
  assert.equal(subject.guided.length, 0)
  assert.equal(subject.injected.length, 0)
  assert.equal(controller.snapshot().recentEvents.some(event => event.kind === 'LOOP_DETECTED'), true)
})

test('recent event state remains bounded independently of the append-only audit file', () => {
  const harness = makeHarness()
  const subject = makeAgent('bounded-events')
  subject.agent.status = 'running'
  harness.agents.set(subject.agent.id, subject.agent)
  const controller = registerTaskGuardian(harness.ctx, {
    policy: 'report',
    maxLoopRepeats: 2,
    maxRecentEvents: 10,
    eventLog: false,
  })
  harness.dispatch('agent/created', { agent: subject.agent })
  for (let index = 0; index < 20; index += 1) {
    harness.dispatch('session/event', subject.session, { type: 'tool/call', data: { name: 'read', arguments: '{}' } })
    harness.dispatch('session/event', subject.session, { type: 'tool/call', data: { name: 'read', arguments: '{}' } })
  }
  assert.equal(controller.snapshot().recentEvents.length, 10)
})

test('agent lineage and workflow events detect recursion without ending any task', () => {
  const harness = makeHarness()
  const root = makeAgent('root')
  const child = makeAgent('child', 'root')
  const grandchild = makeAgent('grandchild', 'child')
  for (const subject of [root, child, grandchild]) harness.agents.set(subject.agent.id, subject.agent)
  const controller = registerTaskGuardian(harness.ctx, {
    maxSubagentDepth: 1,
    cooldownMs: 0,
    eventLog: false,
  })
  harness.dispatch('agent/created', { agent: root.agent })
  harness.dispatch('agent/created', { agent: child.agent })
  harness.dispatch('agent/created', { agent: grandchild.agent })
  assert.equal(grandchild.injected.length, 1)
  assert.match(grandchild.injected[0].content[0].text, /递归/u)

  harness.dispatch('session/event', root.session, { type: 'tool-workflow/agent-start', data: {} })
  harness.dispatch('session/event', root.session, { type: 'tool-workflow/agent-start', data: {} })
  assert.equal(root.injected.length, 1)
  assert.equal(controller.snapshot().recentEvents.filter(event => event.kind === 'RECURSION_DETECTED').length, 2)
  assert.equal(controller.snapshot().safety.stopsProcesses, false)
  assert.equal(controller.snapshot().safety.disablesPlugins, false)
})

test('persisted delegation depth detects recursion when the parent agent is absent', () => {
  const harness = makeHarness()
  const subject = makeAgent('orphan-grandchild', 'missing-parent', 2)
  harness.agents.set(subject.agent.id, subject.agent)
  const controller = registerTaskGuardian(harness.ctx, {
    maxSubagentDepth: 1,
    cooldownMs: 0,
    eventLog: false,
  })

  harness.dispatch('agent/created', { agent: subject.agent })
  assert.equal(subject.injected.length, 1)
  assert.equal(controller.snapshot().watching[0].depth, 2)
  assert.equal(controller.snapshot().recentEvents.some(event => event.kind === 'RECURSION_DETECTED' && event.depth === 2), true)
})

test('status route refuses to call a running or busy state safe to restart', async () => {
  const harness = makeHarness()
  const subject = makeAgent('status-private-id')
  harness.agents.set(subject.agent.id, subject.agent)
  registerTaskGuardian(harness.ctx, { eventLog: false })
  harness.dispatch('agent/created', { agent: subject.agent })
  subject.agent.status = 'running'
  harness.dispatch('agent/status', { agent: subject.agent, status: 'running' })
  harness.dispatch('session/event', subject.session, { type: 'tool/call', data: { name: 'tool', arguments: '{}' } })

  const route = harness.routes.find(candidate => candidate.path === GUARDIAN_STATUS_PATH)
  assert.ok(route)
  const active = await callRoute(route)
  assert.equal(active.status, 200)
  assert.equal(active.headers['cache-control'], 'no-store')
  const activeBody = JSON.parse(active.body)
  assert.equal(activeBody.safeToRestart, false)
  assert.equal(activeBody.activeSessions, 1)
  assert.equal(activeBody.inFlightOperations, 1)
  assert.doesNotMatch(active.body, /status-private-id/u)

  harness.dispatch('session/event', subject.session, { type: 'tool/result', data: {} })
  subject.agent.status = 'idle'
  harness.dispatch('agent/status', { agent: subject.agent, status: 'idle' })
  const idle = JSON.parse((await callRoute(route)).body)
  assert.equal(idle.safeToRestart, true)
  assert.equal((await callRoute(route, 'POST')).status, 405)
})

test('official aborted and max-tokens turns are reported as interruption metadata', () => {
  const harness = makeHarness()
  const subject = makeAgent('interrupt-private-id')
  harness.agents.set(subject.agent.id, subject.agent)
  const controller = registerTaskGuardian(harness.ctx, { eventLog: false })
  harness.dispatch('agent/created', { agent: subject.agent })
  harness.dispatch('session/event', subject.session, { type: 'turn/start', data: { turn: 7 } })
  harness.dispatch('session/event', subject.session, { type: 'turn/end', data: { reason: { kind: 'aborted', detail: 'private' } } })
  harness.dispatch('session/event', subject.session, { type: 'turn/start', data: { turn: 8 } })
  harness.dispatch('session/event', subject.session, { type: 'turn/end', data: { reason: { kind: 'max-tokens', detail: 'private' } } })
  const events = controller.snapshot().recentEvents.filter(candidate => candidate.kind === 'INTERRUPTION_OBSERVED')
  assert.deepEqual(events.map(event => ({ reason: event.reason, turn: event.turn })), [
    { reason: 'aborted', turn: 7 },
    { reason: 'max-tokens', turn: 8 },
  ])
  assert.doesNotMatch(JSON.stringify(events), /interrupt-private-id|private/u)
})

test('guardian source has no task or process termination seam', () => {
  const source = readFileSync(new URL('../src/task-guardian.js', import.meta.url), 'utf8')
  assert.doesNotMatch(source, /\.cancel\s*\(|process\.kill\s*\(|Stop-Process|taskkill|child_process|\.dispose\s*\(/iu)
  assert.doesNotMatch(source, /session\.append\s*\(/u)
  assert.doesNotMatch(source, /String\(error\?\.message\s*\?\?/u)
  assert.match(source, /messagePresent=/u)
})
