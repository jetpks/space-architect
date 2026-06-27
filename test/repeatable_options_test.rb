# frozen_string_literal: true

require_relative "test_helper"
require "dry/cli"

# Covers the dry-cli reopens in lib/space_architect/cli/repeatable_options.rb:
# repeated array-option flags accumulate, and the help advertises the repeatable
# flag rather than the comma-only form.
class RepeatableOptionsTest < Minitest::Test
  class Collect < Dry::CLI::Command
    option :repo, type: :array, aliases: ["-r"], desc: "Repo (repeatable)"
    def call(repo: [], **) = out.puts(repo.inspect)
  end

  module Registry
    extend Dry::CLI::Registry
    register "collect", Collect
  end

  def run_cli(*argv)
    out = StringIO.new
    Dry::CLI.new(Registry).call(arguments: ["collect", *argv], out: out, err: StringIO.new)
    out.string.chomp
  end

  def test_repeated_short_and_long_flags_accumulate
    assert_equal '["a", "b", "c"]', run_cli("-r", "a", "-r", "b", "-r", "c")
    assert_equal '["a", "b"]', run_cli("--repo", "a", "--repo", "b")
  end

  def test_comma_form_still_works_and_mixes_with_repeats
    assert_equal '["a", "b", "c"]', run_cli("-r", "a,b", "-r", "c")
  end

  def test_absent_array_option_defaults_to_empty
    assert_equal "[]", run_cli
  end

  def test_help_advertises_repeatable_flag_not_comma_form
    banner = Dry::CLI::Banner.call(Collect, "collect")
    assert_match("--repo=VALUE, -r VALUE", banner)
    refute_match(/VALUE1,VALUE2/, banner)
  end
end
