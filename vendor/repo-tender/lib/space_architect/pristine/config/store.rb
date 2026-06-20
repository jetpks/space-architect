# frozen_string_literal: true

require "yaml"
require "fileutils"
require "dry/monads"
require "space_architect/pristine/config/model"
require "space_architect/pristine/config/contract"

module SpaceArchitect::Pristine
  module Config
    # Load/validate/write-back the YAML config file.
    #
    # The store is the only place that touches the disk. It does not
    # preserve unknown keys or YAML comments on write — that's a known
    # limitation per the PRD §2 (YAML comment loss accepted) and is
    # documented in the Slice 1 lane report. Managed fields round-trip
    # byte-identically (gate G1).
    class Store
      extend Dry::Monads[:result]

      DEFAULT_BASE_DIR = SpaceArchitect::Pristine::Paths::DEFAULT_BASE_DIR
      DEFAULT_REFRESH_INTERVAL = 6 * 3600
      DEFAULT_CONCURRENCY = 8

      def self.load(path)
        raw = read_yaml(path)
        hash = symbolize(raw)
        # CF1: normalize `refresh_interval` from a human-duration
        # string ("6h", "90m", "45s", "30d") or bare integer string
        # ("21600") into integer seconds BEFORE the contract runs.
        # The contract stays integer-typed (:integer, gt?: 0); this
        # is a load-layer normalization that lets a hand-edited
        # config.yaml round-trip without rejecting "6h" as a
        # non-integer. See lib/repo_tender/config/duration.rb.
        if hash.key?(:refresh_interval)
          result = Duration.parse(hash[:refresh_interval])
          return result if result.failure?
          hash[:refresh_interval] = result.success
        end
        with_defaults(hash) do |filled|
          result = Contract.new.call(filled)
          if result.success?
            Success(Config.new(result.success))
          else
            Failure(result.failure)
          end
        end
      rescue Errno::ENOENT
        # Missing file is treated as an empty config (load defaults).
        # The store does not create the file on read — that is the
        # writer's job (write() is idempotent and always validates first).
        Success(Config.new(defaults))
      end

      def self.write(path, config)
        # Always re-validate the struct's contents before writing. This
        # guards against a caller constructing a Config with a
        # constraint-violating value via Struct.new (which does not run
        # the same checks as the contract).
        hash = config.to_h
        result = Contract.new.call(hash)
        return result if result.failure?

        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, emit(hash))
        Success(config)
      end

      def self.update(path)
        config = load(path).success
        new_config = yield(config)
        write(path, new_config)
      end

      # dry-struct update idiom: pass a hash of attributes to
      # `Config#new` to get a new struct with the overrides applied
      # (existing fields are kept).
      def self.with(config, **changes)
        config.new(**changes)
      end

      # Hash → human-clean YAML string. String keys, defaults omitted.
      # Stable key order: base_dir, refresh_interval, concurrency, repos, orgs.
      # repos/orgs omitted when empty.
      def self.emit(hash)
        ordered = {}
        ordered["base_dir"] = hash[:base_dir] if hash.key?(:base_dir)
        ordered["refresh_interval"] = hash[:refresh_interval] if hash.key?(:refresh_interval)
        ordered["concurrency"] = hash[:concurrency] if hash.key?(:concurrency)

        repos = hash[:repos]
        ordered["repos"] = repos.map { |r| compact_repo(r) } if repos && !repos.empty?

        orgs = hash[:orgs]
        ordered["orgs"] = orgs.map { |o| compact_org(o) } if orgs && !orgs.empty?

        YAML.dump(ordered, line_width: -1)
      end

      def self.compact_repo(r)
        h = {}
        h["host"] = r[:host] if r[:host] && r[:host] != DEFAULT_HOST
        h["owner"] = r[:owner]
        h["name"] = r[:name]
        h
      end

      def self.compact_org(o)
        h = {}
        h["host"] = o[:host] if o[:host] && o[:host] != DEFAULT_HOST
        h["name"] = o[:name]
        h["include_archived"] = true if o[:include_archived]
        h["include_forks"] = true if o[:include_forks]
        ignored = o[:ignored_repos]
        h["ignored_repos"] = ignored if ignored && !ignored.empty?
        h
      end

      def self.read_yaml(path)
        return {} unless File.exist?(path)
        # Symbol permitted because some YAML files use :symbol keys; the
        # store's symbolize() then re-keys consistently anyway. We still
        # disallow arbitrary classes.
        YAML.safe_load_file(path, permitted_classes: [Symbol], aliases: false) || {}
      end

      def self.symbolize(value)
        case value
        when Hash
          value.each_with_object({}) { |(k, v), acc| acc[k.to_sym] = symbolize(v) }
        when Array
          value.map { |v| symbolize(v) }
        else
          value
        end
      end

      # Fill in missing top-level defaults before validation, so an empty
      # YAML produces a fully-populated Config.
      def self.with_defaults(hash)
        filled = defaults.merge(hash)
        yield(filled)
      end

      def self.defaults
        {
          base_dir: DEFAULT_BASE_DIR,
          refresh_interval: DEFAULT_REFRESH_INTERVAL,
          concurrency: DEFAULT_CONCURRENCY,
          repos: [],
          orgs: []
        }
      end
    end
  end
end
