/// <reference types="@testing-library/jest-dom/vitest" />
import { fireEvent, render, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import Block from '@/components/Block'
import type { TextBlock } from '@/types'

function block(text: string): TextBlock {
  return { type: 'text', text }
}

function renderText(text: string) {
  return render(<Block block={block(text)} />)
}

// --- existing behavior preserved (AC-4) ------------------------------------

describe('existing behavior preserved', () => {
  it('renders /clear as a command pill (command-name-led)', () => {
    renderText('<command-name>/clear</command-name>')
    expect(screen.getByText(/⌘/)).toBeInTheDocument()
    expect(screen.getByText(/\/clear/)).toBeInTheDocument()
  })

  it('renders turn_aborted as [interrupted by user]', () => {
    renderText(
      '<turn_aborted>\nThe user interrupted the previous turn on purpose.\n</turn_aborted>',
    )
    expect(screen.getByText('[interrupted by user]')).toBeInTheDocument()
  })

  it('renders local-command-stdout pairing (command-name-led)', () => {
    renderText(
      '<command-name>/compact</command-name>',
    )
    expect(screen.getByText(/⌘/)).toBeInTheDocument()
  })
})

// --- B1: command-message-led commands (AC-3, AC-4) -------------------------

describe('B1: command-message-led commands', () => {
  it('renders the ⌘ pill for a command-message-led command with name and args', () => {
    renderText(
      '<command-message>architect</command-message>\n<command-name>/architect</command-name>\n<command-args>judge it up</command-args>',
    )
    expect(screen.getByText(/⌘/)).toBeInTheDocument()
    expect(screen.getByText(/\/architect/)).toBeInTheDocument()
    expect(screen.getByText('judge it up')).toBeInTheDocument()
  })

  it('renders the ⌘ pill for command-message-led command without args', () => {
    renderText(
      '<command-message>architect</command-message>\n<command-name>/architect</command-name>',
    )
    expect(screen.getByText(/⌘/)).toBeInTheDocument()
    expect(screen.getByText(/\/architect/)).toBeInTheDocument()
  })

  it('falls through to text when command-message has no command-name or stdout', () => {
    renderText('<command-message>architect</command-message>')
    expect(screen.queryByText(/⌘/)).not.toBeInTheDocument()
  })

  it('B4: prose mentioning command-message mid-sentence does not render a pill', () => {
    renderText('Discussing the <command-message> tag format here.')
    expect(screen.queryByText(/⌘/)).not.toBeInTheDocument()
  })
})

// --- B2: task-notification (AC-3, AC-4) ------------------------------------

const TASK_COMPLETED = `<task-notification>
<task-id>abc123</task-id>
<tool-use-id>toolu_xyz789</tool-use-id>
<output-file>/tmp/tasks/abc123.output</output-file>
<status>completed</status>
<summary>Background command "Dispatch backend lane (background)" completed (exit code 0)</summary>
</task-notification>`

describe('B2: task-notification', () => {
  it('shows ✓ glyph and summary text for completed status', () => {
    renderText(TASK_COMPLETED)
    expect(screen.getByText('✓')).toBeInTheDocument()
    expect(
      screen.getByText(
        'Background command "Dispatch backend lane (background)" completed (exit code 0)',
      ),
    ).toBeInTheDocument()
  })

  it('hides detail fields by default (collapsed)', () => {
    const { container } = renderText(TASK_COMPLETED)
    const content = container.querySelector('[data-slot="collapsible-content"]')
    expect(content).toHaveAttribute('hidden')
  })

  it('reveals task-id and output-file after expanding', () => {
    const { container } = renderText(TASK_COMPLETED)
    fireEvent.click(
      screen.getByText(
        'Background command "Dispatch backend lane (background)" completed (exit code 0)',
      ),
    )
    expect(container.querySelector('[data-slot="collapsible-content"]')).not.toHaveAttribute(
      'hidden',
    )
    expect(screen.getByText('abc123')).toBeInTheDocument()
    expect(screen.getByText('/tmp/tasks/abc123.output')).toBeInTheDocument()
  })

  it('shows ✗ glyph for failed status', () => {
    renderText(
      '<task-notification><status>failed</status><summary>Command failed</summary></task-notification>',
    )
    expect(screen.getByText('✗')).toBeInTheDocument()
  })

  it('shows ✗ glyph for error status', () => {
    renderText(
      '<task-notification><status>error</status><summary>Command errored</summary></task-notification>',
    )
    expect(screen.getByText('✗')).toBeInTheDocument()
  })

  it('shows • glyph for unknown status', () => {
    renderText(
      '<task-notification><status>running</status><summary>Command still running</summary></task-notification>',
    )
    expect(screen.getByText('•')).toBeInTheDocument()
  })

  it('falls back to status word when summary is absent', () => {
    renderText('<task-notification><status>completed</status></task-notification>')
    expect(screen.getByText('✓')).toBeInTheDocument()
    expect(screen.getByText('completed')).toBeInTheDocument()
  })

  it('B4: prose mentioning task-notification mid-sentence does not render a pill', () => {
    renderText('Some prose mentioning <task-notification> mid-sentence.')
    expect(screen.queryByText('✓')).not.toBeInTheDocument()
    expect(screen.queryByText('✗')).not.toBeInTheDocument()
    expect(screen.queryByText('•')).not.toBeInTheDocument()
  })

  it('B4: unmatched task-notification (no closing tag) falls through to text', () => {
    renderText(
      '<task-notification>\n<status>completed</status>\n<summary>Test</summary>',
    )
    expect(screen.queryByText('✓')).not.toBeInTheDocument()
  })
})

// --- B3: harness boilerplate (AC-3, AC-4) ----------------------------------

describe('B3: local-command-caveat', () => {
  it('renders a collapsed caveat trigger', () => {
    renderText(
      '<local-command-caveat>Do not respond to these messages.</local-command-caveat>',
    )
    expect(screen.getByText('caveat')).toBeInTheDocument()
  })

  it('hides body by default', () => {
    const { container } = renderText(
      '<local-command-caveat>Do not respond to these messages.</local-command-caveat>',
    )
    expect(container.querySelector('[data-slot="collapsible-content"]')).toHaveAttribute('hidden')
  })

  it('reveals body text on expand', () => {
    const { container } = renderText(
      '<local-command-caveat>Do not respond to these messages.</local-command-caveat>',
    )
    fireEvent.click(screen.getByText('caveat'))
    expect(container.querySelector('[data-slot="collapsible-content"]')).not.toHaveAttribute(
      'hidden',
    )
    expect(screen.getByText('Do not respond to these messages.')).toBeInTheDocument()
  })

  it('B4: prose mentioning local-command-caveat mid-sentence does not render a marker', () => {
    renderText('Discussing the <local-command-caveat> tag format here.')
    expect(screen.queryByText('caveat')).not.toBeInTheDocument()
  })
})

describe('B3: system-reminder', () => {
  it('renders a collapsed system reminder trigger', () => {
    renderText('<system-reminder>This is a system reminder.</system-reminder>')
    expect(screen.getByText('system reminder')).toBeInTheDocument()
  })

  it('hides body by default', () => {
    const { container } = renderText(
      '<system-reminder>This is a system reminder.</system-reminder>',
    )
    expect(container.querySelector('[data-slot="collapsible-content"]')).toHaveAttribute('hidden')
  })

  it('reveals body text on expand', () => {
    const { container } = renderText(
      '<system-reminder>This is a system reminder.</system-reminder>',
    )
    fireEvent.click(screen.getByText('system reminder'))
    expect(container.querySelector('[data-slot="collapsible-content"]')).not.toHaveAttribute(
      'hidden',
    )
    expect(screen.getByText('This is a system reminder.')).toBeInTheDocument()
  })

  it('B4: prose mentioning system-reminder mid-sentence does not render a marker', () => {
    renderText('Some text about <system-reminder> tags in the middle.')
    expect(screen.queryByText('system reminder')).not.toBeInTheDocument()
  })

  it('B4: unmatched system-reminder (no closing tag) falls through to text', () => {
    renderText('<system-reminder>No closing tag here')
    expect(screen.queryByText('system reminder')).not.toBeInTheDocument()
  })
})

// --- skill envelope (AC1-AC3) ------------------------------------------

const SKILL_BODY = [
  'References are relative to /Users/eric/.agents/skills/architect.',
  '',
  '# Architect',
  ...Array.from({ length: 30 }, (_, i) => `line ${i} of skill markdown`),
].join('\n')

function skillEnvelope(rest = '') {
  return (
    `<skill name="architect" location="/Users/eric/.agents/skills/architect/SKILL.md">\n` +
    `${SKILL_BODY}\n</skill>` +
    (rest ? `\n\n${rest}` : '')
  )
}

describe('skill envelope', () => {
  it('renders a collapsed skill pill with the name, and location as muted detail', () => {
    renderText(skillEnvelope('do the thing'))
    expect(screen.getByText(/✦\s*architect/)).toBeInTheDocument()
    expect(
      screen.getByText('/Users/eric/.agents/skills/architect/SKILL.md'),
    ).toBeInTheDocument()
  })

  it('never renders the raw <skill tag text', () => {
    const { container } = renderText(skillEnvelope('do the thing'))
    expect(container.textContent).not.toContain('<skill')
    expect(container.textContent).not.toContain('</skill>')
  })

  it('hides the body by default (collapsed)', () => {
    const { container } = renderText(skillEnvelope('do the thing'))
    const content = container.querySelector('[data-slot="collapsible-content"]')
    expect(content).toHaveAttribute('hidden')
    expect(screen.queryByText(/# Architect/)).not.toBeInTheDocument()
  })

  it('expanding the pill reveals the body on a line-clamped code surface', () => {
    const { container } = renderText(skillEnvelope('do the thing'))
    fireEvent.click(screen.getByText(/✦/))
    const content = container.querySelector('[data-slot="collapsible-content"]')
    expect(content).not.toHaveAttribute('hidden')
    expect(container.textContent).toContain('References are relative to')
    // the body itself is long enough to trip CodeBlock's own line clamp
    expect(screen.getByText(/Show all \d+ lines/)).toBeInTheDocument()
    expect(container.textContent).not.toContain('line 29 of skill markdown')
  })

  it('collapses back after expanding', () => {
    const { container } = renderText(skillEnvelope('do the thing'))
    const trigger = screen.getByText(/✦/)
    fireEvent.click(trigger)
    fireEvent.click(trigger)
    expect(container.querySelector('[data-slot="collapsible-content"]')).toHaveAttribute('hidden')
  })

  it('renders the trailing rest as prose below the skill row', () => {
    renderText(skillEnvelope('please fix the flaky test'))
    expect(screen.getByText('please fix the flaky test')).toBeInTheDocument()
  })

  it('renders the pill alone with no empty prose section when promptless', () => {
    const { container } = renderText(skillEnvelope())
    expect(screen.getByText(/✦/)).toBeInTheDocument()
    // CollapsibleText's markdown wrapper (prose class) should not be mounted
    expect(container.querySelector('.prose')).not.toBeInTheDocument()
  })

  it('B4: prose mentioning the skill tag mid-message renders literally', () => {
    renderText(
      `I was reading about the <skill name="x" location="y"></skill> envelope format today.`,
    )
    expect(screen.queryByText(/✦/)).not.toBeInTheDocument()
    expect(
      screen.getByText(/I was reading about the/),
    ).toBeInTheDocument()
  })

  it('B4: an unclosed skill opener falls through to text', () => {
    renderText('<skill name="architect" location="loc">\nno closing tag here')
    expect(screen.queryByText(/✦/)).not.toBeInTheDocument()
  })

  it('B4: a code sample showing the tag does not render a pill', () => {
    renderText('```\n<skill name="x">...</skill>\n```\nsome other prose after the fence')
    expect(screen.queryByText(/✦/)).not.toBeInTheDocument()
  })
})
