import { createContext } from 'react'

// True when the surrounding message carries range notes. Every line-clamp
// inside it (prose show-more, output clamp, code collapse) reads this as its
// initial state, so a highlighted passage buried past a clamp is visible on
// load instead of silently hidden — however deep the clamp sits. Provided by
// Message around its rendered blocks; toggles still work afterwards.
export const ExpandClampsContext = createContext(false)
