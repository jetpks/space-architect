# frozen_string_literal: true

require_relative "test_helper"

# Scans lib/**/*.rb for the raw filesystem-enumeration APIs whose dotfile
# behavior disagrees by default (Dir.glob, Pathname#children, ...) — see
# Space::Core::Paths. A hit outside the shared module means either a new
# callsite silently re-decided the dotfile question (route it through a
# Paths helper) or a legitimate non-filesystem/independent-module use, which
# must say so inline with a `# paths:exempt <reason>` annotation. A bare
# marker with no reason fails the guard just as loudly as an unannotated hit
# — a marker that can silence a hit without stating why is exactly the
# bare-list failure this guard exists to prevent.
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

  # Exempts a single hit: on the hit line itself (trailing) or on the
  # comment-only line directly above it. `(?!-file)` keeps this from also
  # matching the file-level marker below.
  LINE_EXEMPT = /#\s*paths:exempt(?!-file)\b\s*[-:—]?\s*(.*)\z/

  # Exempts every hit in the file, wherever the marker line sits.
  FILE_EXEMPT = /\A\s*#\s*paths:exempt-file\b\s*[-:—]?\s*(.*)\z/

  def test_no_raw_enumeration_outside_shared_module
    offenses = Dir.glob(File.join(LIB_ROOT, "**", "*.rb")).sort.flat_map { |path| offenses_in(path) }

    assert_empty offenses, offenses.join("\n")
  end

  private

  def offenses_in(path)
    rel = Pathname.new(path).relative_path_from(Pathname.new(LIB_ROOT)).to_s
    lines = File.readlines(path, chomp: true)

    file_reason = lines.filter_map { |line| line[FILE_EXEMPT, 1] }.first
    return [] if file_reason && !file_reason.empty?
    return ["#{rel} — `# paths:exempt-file` has no reason. State why the whole file is exempt."] if file_reason

    lines.each_with_index.filter_map { |line, idx| offense_for(rel, lines, line, idx) }
  end

  def offense_for(rel, lines, line, idx)
    hit_names = PATTERNS.select { |_name, regex| line.match?(regex) }.keys
    return if hit_names.empty?

    lineno = idx + 1
    reason = exemption_reason(lines, idx)
    return if reason && !reason.empty?

    if reason
      "#{rel}:#{lineno} — `# paths:exempt` has no reason. State why raw #{hit_names.join(', ')} is correct here."
    else
      "#{rel}:#{lineno} — raw #{hit_names.join(', ')} outside Space::Core::Paths. " \
        "Route it through a Paths helper, or annotate the line with `# paths:exempt <reason>` " \
        "explaining why raw enumeration is correct here."
    end
  end

  def exemption_reason(lines, idx)
    same_line = lines[idx][LINE_EXEMPT, 1]
    return same_line unless same_line.nil?
    return nil unless idx.positive?

    prev = lines[idx - 1].strip
    prev.start_with?("#") ? prev[LINE_EXEMPT, 1] : nil
  end
end
