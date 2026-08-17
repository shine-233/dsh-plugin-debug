import { preflightHotswapSource } from '../lib/hotswap-preflight.js'

function parseArguments(argv) {
  const result = {}
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index]
    if (token === '--strict') {
      result.strict = true
      continue
    }
    if (!token.startsWith('--')) throw new Error('hotswap 预检参数格式无效')
    const name = token.slice(2)
    const value = argv[index + 1]
    if (!value || value.startsWith('--')) throw new Error(`hotswap 预检参数缺少值：${name}`)
    result[name] = value
    index += 1
  }
  return result
}

async function main() {
  const args = parseArguments(process.argv.slice(2))
  const path = args.path ?? process.cwd()
  const report = await preflightHotswapSource(path, { strict: args.strict === true })
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`)
  process.exitCode = report.verdict === 'PASS' ? 0 : 2
}

try {
  await main()
} catch (error) {
  process.stderr.write(`DSH hotswap 源码预检未生成：${error instanceof Error ? error.message : '输入无效'}\n`)
  process.exitCode = 1
}
