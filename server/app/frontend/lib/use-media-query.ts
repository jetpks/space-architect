import { useEffect, useState } from 'react'

// Live matchMedia as state — how Show decides whether notes render in the
// margin column (wide screens) or inline under their targets (everything
// else). A render-time decision, not CSS hiding: the two presentations carry
// forms and ids that must not exist twice.
export function useMediaQuery(query: string): boolean {
  const [matches, setMatches] = useState(() => window.matchMedia(query).matches)
  useEffect(() => {
    const mq = window.matchMedia(query)
    const onChange = () => setMatches(mq.matches)
    onChange()
    mq.addEventListener('change', onChange)
    return () => mq.removeEventListener('change', onChange)
  }, [query])
  return matches
}
