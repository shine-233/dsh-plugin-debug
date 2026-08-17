import { readdir } from 'node:fs/promises'
import { spawnSync } from 'node:child_process'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = resolve(fileURLToPath(new URL('..', import.meta.url)))
const scanRoots = ['src', 'lib', 'scripts', 'tests']
const extensions = new Set(['.js', '.mjs', '.cjs'])

async function collect(directory) {
  const files = []
  let entries
  try { entries = await readdir(directory, { withFileTypes: true }) } catch { return files }
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
for (const file of files) {
  const result = spawnSync(process.execPath, ['--check', file], { stdio: 'inherit' })
  if (result.status !== 0) throw new Error(`syntax check failed: ${file}`)
}
console.log(`JavaScript syntax verified: ${files.length} files`)
