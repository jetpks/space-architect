# frozen_string_literal: true

require_relative "test_helper"

# Scans lib/**/*.rb for the raw filesystem-enumeration APIs whose dotfile
# behavior disagrees by default (Dir.glob, Pathname#children, ...) — see
# Space::Core::Paths. A hit outside the shared module means either a new
# callsite silently re-decided the dotfile question (route it through a
# Paths helper) or a legitimate non-filesystem/independent-module use that
# needs a one-line EXEMPT entry explaining why raw enumeration is correct
# there.
class PathsGuardTest < Space::ArchitectTest
  LIB_ROOT = File.expand_path("../lib", __dir__)

  PATTERNS = {
    "Dir.glob" => /\bDir\.glob\b/,
    "Dir[...]" => /\bDir\[/,
    "Dir.children" => /\bDir\.children\b/,
    "Dir.entries" => /\bDir\.entries\b/,
    "Dir.each_child" => /\bDir\.each_child\b/,
    "File.fnmatch" => /\bFile\.fnmatch\b/,
    "Find.find" => /\bFind\.find\b/,
    ".children" => /\.children\b/
  }.freeze

  # "path" (relative to lib/) exempts the whole file; "path:line" exempts one
  # line. Each entry states why raw enumeration is correct there instead of
  # routed through Space::Core::Paths.
  EXEMPT = {
    "space_core/paths.rb" =>
      "the shared module itself — this is the one home the guard defends",
    "space_core/cli/help.rb:93" =>
      "result.children is a dry-cli command-tree node, not a filesystem path",
    "space_core/cli/help.rb:153" =>
      "node.children? is a dry-cli command-tree predicate, not a filesystem path",
    "space_src/cli.rb:72" =>
      "Registry.get([]).children is a dry-cli command-tree node, not a filesystem path",
    "space_src/nav.rb" =>
      "layout intent (depth-3 checkout scan); space_src is deliberately independent of " \
      "space_core and must not require it",
    "space_src/cloner.rb" =>
      "layout intent (checkout resolution by depth); space_src is deliberately independent " \
      "of space_core and must not require it",
    "space_architect/skill_installer.rb:49" =>
      "source_skills is intentionally dot-inclusive, consistent with install_skill's own " \
      "dot-inclusive FileUtils.cp_r a few lines below — excluding dotfiles here would be the wrong call",
    "space_architect/architect_project.rb:149" =>
      'the /\AI\d+-.+\.md\z/ filter structurally cannot match a dotfile-prefixed name, so raw ' \
      "enumeration is already dotfile-safe here",
    "space_architect/architect_project.rb:1031" =>
      'the /\AI\d+-.+\.md\z/ filter structurally cannot match a dotfile-prefixed name, so raw ' \
      "enumeration is already dotfile-safe here"
  }.freeze

  def test_no_raw_enumeration_outside_shared_module
    offenses = Dir.glob(File.join(LIB_ROOT, "**", "*.rb")).sort.flat_map do |path|
      rel = Pathname.new(path).relative_path_from(Pathname.new(LIB_ROOT)).to_s
      next [] if EXEMPT.key?(rel)

      File.readlines(path).each_with_index.filter_map do |line, idx|
        lineno = idx + 1
        next if EXEMPT.key?("#{rel}:#{lineno}")

        hit_names = PATTERNS.select { |_name, regex| line.match?(regex) }.keys
        next if hit_names.empty?

        "#{rel}:#{lineno} — raw #{hit_names.join(', ')} outside Space::Core::Paths. " \
          "Route it through a Paths helper, or add a one-line EXEMPT entry in " \
          "test/paths_guard_test.rb explaining why raw enumeration is correct here."
      end
    end

    assert_empty offenses, offenses.join("\n")
  end
end
