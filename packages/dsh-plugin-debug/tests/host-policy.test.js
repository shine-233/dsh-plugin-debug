import assert from 'node:assert/strict'
import test from 'node:test'
import { apply, decideToolCall, normalizeToolPolicyConfig } from '../src/index.js'

test('host policy is a no-op unless explicitly enabled', () => {
  const decision = decideToolCall({}, {
    name: 'bash',
    arguments: { sandbox_permissions: 'danger-full-access' },
  })
  assert.deepEqual(decision.kind, 'allow')
  assert.match(decision.reason, /disabled/u)
})

test('enabled policy asks before a dangerous full-access shell call', () => {
  const exec = {
    name: 'bash',
    arguments: { sandbox_permissions: 'danger-full-access', command: 'ignored' },
  }
  const before = JSON.stringify(exec)
  const decision = decideToolCall({ toolPolicy: { enabled: true } }, exec)
  assert.equal(decision.kind, 'ask')
  assert.match(decision.reason, /explicit approval/u)
  assert.equal(JSON.stringify(exec), before)
})

test('ordered rules and JSON-pointer predicates are evaluated without rewriting arguments', () => {
  const config = {
    toolPolicy: {
      enabled: true,
      defaultDecision: 'deny',
      rules: [
        { tool: 'read_*', decision: 'allow' },
        { tool: 'mcp_*', when: { pointer: '/server', equals: 'external' }, decision: 'ask', reason: 'external MCP approval' },
      ],
    },
  }
  assert.equal(decideToolCall(config, { name: 'read_file', arguments: {} }).kind, 'allow')
  const mcp = { name: 'mcp_fetch', arguments: { server: 'external', url: 'https://example.invalid' } }
  const decision = decideToolCall(config, mcp)
  assert.equal(decision.kind, 'ask')
  assert.equal(decision.reason, 'external MCP approval')
  assert.equal(decideToolCall(config, { name: 'unknown', arguments: {} }).kind, 'deny')
})

test('dangerous shell protection is monotonic over an allow rule', () => {
  const decision = decideToolCall({
    toolPolicy: {
      enabled: true,
      rules: [{ tool: 'bash', decision: 'allow' }],
      protectDangerousShell: true,
    },
  }, { name: 'bash', arguments: { sandboxPermissions: 'danger-full-access' } })
  assert.equal(decision.kind, 'ask')
})

test('apply registers only the opt-in pre-execute hook', () => {
  const registrations = []
  const ctx = { on: (...args) => registrations.push(args) }
  apply({}, {})
  assert.equal(registrations.length, 0)
  apply(ctx, { guardian: { enabled: false }, toolPolicy: { enabled: true, defaultDecision: 'ask' } })
  assert.equal(registrations.length, 1)
  assert.equal(registrations[0][0], 'tools/pre-execute')
  assert.equal(registrations[0][2].prepend, true)
  assert.equal(normalizeToolPolicyConfig({}).enabled, false)
})
