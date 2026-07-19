import { Link, router, usePage } from '@inertiajs/react'
import { LogIn, LogOut, Upload } from 'lucide-react'
import { Avatar, AvatarFallback, AvatarImage } from '@/components/ui/avatar'
import { Button } from '@/components/ui/button'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
import type { SharedProps } from '@/types'

function csrfToken(): string {
  const match = document.cookie.match(/(?:^|;\s*)XSRF-TOKEN=([^;]*)/)
  return match ? decodeURIComponent(match[1]) : ''
}

export default function Nav() {
  const { current_user } = usePage<SharedProps>().props

  return (
    <header className="border-b border-border bg-card">
      <div className="mx-auto flex max-w-4xl items-center justify-between px-6 py-3">
        <Link href="/" className="font-mono text-lg font-bold tracking-tight">
          chat_share
        </Link>

        <nav className="flex items-center gap-3">
          <Button asChild variant="ghost" size="sm">
            <Link href="/runs">Runs</Link>
          </Button>

          {current_user ? (
            <>
              <Button asChild variant="ghost" size="sm">
                <Link href="/jobs">Jobs</Link>
              </Button>

              <Button asChild variant="ghost" size="sm">
                <Link href="/conversations/new">
                  <Upload className="size-4" /> Upload
                </Link>
              </Button>

              <DropdownMenu>
                <DropdownMenuTrigger asChild>
                  <button className="flex items-center gap-2 rounded-full outline-none">
                    <Avatar className="size-8">
                      {current_user.avatar_url && (
                        <AvatarImage src={current_user.avatar_url} alt={current_user.username} />
                      )}
                      <AvatarFallback>
                        {current_user.username.slice(0, 2).toUpperCase()}
                      </AvatarFallback>
                    </Avatar>
                    <span className="text-sm text-muted-foreground">
                      {current_user.username}
                    </span>
                  </button>
                </DropdownMenuTrigger>
                <DropdownMenuContent align="end">
                  <DropdownMenuItem onClick={() => router.delete('/logout')}>
                    <LogOut className="size-4" /> Sign out
                  </DropdownMenuItem>
                </DropdownMenuContent>
              </DropdownMenu>
            </>
          ) : (
            // Native full-page POST — NOT Inertia. The OmniAuth request phase
            // requires POST + CSRF, and the browser must follow the cross-origin
            // 302 to GitHub (an Inertia XHR cannot).
            <form action="/auth/github" method="post">
              <input type="hidden" name="authenticity_token" value={csrfToken()} />
              <Button type="submit" size="sm">
                <LogIn className="size-4" /> Sign in with GitHub
              </Button>
            </form>
          )}
        </nav>
      </div>
    </header>
  )
}
