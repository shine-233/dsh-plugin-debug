export function registerPluginCheckTool(ctx, { defineTool, checker }) {
  const definition = defineTool({
    name: 'plugin_check',
    description: 'Run read-only diagnostics for a DSH plugin repository. Actions: check, scan, schema.',
    parameters: {
      action: {
        type: 'string',
        required: true,
        enum: ['check', 'scan', 'schema'],
        description: 'check one repository, scan a parent directory, or return the check schema',
      },
      path: {
        type: 'string',
        description: 'absolute repository or parent directory; defaults to the current working directory',
      },
      strict: {
        type: 'boolean',
        description: 'promote warnings to errors in the verdict',
      },
    },
    output: {
      schema: { type: 'string' },
      render: (_args, value) => [{ type: 'text', text: value }],
    },
    async execute(args) {
      const path = typeof args?.path === 'string' && args.path !== '' ? args.path : process.cwd()
      const strict = args?.strict === true
      if (args?.action === 'check') return JSON.stringify(await checker.check(path, { strict }))
      if (args?.action === 'scan') return JSON.stringify(await checker.scan(path, { strict }))
      if (args?.action === 'schema') return JSON.stringify(await checker.schema())
      throw new Error(`plugin_check: unknown action ${String(args?.action)}`)
    },
    timeoutMs: 5000,
  })
  return ctx.tools.register(definition)
}
