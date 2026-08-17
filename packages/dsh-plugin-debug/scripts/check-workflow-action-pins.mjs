import { readdir, readFile } from 'node:fs/promises'
import { basename, dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const SCRIPT_DIRECTORY = dirname(fileURLToPath(import.meta.url))
// This package lives at packages/dsh-plugin-debug, while workflows live at
// the repository root. Keep the default explicit so `npm run check:*` works
// both from this package and from a fresh source checkout.
const DEFAULT_REPOSITORY_ROOT = resolve(SCRIPT_DIRECTORY, '..', '..', '..')

function findUses(lines, relativePath) {
  const findings = []
  for (let index = 0; index < lines.length; index += 1) {
    const match = lines[index].match(/^\s*(?:-\s*)?uses:\s*([^\s#]+)/u)
    if (!match) continue
    const value = match[1]
    if (value.startsWith('./')) continue
    const at = value.lastIndexOf('@')
    const ref = at > 0 ? value.slice(at + 1) : ''
    if (!/^[0-9a-f]{40}$/iu.test(ref)) {
      findings.push({
        file: relativePath,
        line: index + 1,
        value,
        reason: 'external GitHub Actions must use a full 40-character commit SHA',
      })
    }
  }
  return findings
}

export async function checkWorkflowActionPins(repositoryRoot = DEFAULT_REPOSITORY_ROOT) {
  const workflowRoot = resolve(repositoryRoot, '.github', 'workflows')
  let entries
  try {
    entries = await readdir(workflowRoot, { withFileTypes: true })
  } catch (error) {
    throw new Error(`cannot read workflow directory: ${error instanceof Error ? error.message : 'unknown error'}`)
  }
  const workflows = entries
    .filter(entry => entry.isFile() && /\.ya?ml$/iu.test(entry.name))
    .map(entry => entry.name)
    .sort()
  const findings = []
  let checkedUses = 0
  for (const name of workflows) {
    const absolute = resolve(workflowRoot, name)
    const contents = await readFile(absolute, 'utf8')
    const lines = contents.split(/\r?\n/u)
    const fileFindings = findUses(lines, `.github/workflows/${name}`)
    checkedUses += lines.filter(line => /^\s*(?:-\s*)?uses:\s*\S+/u.test(line)).length
    findings.push(...fileFindings)
  }
  return { workflows, checkedUses, findings }
}

async function main() {
  const result = await checkWorkflowActionPins()
  if (result.findings.length > 0) {
    for (const finding of result.findings) {
      process.stderr.write(`${finding.file}:${finding.line}: ${finding.value} — ${finding.reason}\n`)
    }
    process.exitCode = 1
    return
  }
  process.stdout.write(`workflow action pin check passed: ${result.checkedUses} external uses across ${result.workflows.length} workflows\n`)
}

if (process.argv[1] && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url))) {
  try {
    await main()
  } catch (error) {
    process.stderr.write(`workflow action pin check failed: ${error instanceof Error ? error.message : 'unknown error'}\n`)
    process.exitCode = 1
  }
}
