# frozen_string_literal: true

require "yaml"
require "fileutils"
require "dry/monads"
require "repo_tender/config/model"
require "repo_tender/config/contract"

module RepoTender
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

      DEFAULT_BASE_DIR = RepoTender::Paths::DEFAULT_BASE_DIR
      DEFAULT_REFRESH_INTERVAL = 6 * 3600
      DEFAULT_CONCURRENCY = 8

      def self.load(path)
        raw = read_yaml(path)
        hash = symbolize(raw)
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

      # Hash → YAML string. Stable key order for diff-ability.
      def self.emit(hash)
        # Order: base_dir, refresh_interval, concurrency, repos, orgs.
        ordered = {}
        ordered[:base_dir] = hash[:base_dir] if hash.key?(:base_dir)
        ordered[:refresh_interval] = hash[:refresh_interval] if hash.key?(:refresh_interval)
        ordered[:concurrency] = hash[:concurrency] if hash.key?(:concurrency)
        ordered[:repos] = hash[:repos] if hash.key?(:repos) && !hash[:repos].nil?
        ordered[:orgs] = hash[:orgs] if hash.key?(:orgs) && !hash[:orgs].nil?

        # Ruby's Psych has a default flow style and key order that is
        # good enough — we don't customize it.
        YAML.dump(ordered, line_width: -1)
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
