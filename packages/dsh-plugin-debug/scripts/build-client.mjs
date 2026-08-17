import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

export function renderClient(source) {
  const indented = source.split('\n').map(line => {
    const trimmed = line.trimEnd()
    return trimmed ? `    ${trimmed}` : ''
  }).join('\n')
  return `window.__ModuleLoader__.load({
  id: 'dsh-plugin-debug',
  factory: (require) => {
    var module = { exports: {} };
    var exports = module.exports;
${indented}
    return module.exports;
  }
});
`
}

export async function buildClient() {
  const root = resolve(fileURLToPath(new URL('..', import.meta.url)))
  const source = await readFile(resolve(root, 'src', 'client-factory.cjs'), 'utf8')
  const output = renderClient(source)
  await mkdir(resolve(root, 'lib'), { recursive: true })
  await writeFile(resolve(root, 'lib', 'client.js'), output, 'utf8')
}

if (process.argv[1] === fileURLToPath(import.meta.url)) await buildClient()
