import assert from 'node:assert/strict'
import test from 'node:test'
import { registerAgentReportTool, registerPluginCheckTool, registerPluginHotswapCheckTool, registerPluginHotswapPreflightTool } from '../src/tool-adapter.js'

test('registerPluginCheckTool registers one plugin_check definition through ctx.tools', () => {
  const registrations = []
  const dispose = () => {}
  const ctx = {
    tools: {
      register(definition) {
        registrations.push(definition)
        return dispose
      },
    },
  }
  const defineTool = options => ({ ...options, defined: true })
  const checker = {
    check() {},
    scan() {},
    schema() {},
  }

  const result = registerPluginCheckTool(ctx, { defineTool, checker })

  assert.equal(result, dispose)
  assert.equal(registrations.length, 1)
  assert.equal(registrations[0].name, 'plugin_check')
  assert.equal(registrations[0].defined, true)
  assert.deepEqual(registrations[0].parameters.action.enum, ['check', 'scan', 'schema'])
})

test('plugin_check executes the selected read-only checker action', async () => {
  const registrations = []
  const ctx = { tools: { register(definition) { registrations.push(definition); return () => {} } } }
  const defineTool = options => options
  const checker = {
    check: async (path, options) => ({ action: 'check', path, options }),
    scan: async (path, options) => ({ action: 'scan', path, options }),
    schema: async () => [{ code: 'fixture' }],
  }

  registerPluginCheckTool(ctx, { defineTool, checker })
  assert.deepEqual(JSON.parse(await registrations[0].execute({ action: 'check', path: 'C:/repo', strict: true })), {
    action: 'check',
    path: 'C:/repo',
    options: { strict: true },
  })
  assert.deepEqual(JSON.parse(await registrations[0].execute({ action: 'schema' })), [{ code: 'fixture' }])
})

test('registerPluginHotswapCheckTool exposes a report-only target selector', async () => {
  const registrations = []
  const ctx = { tools: { register(definition) { registrations.push(definition); return () => {} } } }
  const defineTool = options => options
  const probeCalls = []

  registerPluginHotswapCheckTool(ctx, {
    defineTool,
    probe: async input => {
      probeCalls.push(input)
      return { verdict: 'UNAVAILABLE', execution: 'NOT_ATTEMPTED', targetMutated: false }
    },
  })

  assert.equal(registrations.length, 1)
  assert.equal(registrations[0].name, 'plugin_hotswap_check')
  assert.equal(registrations[0].parameters.pluginId.type, 'string')
  const value = JSON.parse(await registrations[0].execute({ pluginId: 'dsh-example' }))
  assert.equal(value.execution, 'NOT_ATTEMPTED')
  assert.deepEqual(probeCalls, [{ pluginId: 'dsh-example' }])
  assert.equal(registrations[0].parameters.action, undefined)
})

test('registerPluginHotswapPreflightTool exposes a bounded offline repository check', async () => {
  const registrations = []
  const ctx = { tools: { register(definition) { registrations.push(definition); return () => {} } } }
  const preflightCalls = []

  registerPluginHotswapPreflightTool(ctx, {
    defineTool: options => options,
    preflight: async (path, options) => {
      preflightCalls.push({ path, options })
      return { verdict: 'PARTIAL', execution: 'NOT_ATTEMPTED', commandsExecuted: false }
    },
  })

  assert.equal(registrations.length, 1)
  assert.equal(registrations[0].name, 'plugin_hotswap_preflight')
  const value = JSON.parse(await registrations[0].execute({ path: 'C:/candidate', strict: true }))
  assert.equal(value.execution, 'NOT_ATTEMPTED')
  assert.deepEqual(preflightCalls, [{ path: 'C:/candidate', options: { strict: true } }])
})

test('dsh_agent_report renders a deterministic report from the currently available source', async () => {
  const registrations = []
  const ctx = { tools: { register(definition) { registrations.push(definition); return () => {} } } }
  registerAgentReportTool(ctx, {
    defineTool: options => options,
    getSource: () => ({ kind: 'live-sessions' }),
    generate: async input => ({ report: `status=${input.source.kind}; preset=${input.preset}` }),
  })
  assert.equal(registrations.length, 1)
  assert.equal(registrations[0].name, 'dsh_agent_report')
  assert.deepEqual(await registrations[0].execute({ preset: '24h' }), 'status=live-sessions; preset=24h')
})
