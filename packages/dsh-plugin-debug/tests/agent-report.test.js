import assert from 'node:assert/strict'
import { access, mkdtemp, rm } from 'node:fs/promises'
import test from 'node:test'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { aggregateAgentReportEvents, generateAgentReport, createLiveSessionsReportSource } from '../src/agent-report.js'

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
