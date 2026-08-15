import assert from 'node:assert/strict'
import test from 'node:test'
import { registerPluginCheckTool } from '../src/tool-adapter.js'

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
