# frozen_string_literal: true

require "pathname"

module Space::Core
  module Paths
    module_function

    # Flags for matching a changed path against a lane's touch_set globs.
    # PATHNAME keeps a single `*` from crossing `/`; EXTGLOB enables `{a,b}`;
    # DOTMATCH lets a glob reach dotfile segments, so a `dir/**` touch set covers
    # `dir/.github/workflows/ci.yml` — the standard deliverable for a lane preparing
    # a directory to become a repo root.
    TOUCH_FNM = File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH

    # Every path beneath root, at every depth: files, directories, dotfiles, and
    # dot-directory contents all included. `File::FNM_DOTMATCH` is what makes
    # dotfiles visible to `Dir.glob`, but it also emits a bogus `root/.`
    # self-entry — that trap is absorbed here so no callsite has to know about it.
    def content_tree(root)
      Dir.glob(File.join(root.to_s, "**", "*"), File::FNM_DOTMATCH).reject { |p| File.basename(p) == "." }
    end

    # The direct children of a fixed-depth structured directory layout (one
    # entry per iteration/skill/lane/space) where a leading dot never names a
    # real layout member — only tooling junk (.git, .DS_Store). Excludes them.
    def layout_children(dir)
      Pathname.new(dir).children.reject { |c| c.basename.to_s.start_with?(".") }
    end

    # Does a single touch_set glob match path? A trailing `dir/**` is matched
    # twice: bare (PATHNAME stops it at direct children) and as `dir/**/*`,
    # whose whole-component `**/` does cross `/`.
    def touch_match?(glob, path)
      File.fnmatch(glob, path, TOUCH_FNM) ||
        (glob.end_with?("/**") && File.fnmatch("#{glob}/*", path, TOUCH_FNM))
    end

    def contract(path, env: ENV)
      value = path.to_s
      home  = XDG.home(env: env)
      [home, realpath_or_nil(home)].compact.uniq.each do |h|
        return "~"  if value == h
        return "~#{value.delete_prefix(h)}" if value.start_with?("#{h}/")
      end
      value
    end

    def realpath_or_nil(path)
      File.realpath(path)
    rescue SystemCallError
      nil
    end
  end
end
