import { readdir, readFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = resolve(fileURLToPath(new URL('..', import.meta.url)))
const scanRoots = ['src', 'lib', 'scripts', 'tests', 'tools']
const textExtensions = new Set([
  '.cjs', '.cmd', '.json', '.js', '.mjs', '.md', '.ps1', '.psm1', '.py',
  '.vbs', '.yml', '.yaml', '.yml.example', '.yml.example', '.patch', '.txt',
])
const rootFiles = [
  'package.json',
  'package-lock.json',
  'bundle-manifest.json',
  'cordis.patch.yml',
  'tool-policy.patch.example.yml',
  'README.md',
  'README.zh-CN.md',
  'RESEARCH.md',
  'DEBUG-QUICKSTART.md',
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
    else {
      const extension = entry.name.slice(entry.name.lastIndexOf('.')).toLowerCase()
      if (textExtensions.has(extension) || entry.name.endsWith('.yml.example')) files.push(full)
    }
  }
  return files
}

const files = []
for (const relative of scanRoots) files.push(...await collect(resolve(root, relative)))
for (const relative of rootFiles) files.push(resolve(root, relative))
const uniqueFiles = [...new Set(files)].filter(file => {
  const extension = file.slice(file.lastIndexOf('.')).toLowerCase()
  return textExtensions.has(extension) || file.endsWith('.yml.example')
}).sort()

const failures = []
const trailingWhitespace = /[ \t]+(?:\r?\n|$)/u
const forbiddenControl = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/u
for (const file of uniqueFiles) {
  let bytes
  try { bytes = await readFile(file) } catch { continue }
  if (bytes.length === 0) continue
  const source = bytes.toString('utf8')
  const relative = file.slice(root.length + 1).replaceAll('\\', '/')
  const lines = source.split(/\n/u)
  if (!bytes.subarray(-1).equals(Buffer.from('\n'))) failures.push(`${relative}: missing final newline`)
  if (lines.some(line => trailingWhitespace.test(line))) failures.push(`${relative}: trailing whitespace`)
  if (forbiddenControl.test(source)) failures.push(`${relative}: forbidden control character`)
}

if (failures.length > 0) {
  for (const failure of failures) console.error(failure)
  process.exitCode = 1
} else {
  console.log(`format check passed: ${uniqueFiles.length} text files; EOF/trailing-whitespace/control policy clean`)
}
