import { usePage } from '@inertiajs/react'
import type { ReactNode } from 'react'
import Nav from '@/components/Nav'
import type { SharedProps } from '@/types'

export default function AppLayout({
  children,
  mainClassName = 'max-w-4xl',
}: {
  children: ReactNode
  // Width of the centered content column; Show widens it to fit the TOC rail.
  mainClassName?: string
}) {
  const { flash } = usePage<SharedProps>().props

  return (
    <div className="min-h-screen bg-background text-foreground">
      <Nav />

      {flash?.notice && (
        <p className="mx-auto max-w-4xl px-6 pt-4 text-sm text-accent-foreground">
          {flash.notice}
        </p>
      )}
      {flash?.alert && (
        <p className="mx-auto max-w-4xl px-6 pt-4 text-sm text-destructive">{flash.alert}</p>
      )}

      <main className={`mx-auto ${mainClassName} px-6 py-6`}>{children}</main>
    </div>
  )
}
