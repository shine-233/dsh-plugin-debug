import { readdir, readFile } from 'node:fs/promises'
import { spawnSync } from 'node:child_process'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

// This package is intentionally dependency-light and is written in JavaScript
// plus PowerShell.  Until the project adopts ESLint, keep a small deterministic
// policy lint here rather than pretending that a formatter or linter ran.
const root = resolve(fileURLToPath(new URL('..', import.meta.url)))
const scanRoots = ['src', 'lib', 'scripts', 'tests']
const extensions = new Set(['.js', '.mjs', '.cjs'])
const forbiddenPatterns = [
  { pattern: /\beval\s*\(/u, label: 'eval()' },
  { pattern: /\bnew\s+Function\s*\(/u, label: 'new Function()' },
]

async function collect(directory) {
  const files = []
  let entries
  try {
    entries = await readdir(directory, { withFileTypes: true })
  } catch {
    return files
  }
  for (const entry of entries) {
    if (entry.name === 'node_modules' || entry.name.startsWith('.')) continue
    const full = resolve(directory, entry.name)
    if (entry.isDirectory()) files.push(...await collect(full))
    else if (extensions.has(entry.name.slice(entry.name.lastIndexOf('.')))) files.push(full)
  }
  return files
}

const files = []
for (const relative of scanRoots) files.push(...await collect(resolve(root, relative)))
files.sort()

const failures = []
for (const file of files) {
  const source = await readFile(file, 'utf8')
  const relative = file.slice(root.length + 1).replaceAll('\\', '/')
  if (relative !== 'scripts/check-quality.mjs') {
    for (const { pattern, label } of forbiddenPatterns) {
      if (pattern.test(source)) failures.push(`${relative}: prohibited ${label}`)
    }
  }
  const result = spawnSync(process.execPath, ['--check', file], { encoding: 'utf8' })
  if (result.status !== 0) failures.push(`${relative}: node --check failed`)
}

if (failures.length > 0) {
  for (const failure of failures) console.error(failure)
  process.exitCode = 1
} else {
  console.log(`policy lint passed: ${files.length} JavaScript files; no dynamic code evaluation`)
}
