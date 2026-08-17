import assert from 'node:assert/strict'
import { access, mkdtemp, rm, symlink, writeFile } from 'node:fs/promises'
import { spawnSync } from 'node:child_process'
import test from 'node:test'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { aggregateAgentReportEvents, createAgentReportDocumentSource, createLiveSessionsReportSource, generateAgentReport, generateAgentReportFromDocument } from '../src/agent-report.js'

const T0 = Date.parse('2026-08-17T00:00:00Z')
const event = (seq, type, data, time = T0 + seq * 1000) => ({ sessionId: 'session-report-1', event: { seq, type, data, time } })

function sampleEvents() {
  return [
    event(0, 'request/header', { header: { config: { provider: 'deepseek', model: 'deepseek-v4-flash' } } }),
    event(1, 'turn/start', { turn: 1 }),
    event(2, 'step/start', { turn: 1, step: 1 }),
    event(3, 'user/message', { content: [{ type: 'text', text: '请检查 token=super-secret-value-12345，但不要输出它' }] }),
    event(4, 'assistant/message', { usage: { inputTokens: 1000000, outputTokens: 500000, cacheReadTokens: 100000, reasoningTokens: 20000 } }),
    // Synthetic event payload only: the report parser receives this string as
    // data and must never execute it through a shell.
    event(5, 'tool/call', { name: 'bash', arguments: JSON.stringify({ command: 'rm -rf /' }) }),
    event(6, 'tool/call', { name: 'bash', arguments: JSON.stringify({ command: 'npm test' }) }),
    event(7, 'tool/call', { name: 'bash', arguments: JSON.stringify({ command: 'npm test' }) }),
    event(8, 'tool/call', { name: 'bash', arguments: JSON.stringify({ command: 'npm test' }) }),
    event(9, 'tool/result', { message: { isError: true, content: [{ type: 'error', text: 'private error should not be copied' }] } }),
    event(10, 'turn/end', { turn: 1, reason: { kind: 'error' } }),
  ]
}

function sourceFor(events = sampleEvents()) {
  return {
    kind: 'session-query',
    async listSessions() {
      return [{ header: { id: 'session-report-1', createdAt: T0 - 1000, delegationDepth: 0 }, live: false }]
    },
    async readSession() {
      return { session: { id: 'session-report-1', createdAt: T0 - 1000 }, events: events.map(item => ({ ...item.event })) }
    },
  }
}

test('agent report aggregates tokens, cost, tools, retries, failures, and risks without raw payloads', async () => {
  const result = await generateAgentReport({ source: sourceFor(), preset: '24h', now: T0 + 3600000 })
  assert.equal(result.status, 'PASS')
  assert.equal(result.sourceKind, 'session-query')
  assert.equal(result.summary.sessions, 1)
  assert.equal(result.summary.toolCallsTotal, 4)
  assert.equal(result.summary.toolErrors, 1)
  assert.equal(result.summary.turnFailures, 1)
  assert.equal(result.summary.retryBursts, 1)
  assert.equal(result.summary.dangerous.red, 1)
  assert.equal(result.summary.secrets.total, 1)
  assert.equal(result.cost.total > 0, true)
  assert.notEqual(result.summary.sessionsDetail[0].sessionId, 'session-report-1')
  assert.match(result.summary.sessionsDetail[0].sessionId, /^session-[0-9a-f]{16}$/)
  assert.equal(result.report.includes('session-report-1'), false)
  assert.equal(result.report.includes('super-secret-value-12345'), false)
  assert.equal(result.report.includes('private error should not be copied'), false)
  assert.equal(result.report.includes('rm -rf /'), false)
  assert.match(result.report, /文本线索，不代表 Debug 插件执行/)
  assert.match(result.report, /只读，不执行命令/)
})

test('agent report follows DSH token-meter replacement semantics for usage chunks', async () => {
  const result = await generateAgentReport({
    source: sourceFor([
      event(0, 'request/header', { header: { config: { provider: 'deepseek', model: 'deepseek-v4-flash' } } }),
      event(1, 'assistant/chunk', {
        turn: 1,
        step: 1,
        chunk: { type: 'usage', usage: { inputTokens: 11, outputTokens: 7, cacheReadTokens: 2, cacheWriteTokens: 3 } },
      }),
      // The finalized message replaces the early usage sample for turn 1/step 1.
      event(2, 'assistant/message', {
        turn: 1,
        step: 1,
        usage: { inputTokens: 13, outputTokens: 9, cacheReadTokens: 4, cacheWriteTokens: 5 },
      }),
      // A usage-only chunk is still reportable when a later request fails.
      event(3, 'assistant/chunk', {
        turn: 1,
        step: 2,
        chunk: { type: 'usage', usage: { inputTokens: 5, outputTokens: 2, cacheReadTokens: 1, cacheWriteTokens: 0 } },
      }),
    ]),
    preset: '24h',
    now: T0 + 3600000,
  })
  assert.equal(result.status, 'PASS')
  assert.deepEqual(result.summary.tokens, {
    input: 18,
    output: 11,
    cacheRead: 5,
    cacheWrite: 5,
    reasoning: 0,
  })
  assert.match(result.report, /缓存写入 5/)
})

test('agent report treats executable-looking command text as inert input', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'dsh-agent-report-'))
  const marker = join(directory, 'must-not-exist')
  const command = `node -e "require('node:fs').writeFileSync(${JSON.stringify(marker)}, 'executed')"`
  try {
    const result = await generateAgentReport({
      source: sourceFor([
        event(0, 'tool/call', { name: 'bash', arguments: JSON.stringify({ command }) }),
      ]),
      preset: '24h',
      now: T0 + 3600000,
    })
    await assert.rejects(access(marker))
    assert.equal(result.report.includes(marker), false)
    assert.match(result.report, /文本线索，不代表 Debug 插件执行/)
  } finally {
    await rm(directory, { recursive: true, force: true })
  }
})

test('agent report uses the live sessions fallback and reports no persistent history claim', async () => {
  const live = {
    header: { id: 'live-1', createdAt: T0 - 1000 },
    events: sampleEvents().map(item => ({ ...item.event })),
  }
  const result = await generateAgentReport({ source: createLiveSessionsReportSource({ list: () => [live] }), preset: '24h', now: T0 + 3600000 })
  assert.equal(result.status, 'PASS')
  assert.equal(result.sourceKind, 'live-sessions')
  assert.notEqual(result.summary.sessionsDetail[0].sessionId, 'live-1')
  assert.match(result.summary.sessionsDetail[0].sessionId, /^session-[0-9a-f]{16}$/)
  assert.match(result.report, /仅当前内存会话/)
})

test('agent report accepts only an explicit bounded redacted Session document', async () => {
  const document = {
    schemaVersion: 1,
    sessions: [{
      header: { id: 'offline-session', createdAt: T0 - 1000, seedLength: 0 },
      events: sampleEvents().map(item => ({ ...item.event })),
    }],
  }
  const result = await generateAgentReportFromDocument(document, { preset: '24h', now: T0 + 3600000 })
  assert.equal(result.status, 'PASS')
  assert.equal(result.sourceKind, 'redacted-document')
  assert.equal(result.summary.sessions, 1)
  assert.notEqual(result.summary.sessionsDetail[0].sessionId, 'offline-session')
  assert.match(result.report, /明确提供的脱敏 Session JSON/)
  assert.match(result.report, /只读，不执行命令/)
})

test('agent report rejects malformed or duplicate offline Session documents before reading events', () => {
  assert.throws(() => createAgentReportDocumentSource({ schemaVersion: 2, sessions: [] }), /schemaVersion/)
  assert.throws(() => createAgentReportDocumentSource({
    schemaVersion: 1,
    sessions: [
      { header: { id: 'duplicate', createdAt: T0 }, events: [] },
      { header: { id: 'duplicate', createdAt: T0 }, events: [] },
    ],
}), /重复/)
})

test('agent report stops after the bounded total event budget', async () => {
  const events = Array.from({ length: 120000 }, (_, index) => ({
    seq: index,
    time: T0 + 1000,
    type: 'assistant/chunk',
    data: {},
  }))
  const result = await generateAgentReport({
    source: {
      kind: 'session-query',
      async listSessions() {
        return Array.from({ length: 12 }, (_, index) => ({ header: { id: `bounded-${index}`, createdAt: T0 } }))
      },
      async readSession(id) {
        return { session: { id, createdAt: T0 }, events }
      },
    },
    preset: '24h',
    now: T0 + 3600000,
  })
  assert.equal(result.status, 'PARTIAL')
  assert.equal(result.coverage.eventsRead <= 1000000, true)
  assert.equal(result.coverage.truncated, true)
})

test('offline report CLI input boundary rejects symlinks', async (t) => {
  const directory = await mkdtemp(join(tmpdir(), 'dsh-agent-report-link-'))
  const target = join(directory, 'document.json')
  const link = join(directory, 'alias.json')
  try {
    await writeFile(target, JSON.stringify({ schemaVersion: 1, sessions: [] }), 'utf8')
    try {
      await symlink(target, link, 'file')
    } catch {
      t.skip('file symlinks are unavailable in this environment')
      return
    }
    const script = fileURLToPath(new URL('../tools/Generate-DSHAgentReport.mjs', import.meta.url))
    const result = spawnSync(process.execPath, [script, '--input', link], { encoding: 'utf8' })
    assert.equal(result.status, 1)
    assert.match(result.stderr, /符号链接/)
  } finally {
    await rm(directory, { recursive: true, force: true })
  }
})

test('aggregate ignores inherited seed events and excludes debug-owned events', () => {
  const collected = {
    headers: [{ id: 's', createdAt: T0, seedLength: 1 }],
    events: [
      { sessionId: 's', event: { seq: 0, type: 'tool/call', time: T0, data: { name: 'read', arguments: '{}' } } },
      { sessionId: 's', event: { seq: 1, type: 'dsh-plugin-debug/report', time: T0, data: {} } },
      { sessionId: 's', event: { seq: 2, type: 'turn/start', time: T0 + 1000, data: {} } },
    ],
  }
  const summary = aggregateAgentReportEvents(collected, { from: T0, to: T0 + 10000 })
  assert.equal(summary.totalEvents, 1)
  assert.equal(summary.toolCallsTotal, 0)
  assert.equal(summary.turns, 1)
})

test('unavailable source is explicit and does not pretend that fixtures are runtime proof', async () => {
  const result = await generateAgentReport({ source: null, preset: 'weekly', now: T0 + 3600000 })
  assert.equal(result.status, 'UNAVAILABLE')
  assert.match(result.report, /没有可读取的 Session 服务/)
})

test('agent report bounds hostile presentation labels without copying raw metadata', async () => {
  const hostile = sourceFor([
    event(0, 'request/header', { header: { config: { provider: 'evil|provider\n`raw`', model: 'model|with\u0007control' } } }),
    event(1, 'tool/call', { name: 'tool|`raw`\nname', arguments: { command: 'echo ok' } }),
    event(2, 'assistant/message', { usage: { inputTokens: 1, outputTokens: 1 } }),
  ])
  const result = await generateAgentReport({ source: hostile, preset: '24h', now: T0 + 3600000 })
  assert.equal(result.status, 'PASS')
  assert.equal(result.report.includes('evil|provider'), false)
  assert.equal(result.report.includes('tool|`raw`'), false)
  assert.equal(result.report.includes('\u0007'), false)
  assert.match(result.report, /evil provider raw/)
})
