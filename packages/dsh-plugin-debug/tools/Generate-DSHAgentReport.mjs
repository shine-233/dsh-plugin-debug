import { lstat, readFile } from 'node:fs/promises'
import { basename } from 'node:path'
import { generateAgentReportFromDocument } from '../lib/agent-report.js'

const MAX_INPUT_BYTES = 16 * 1024 * 1024

function parseArguments(argv) {
  const result = {}
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index]
    if (!token.startsWith('--')) throw new Error('报告参数格式无效')
    const name = token.slice(2)
    const value = argv[index + 1]
    if (!value || value.startsWith('--')) throw new Error(`报告参数缺少值：${name}`)
    result[name] = value
    index += 1
  }
  return result
}

function rejectSensitiveFileName(path) {
  const name = basename(path).toLowerCase()
  if (
    name === '.env' ||
    name.startsWith('.env.') ||
    name.includes('credential') ||
    name.includes('secret') ||
    name.endsWith('.pem') ||
    name.endsWith('.key') ||
    name.endsWith('.p12') ||
    name.endsWith('.pfx')
  ) throw new Error('为避免误读凭据，Agent 报告拒绝读取 .env、credentials、secret、key 或证书文件')
}

async function main() {
  const args = parseArguments(process.argv.slice(2))
  if (!args.input) throw new Error('必须提供 --input <脱敏 Session JSON>')
  rejectSensitiveFileName(args.input)
  const info = await lstat(args.input)
  if (info.isSymbolicLink()) throw new Error('为避免越过文件边界，Agent 报告拒绝读取符号链接输入')
  if (!info.isFile()) throw new Error('Agent 报告输入必须是一个 JSON 文件')
  if (info.size > MAX_INPUT_BYTES) throw new Error(`Agent 报告输入不能超过 ${MAX_INPUT_BYTES} 字节`)
  const raw = await readFile(args.input, 'utf8')
  let document
  try {
    document = JSON.parse(raw)
  } catch {
    throw new Error('Agent 报告输入不是合法 JSON')
  }
  const result = await generateAgentReportFromDocument(document, {
    preset: args.preset ?? 'weekly',
    from: args.from,
    to: args.to,
  })
  process.stdout.write(`${result.report}\n`)
  process.exitCode = result.status === 'PASS' ? 0 : 2
}

try {
  await main()
} catch (error) {
  const code = error && typeof error === 'object' ? error.code : undefined
  const message = code === 'ENOENT'
    ? '输入文件不存在'
    : code === 'EACCES' || code === 'EPERM'
      ? '无法读取输入文件；请检查文件权限'
      : error instanceof Error
        ? error.message
        : '输入无效'
  process.stderr.write(`DSH Agent 报告未生成：${message}\n`)
  process.exitCode = 1
}
