import assert from 'node:assert/strict'
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { checkWorkflowActionPins } from '../scripts/check-workflow-action-pins.mjs'

test('workflow action pin checker accepts full commit SHAs and ignores local actions', async () => {
  const root = await mkdtemp(join(tmpdir(), 'dsh-workflow-pins-'))
  try {
    const workflowRoot = join(root, '.github', 'workflows')
    await mkdir(workflowRoot, { recursive: true })
    await writeFile(join(workflowRoot, 'ci.yml'), [
      'name: CI',
      'jobs:',
      '  test:',
      '    steps:',
      '      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7',
      '      - uses: ./.github/actions/local',
      '      - uses: org/example@0123456789abcdef0123456789abcdef01234567',
    ].join('\n'))
    const result = await checkWorkflowActionPins(root)
    assert.deepEqual(result.workflows, ['ci.yml'])
    assert.equal(result.checkedUses, 3)
    assert.deepEqual(result.findings, [])
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('workflow action pin checker reports mutable refs with file and line evidence', async () => {
  const root = await mkdtemp(join(tmpdir(), 'dsh-workflow-pins-'))
  try {
    const workflowRoot = join(root, '.github', 'workflows')
    await mkdir(workflowRoot, { recursive: true })
    await writeFile(join(workflowRoot, 'ci.yaml'), 'jobs:\n  test:\n    steps:\n      - uses: actions/checkout@v7\n')
    const result = await checkWorkflowActionPins(root)
    assert.equal(result.checkedUses, 1)
    assert.equal(result.findings.length, 1)
    assert.equal(result.findings[0].file, '.github/workflows/ci.yaml')
    assert.equal(result.findings[0].line, 4)
    assert.equal(result.findings[0].value, 'actions/checkout@v7')
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})
