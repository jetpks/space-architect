import { describe, expect, it } from 'vitest'
import {
  applyPatchFiles,
  gist,
  isEncryptedThinking,
  messageMarker,
  parseAskUserAnswers,
  parseToolAnswers,
  toolLabel,
} from '@/lib/tools'
import type { Block, Message, ToolUseBlock } from '@/types'

function message(blocks: Block[], role = 'assistant'): Message {
  return { id: 1, role, model: null, position: 0, published: false, blocks, can_publish: false }
}

describe('parseAskUserAnswers', () => {
  it('maps each question to its answer (option label or free text)', () => {
    const result =
      'Your questions have been answered: ' +
      '"Should I install make 4.x and ccache first?"="done -- i installed these just now", ' +
      '"Which build flavor do you want for learning the internals?"="Debug build (Recommended)". ' +
      'You can now continue with these answers in mind.'

    expect(parseAskUserAnswers(result)).toEqual({
      'Should I install make 4.x and ccache first?': 'done -- i installed these just now',
      'Which build flavor do you want for learning the internals?': 'Debug build (Recommended)',
    })
  })

  it('handles a single question', () => {
    expect(parseAskUserAnswers('Your questions have been answered: "Pick one"="A".')).toEqual({
      'Pick one': 'A',
    })
  })

  it('yields {} for an unrecognized result', () => {
    expect(parseAskUserAnswers('no quoted pairs here')).toEqual({})
  })
})

describe('parseToolAnswers', () => {
  const questions = [
    { id: 'argo_scope', question: 'Which fix do you want?' },
    { id: 'metric_api', question: 'Which metric API?' },
  ]

  it('maps codex JSON answers from question ids back to question text', () => {
    const result =
      '{"answers":{"argo_scope":{"answers":["Exclude Google (Recommended)"]},"metric_api":{"answers":["Add new metric"]}}}'

    expect(parseToolAnswers(result, questions)).toEqual({
      'Which fix do you want?': 'Exclude Google (Recommended)',
      'Which metric API?': 'Add new metric',
    })
  })

  it('joins multi-select answers', () => {
    const result = '{"answers":{"argo_scope":{"answers":["A","B"]}}}'
    expect(parseToolAnswers(result, questions)).toEqual({ 'Which fix do you want?': 'A, B' })
  })

  it('falls back to the Claude flat-sentence shape for non-JSON results', () => {
    const result = 'Your questions have been answered: "Pick one"="A".'
    expect(parseToolAnswers(result, questions)).toEqual({ 'Pick one': 'A' })
  })
})

describe('applyPatchFiles', () => {
  it('extracts every touched path from the patch envelope', () => {
    const patch =
      '*** Begin Patch\n*** Update File: /tmp/a.rb\n@@\n-x\n+y\n*** Add File: /tmp/b.rb\n+hi\n*** Delete File: /tmp/c.rb\n*** End Patch'

    expect(applyPatchFiles(patch)).toEqual(['/tmp/a.rb', '/tmp/b.rb', '/tmp/c.rb'])
  })

  it('returns [] when nothing matches', () => {
    expect(applyPatchFiles('not a patch')).toEqual([])
  })
})

describe('codex tool affordances', () => {
  it('marks an exec_command git commit as a commit beat', () => {
    const m = message([
      { type: 'tool_use', name: 'exec_command', input: { cmd: 'git commit -m "ship it"' } },
    ])
    expect(messageMarker(m)).toBe('commit')
  })

  it('marks request_user_input as a decision beat', () => {
    const m = message([{ type: 'tool_use', name: 'request_user_input', input: { questions: [] } }])
    expect(messageMarker(m)).toBe('decision')
  })

  it('labels exec_command gist rows with the command', () => {
    const block = {
      type: 'tool_use',
      name: 'exec_command',
      input: { cmd: 'ls -la' },
    } as ToolUseBlock
    expect(toolLabel(block)).toBe('→ exec_command ls -la')
  })

  it('labels apply_patch gist rows with the touched file', () => {
    const block = {
      type: 'tool_use',
      name: 'apply_patch',
      input: { patch: '*** Begin Patch\n*** Update File: /tmp/a.rb\n@@\n-x\n+y\n*** End Patch' },
    } as ToolUseBlock
    expect(toolLabel(block)).toBe('→ apply_patch /tmp/a.rb')
  })

  it('reduces a turn_aborted envelope to an interrupt note in gists', () => {
    const m = message(
      [
        {
          type: 'text',
          text: '<turn_aborted>\nThe user interrupted the previous turn on purpose.\n</turn_aborted>',
        },
      ],
      'user',
    )
    expect(gist(m)).toBe('interrupted')
  })
})

describe('gist: skill envelope', () => {
  const SKILL_MARKDOWN =
    '<skill name="architect" location="/Users/eric/.agents/skills/architect/SKILL.md">\n' +
    'References are relative to /Users/eric/.agents/skills/architect.\n\n' +
    '# Architect\n…the whole skill markdown…\n</skill>'

  it('collapses the envelope to a skill-name marker followed by the trailing user input', () => {
    const m = message([{ type: 'text', text: `${SKILL_MARKDOWN}\n\nplease fix the flaky test` }], 'user')
    expect(gist(m)).toBe('✦ architect please fix the flaky test')
  })

  it('yields a non-empty gist naming the skill for a promptless kickstart', () => {
    const m = message([{ type: 'text', text: SKILL_MARKDOWN }], 'user')
    const result = gist(m)
    expect(result).not.toBe('')
    expect(result).toContain('architect')
  })

  it('contains no raw <skill tag text', () => {
    const m = message([{ type: 'text', text: `${SKILL_MARKDOWN}\n\ndo the thing` }], 'user')
    expect(gist(m)).not.toContain('<skill')
    expect(gist(m)).not.toContain('</skill>')
  })
})

describe('isEncryptedThinking', () => {
  it('hides redacted_thinking (encrypted chain-of-thought)', () => {
    expect(isEncryptedThinking(message([{ type: 'redacted_thinking', data: 'gAAAAA==' }]))).toBe(
      true,
    )
  })

  it('hides empty thinking blocks (interleaved-thinking noise)', () => {
    expect(isEncryptedThinking(message([{ type: 'thinking', thinking: '' }]))).toBe(true)
  })

  it('keeps readable thinking visible', () => {
    expect(isEncryptedThinking(message([{ type: 'thinking', thinking: 'hmm' }]))).toBe(false)
  })
})
