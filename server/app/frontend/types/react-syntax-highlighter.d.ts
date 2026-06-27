// @types/react-syntax-highlighter ships types for the package entry but not the
// deep per-language ESM paths we import for the PrismLight build. Declare them.
declare module 'react-syntax-highlighter/dist/esm/languages/prism/*' {
  const language: unknown
  export default language
}

declare module 'react-syntax-highlighter/dist/esm/prism-light' {
  import type { ComponentType } from 'react'
  import type { SyntaxHighlighterProps } from 'react-syntax-highlighter'
  const SyntaxHighlighter: ComponentType<SyntaxHighlighterProps> & {
    registerLanguage: (name: string, language: unknown) => void
  }
  export default SyntaxHighlighter
}

declare module 'react-syntax-highlighter/dist/esm/styles/prism' {
  const styles: Record<string, Record<string, React.CSSProperties>>
  export = styles
}
