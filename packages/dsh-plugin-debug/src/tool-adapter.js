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

export function registerPluginHotswapCheckTool(ctx, { defineTool, probe }) {
  const definition = defineTool({
    name: 'plugin_hotswap_check',
    description: 'Read-only report of whether the current DSH Host declares a safe plugin lifecycle contract. It never reloads, disables, installs, or rewrites a plugin.',
    parameters: {
      pluginId: {
        type: 'string',
        description: 'optional exact plugin id or module name to assess; omit to report Host-wide capability only',
      },
    },
    output: {
      schema: { type: 'string' },
      render: (_args, value) => [{ type: 'text', text: value }],
    },
    async execute(args) {
      const pluginId = typeof args?.pluginId === 'string' && args.pluginId.trim() !== '' ? args.pluginId : undefined
      return JSON.stringify(await probe({ pluginId }))
    },
    timeoutMs: 5000,
  })
  return ctx.tools.register(definition)
}

export function registerPluginHotswapPreflightTool(ctx, { defineTool, preflight }) {
  const definition = defineTool({
    name: 'plugin_hotswap_preflight',
    description: 'Run a bounded offline static preflight over a hotswap candidate repository. It never imports, installs, executes, reloads, or rewrites the candidate.',
    parameters: {
      path: {
        type: 'string',
        description: 'absolute candidate repository path; defaults to the current working directory',
      },
      strict: {
        type: 'boolean',
        description: 'promote static warnings to manual review',
      },
    },
    output: {
      schema: { type: 'string' },
      render: (_args, value) => [{ type: 'text', text: value }],
    },
    async execute(args) {
      const path = typeof args?.path === 'string' && args.path !== '' ? args.path : process.cwd()
      return JSON.stringify(await preflight(path, { strict: args?.strict === true }))
    },
    timeoutMs: 10000,
  })
  return ctx.tools.register(definition)
}

export function registerAgentReportTool(ctx, { defineTool, getSource, generate }) {
  const definition = defineTool({
    name: 'dsh_agent_report',
    description: 'Generate a read-only deterministic report of DSH sessions, tokens, estimated cost, tool calls, risks, and anomalies. It never executes commands, reads credentials, calls a model, or writes session history.',
    parameters: {
      preset: {
        type: 'string',
        enum: ['daily', '24h', 'weekly', 'monthly', 'yearly', 'custom'],
        description: 'report range; defaults to weekly',
      },
      from: {
        type: 'string',
        description: 'ISO start time, required for custom',
      },
      to: {
        type: 'string',
        description: 'ISO end time, required for custom',
      },
    },
    output: {
      schema: { type: 'string' },
      render: (_args, value) => [{ type: 'text', text: value }],
    },
    async execute(args) {
      const result = await generate({
        source: getSource(),
        preset: typeof args?.preset === 'string' ? args.preset : 'weekly',
        from: typeof args?.from === 'string' ? args.from : undefined,
        to: typeof args?.to === 'string' ? args.to : undefined,
      })
      return result.report
    },
    timeoutMs: 15000,
  })
  return ctx.tools.register(definition)
}
