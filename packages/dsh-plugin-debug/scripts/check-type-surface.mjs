import { readdir } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = resolve(fileURLToPath(new URL('..', import.meta.url)))
const scanRoots = ['src', 'lib', 'scripts', 'tests']
const typeExtensions = new Set(['.ts', '.tsx', '.mts', '.cts'])

async function collect(directory) {
  const files = []
  let entries
  try { entries = await readdir(directory, { withFileTypes: true }) } catch { return files }
  for (const entry of entries) {
    if (entry.name === 'node_modules' || entry.name.startsWith('.')) continue
    const full = resolve(directory, entry.name)
    if (entry.isDirectory()) files.push(...await collect(full))
    else if (typeExtensions.has(entry.name.slice(entry.name.lastIndexOf('.')))) files.push(full)
  }
  return files
}

const files = []
for (const relative of scanRoots) files.push(...await collect(resolve(root, relative)))
if (files.length === 0) {
  console.log('typecheck: SKIPPED (no TypeScript sources; package is JavaScript/PowerShell)')
  process.exit(0)
}

const config = resolve(root, 'tsconfig.json')
const tsc = resolve(root, 'node_modules', '.bin', process.platform === 'win32' ? 'tsc.cmd' : 'tsc')
if (!existsSync(config)) throw new Error('TypeScript sources exist but tsconfig.json is missing')
if (!existsSync(tsc)) throw new Error('TypeScript sources exist but local TypeScript is not installed')
const result = spawnSync(tsc, ['--noEmit', '--pretty', 'false'], { cwd: root, stdio: 'inherit' })
if (result.status !== 0) process.exit(result.status ?? 1)
console.log(`typecheck passed: ${files.length} TypeScript files`)
