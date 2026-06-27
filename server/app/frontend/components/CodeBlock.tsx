import { useContext, useState } from 'react'
import SyntaxHighlighter from 'react-syntax-highlighter/dist/esm/prism-light'
import { ExpandClampsContext } from '@/lib/expand-clamps'
import { nightOwl } from 'react-syntax-highlighter/dist/esm/styles/prism'
import bash from 'react-syntax-highlighter/dist/esm/languages/prism/bash'
import c from 'react-syntax-highlighter/dist/esm/languages/prism/c'
import cpp from 'react-syntax-highlighter/dist/esm/languages/prism/cpp'
import css from 'react-syntax-highlighter/dist/esm/languages/prism/css'
import diff from 'react-syntax-highlighter/dist/esm/languages/prism/diff'
import docker from 'react-syntax-highlighter/dist/esm/languages/prism/docker'
import go from 'react-syntax-highlighter/dist/esm/languages/prism/go'
import javascript from 'react-syntax-highlighter/dist/esm/languages/prism/javascript'
import json from 'react-syntax-highlighter/dist/esm/languages/prism/json'
import jsx from 'react-syntax-highlighter/dist/esm/languages/prism/jsx'
import markdown from 'react-syntax-highlighter/dist/esm/languages/prism/markdown'
import markup from 'react-syntax-highlighter/dist/esm/languages/prism/markup'
import python from 'react-syntax-highlighter/dist/esm/languages/prism/python'
import ruby from 'react-syntax-highlighter/dist/esm/languages/prism/ruby'
import rust from 'react-syntax-highlighter/dist/esm/languages/prism/rust'
import scss from 'react-syntax-highlighter/dist/esm/languages/prism/scss'
import sql from 'react-syntax-highlighter/dist/esm/languages/prism/sql'
import toml from 'react-syntax-highlighter/dist/esm/languages/prism/toml'
import tsx from 'react-syntax-highlighter/dist/esm/languages/prism/tsx'
import typescript from 'react-syntax-highlighter/dist/esm/languages/prism/typescript'
import yaml from 'react-syntax-highlighter/dist/esm/languages/prism/yaml'

// Output longer than this many lines collapses behind a toggle (shared with the
// plain OutputBlock so code and CLI output behave the same).
export const COLLAPSE_THRESHOLD = 24

// The active theme's background, exported so OutputBlock (ANSI output, which
// can't go through the highlighter) can match it — one source of truth for the
// "code surface" look.
export const CODE_BG = (nightOwl['pre[class*="language-"]']?.background as string) ?? '#011627'

// Shared container chrome for the code/output surface.
export const codeSurface: React.CSSProperties = {
  margin: 0,
  padding: '0.5rem',
  borderRadius: '0.5rem',
  border: '1px solid var(--border)',
  fontSize: '0.75rem',
  lineHeight: 1.4,
}

for (const [name, lang] of Object.entries({
  bash,
  c,
  cpp,
  css,
  diff,
  docker,
  go,
  javascript,
  json,
  jsx,
  markdown,
  markup,
  python,
  ruby,
  rust,
  scss,
  sql,
  toml,
  tsx,
  typescript,
  yaml,
})) {
  SyntaxHighlighter.registerLanguage(name, lang)
}

const EXT_LANG: Record<string, string> = {
  rb: 'ruby',
  rake: 'ruby',
  gemspec: 'ruby',
  js: 'javascript',
  mjs: 'javascript',
  cjs: 'javascript',
  jsx: 'jsx',
  ts: 'typescript',
  tsx: 'tsx',
  json: 'json',
  yml: 'yaml',
  yaml: 'yaml',
  md: 'markdown',
  markdown: 'markdown',
  py: 'python',
  go: 'go',
  rs: 'rust',
  c: 'c',
  h: 'c',
  cpp: 'cpp',
  cc: 'cpp',
  cxx: 'cpp',
  hpp: 'cpp',
  css: 'css',
  scss: 'scss',
  html: 'markup',
  xml: 'markup',
  svg: 'markup',
  sql: 'sql',
  toml: 'toml',
  sh: 'bash',
  bash: 'bash',
  zsh: 'bash',
  diff: 'diff',
  patch: 'diff',
}

const NAME_LANG: Record<string, string> = {
  gemfile: 'ruby',
  rakefile: 'ruby',
  dockerfile: 'docker',
}

// Pick a Prism language for a file path, or undefined when we don't recognize it
// (the caller then falls back to plain monospace rendering).
export function languageFor(path: string): string | undefined {
  const base = path.split('/').pop()?.toLowerCase() ?? ''
  if (NAME_LANG[base]) return NAME_LANG[base]
  const ext = base.includes('.') ? base.split('.').pop()! : ''
  return EXT_LANG[ext]
}

// Read output arrives in `cat -n` form ("   12\tcode"). Split the gutter off so
// we can highlight the code and still show real line numbers. Returns null when
// the text isn't consistently numbered (then we highlight it verbatim).
function stripLineNumbers(text: string): { start: number; code: string } | null {
  const lines = text.split('\n')
  const re = /^\s*(\d+)\t(.*)$/
  let start: number | null = null
  const code: string[] = []
  for (const line of lines) {
    const m = line.match(re)
    if (m) {
      if (start === null) start = parseInt(m[1], 10)
      code.push(m[2])
    } else if (line === '') {
      code.push('')
    } else {
      return null
    }
  }
  return start === null ? null : { start, code: code.join('\n') }
}

export default function CodeBlock({
  text,
  language,
  showLineNumbers = true,
}: {
  text: string
  language: string
  showLineNumbers?: boolean
}) {
  // Range notes in the surrounding message start the collapse open — see
  // lib/expand-clamps.
  const [expanded, setExpanded] = useState(useContext(ExpandClampsContext))
  const stripped = showLineNumbers ? stripLineNumbers(text) : null
  const body = stripped ? stripped.code : text
  const start = stripped ? stripped.start : 1

  const lines = body.split('\n')
  const truncatable = lines.length > COLLAPSE_THRESHOLD
  const shown = truncatable && !expanded ? lines.slice(0, COLLAPSE_THRESHOLD).join('\n') : body

  return (
    <div className="text-sm">
      <SyntaxHighlighter
        language={language}
        style={nightOwl}
        showLineNumbers={showLineNumbers}
        startingLineNumber={start}
        wrapLongLines
        customStyle={codeSurface}
      >
        {shown}
      </SyntaxHighlighter>
      {truncatable && (
        <button
          onClick={() => setExpanded(!expanded)}
          className="mt-1 text-muted-foreground hover:text-foreground"
        >
          {expanded ? 'Collapse' : `Show all ${lines.length} lines`}
        </button>
      )}
    </div>
  )
}
