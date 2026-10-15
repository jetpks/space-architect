# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/space_architect/extension_installer"
require "tmpdir"

# A fake pi on PATH logs its argv and can be told (via FAKE_PI_FAIL) to fail a
# step whose argv contains the marker — the dispatch `bin:` precedent
# (test/dispatch_detach_test.rb). Same fake-pi shape as the unit tests, but
# found through PATH like the real binary.
FAKE_PI = <<~RUBY
  #!/usr/bin/env ruby
  File.open(ENV.fetch("FAKE_PI_LOG"), "a") { |f| f.puts ARGV.join(" ") }
  if ENV["FAKE_PI_FAIL"] && ARGV.join(" ").include?(ENV["FAKE_PI_FAIL"])
    warn "boom: simulated pi failure"
    exit 1
  end
  exit 0
RUBY

class ExtensionInstallerTest < Space::ArchitectTest
  SOURCE = Space::Architect::ExtensionInstaller::PACKAGE_SOURCE

  def test_install_extensions_runs_the_exact_two_command_sequence
    with_fake_pi do |bin, log|
      result = Space::Architect::ExtensionInstaller.install(pi_bin: bin, env: {})

      assert_equal SOURCE, result[:source]
      assert_equal ["#{bin} install #{SOURCE}", "#{bin} update --extension #{SOURCE}"],
                   result[:steps].map { |s| s[:cmd] }, "install first, then the singular --extension update"
      assert_equal [0, 0], result[:steps].map { |s| s[:exit_code] }
      assert_equal File.read(log).lines.map(&:chomp), ["install #{SOURCE}", "update --extension #{SOURCE}"]
    end
  end

  # Idempotent by pi's semantics — a second run repeats the same sequence and
  # succeeds again.
  def test_install_extensions_second_run_succeeds
    with_fake_pi do |bin, log|
      2.times { Space::Architect::ExtensionInstaller.install(pi_bin: bin, env: {}) }

      assert_equal ["install #{SOURCE}", "update --extension #{SOURCE}"] * 2,
                   File.read(log).lines.map(&:chomp)
    end
  end

  def test_install_extensions_missing_binary_raises_loudly
    error = assert_raises(Space::Core::Error) do
      Space::Architect::ExtensionInstaller.install(pi_bin: "/nonexistent-dir/pi", env: {})
    end

    assert_match(/pi.*command not found/, error.message, "names the missing binary")
    assert_match(%r{pi install #{Regexp.escape(SOURCE)}}, error.message, "names the exact command")
    assert_match(/Install pi or check your PATH/, error.message, "names the remediation")
  end

  # A failing update's error carries the exact command plus the captured
  # stdout+stderr verbatim.
  def test_install_extensions_failing_update_carries_command_and_output
    with_fake_pi do |bin, log|
      error = assert_raises(Space::Core::Error) do
        Space::Architect::ExtensionInstaller.install(pi_bin: bin, env: { "FAKE_PI_FAIL" => "update" })
      end

      assert_match(/#{Regexp.escape("#{bin} update --extension #{SOURCE}")} failed \(exit 1\)/, error.message)
      assert_match(/boom: simulated pi failure/, error.message, "captured stderr rides the error verbatim")
      assert_equal ["install #{SOURCE}", "update --extension #{SOURCE}"], File.read(log).lines.map(&:chomp)
    end
  end

  # Loud failure aborts before the next step: a failing install means the
  # update never runs.
  def test_install_extensions_failure_aborts_before_the_next_step
    with_fake_pi do |bin, log|
      assert_raises(Space::Core::Error) do
        Space::Architect::ExtensionInstaller.install(pi_bin: bin, env: { "FAKE_PI_FAIL" => "install" })
      end

      assert_equal ["install #{SOURCE}"], File.read(log).lines.map(&:chomp),
        "the failed install aborts the run — no further step executes"
    end
  end

  # CLI-level: the real command finds pi through PATH and prints one line per
  # step plus the source.
  def test_install_extensions_command_installs_via_path
    with_fake_pi do |_bin, log|
      out, err = invoke("install-extensions")

      assert_empty err
      assert_match(%r{install #{Regexp.escape(SOURCE)} \(exit 0\)}, out)
      assert_match(%r{update --extension #{Regexp.escape(SOURCE)} \(exit 0\)}, out)
      assert_match(/Extensions source: #{Regexp.escape(SOURCE)}/, out)
      assert_equal ["install #{SOURCE}", "update --extension #{SOURCE}"], File.read(log).lines.map(&:chomp)
    end
  end

  private

  # Writes the fake pi into a tmpdir, puts that dir on PATH (so the CLI-level
  # test resolves it like the real binary), and passes the fake binary's path
  # plus its log path to the block.
  def with_fake_pi
    Dir.mktmpdir("extension-installer-test") do |dir|
      bin = File.join(dir, "pi")
      File.write(bin, FAKE_PI)
      File.chmod(0o755, bin)
      log = File.join(dir, "pi.log")

      with_env({ "FAKE_PI_LOG" => log, "PATH" => "#{dir}#{File::PATH_SEPARATOR}#{ENV['PATH']}" }) do
        yield bin, log
      end
    end
  end
end
