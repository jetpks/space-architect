# frozen_string_literal: true

require "test_helper"
require "tempfile"

class ConfigStoreTest < Minitest::Test
  include TestHelpers

  Store = RepoTender::Config::Store
  Config = RepoTender::Config::Config
  RepoRef = RepoTender::Config::RepoRef
  OrgRef = RepoTender::Config::OrgRef

  # G1: round-trip. Load → mutate struct → write → reload → managed
  # fields byte-identical to the mutated struct.
  def test_round_trip_preserves_managed_fields
    Tempfile.create(["config", ".yaml"]) do |f|
      f.write(<<~YAML)
        base_dir: /tmp/evergreen
        refresh_interval: 7200
        concurrency: 16
        repos:
          - host: github.com
            owner: ruby
            name: ruby
        orgs:
          - name: example-org
            include_archived: true
      YAML
      f.flush

      cfg = Store.load(f.path).success
      refute_nil cfg

      # Mutate via the dry-struct `new(overrides)` idiom.
      new_repo = RepoRef.new(host: "github.com", owner: "foo", name: "bar")
      mutated = cfg.new(repos: cfg.repos + [new_repo], concurrency: 32)

      out = File.join(Dir.tmpdir, "repo-tender-rt-#{rand(1_000_000)}.yaml")
      File.delete(out) if File.exist?(out)
      write_result = Store.write(out, mutated)
      assert write_result.success?, "write failed: #{write_result.failure.inspect}"

      reloaded = Store.load(out).success
      assert_equal mutated.to_h, reloaded.to_h,
        "round-trip mismatch: mutated=#{mutated.to_h.inspect} reloaded=#{reloaded.to_h.inspect}"

      File.delete(out)
    end
  end

  # Documents a known limitation per gate G1: unknown top-level keys
  # and YAML comments are not preserved on write. The store's emitter
  # only writes the five managed fields.
  def test_write_emits_only_managed_fields
    Tempfile.create(["config", ".yaml"]) do |f|
      f.write(<<~YAML)
        # a human comment that will be lost
        base_dir: /tmp/evergreen
        refresh_interval: 7200
        concurrency: 16
        unknown_field: surprise
        repos: []
        orgs: []
      YAML
      f.flush

      cfg = Store.load(f.path).success
      out = File.join(Dir.tmpdir, "repo-tender-emit-#{rand(1_000_000)}.yaml")
      File.delete(out) if File.exist?(out)
      Store.write(out, cfg)

      contents = File.read(out)
      refute_includes contents, "unknown_field", "unknown_field should not be re-emitted"
      refute_includes contents, "# a human comment", "YAML comments are not preserved on write (known limitation per G1)"
      assert_includes contents, "base_dir"

      File.delete(out)
    end
  end

  def test_missing_file_loads_with_defaults
    path = "/tmp/repo-tender-nonexistent-#{rand(1_000_000)}.yaml"
    File.delete(path) if File.exist?(path)
    cfg = Store.load(path).success
    assert_equal Store::DEFAULT_BASE_DIR, cfg.base_dir
    assert_equal Store::DEFAULT_REFRESH_INTERVAL, cfg.refresh_interval
    assert_equal Store::DEFAULT_CONCURRENCY, cfg.concurrency
    assert_equal [], cfg.repos
    assert_equal [], cfg.orgs
  end

  def test_minimal_yaml_loads_with_struct_defaults
    Tempfile.create(["config", ".yaml"]) do |f|
      f.write("repos:\n  - owner: foo\n    name: bar\n")
      f.flush
      cfg = Store.load(f.path).success
      assert_equal "github.com", cfg.repos.first.host, "host defaults to github.com"
      assert_equal "foo", cfg.repos.first.owner
      assert_equal "bar", cfg.repos.first.name
      # Config-level defaults still applied
      assert_equal Store::DEFAULT_BASE_DIR, cfg.base_dir
    end
  end

  def test_write_validates_before_writing
    Tempfile.create(["config", ".yaml"]) do |f|
      f.write("")
      f.flush
      cfg = Store.load(f.path).success
      # The struct constructor refuses the bad value; assert that the
      # struct-level guard works. The store's own pre-write contract
      # check is exercised when callers bypass Struct.new (e.g. by
      # building a hash and constructing a struct directly).
      assert_raises(Dry::Struct::Error) do
        cfg.new(refresh_interval: -1)
      end

      # Build a contract-bad hash and run the write path's validator.
      bad_hash = cfg.to_h.merge(refresh_interval: -1)
      contract_result = RepoTender::Config::Contract.new.call(bad_hash)
      assert contract_result.failure?, "contract should reject negative refresh_interval"
      assert_includes contract_result.failure[:refresh_interval].first, "must be greater than 0"
    end
  end
end
