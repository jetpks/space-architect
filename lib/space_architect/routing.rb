# frozen_string_literal: true

require "yaml"
require "pathname"

module Space::Architect
  # The v1 `architect.yaml` loop-role routing contract — the parity twin of the
  # pi extension's parser (the extension's behavior defines v1; the one
  # deliberate addition this iteration is `thinking` VALUE validation, landed on
  # both sides). Pure module: parse one file's text, resolve the merged routing
  # for a space, nil when no config exists anywhere. Every invalid state raises
  # Space::Core::Error in the CLI's idiom, naming the file, the key, and the
  # expectation. Resolution layers are [global, space-local], merged per role
  # key; global is ENV["SPACE_ARCHITECT_GLOBAL_CONFIG"] if set, else
  # ~/.config/space-architect/architect.yaml (exactly the extension's
  # resolution — parity outranks the XDG convention, do not divert to
  # XDG_CONFIG_HOME); space-local is architect.yaml beside the loaded
  # space.yaml (the CLI already resolved the space — no walk-up).
  module Routing
    ROLES          = %w[architect spec builder judge coordinator narrator].freeze
    # The five agent roles that must be routed after the merge; `architect` is optional.
    REQUIRED_ROLES = %w[spec builder judge coordinator narrator].freeze
    ENTRY_KEYS     = %w[model thinking].freeze

    # I09: the `architect routing init` scaffold — the exact bytes the command
    # writes, living beside the parsers that must accept it. Example models are
    # loud REPLACE_MEs; the header comment carries both locations and the merge
    # order so the file is self-documenting. Byte-exact contract: the extension
    # lane's tests carry an inline copy, and the command round-trips the write
    # through parse below — a template the machinery rejects is a bug.
    TEMPLATE = <<~'YAML'.freeze
      # architect.yaml — space-architect loop role routing, scaffolded by `architect routing init`.
      # Locations (merged in this order; the space-local entry wins per role):
      #   global:  ~/.config/space-architect/architect.yaml   (machine-wide)
      #   local:   architect.yaml beside this space's space.yaml (this file)
      # A local entry overrides the global entry for THAT ROLE only; after the
      # merge every agent role must be routed: spec, builder, judge, coordinator,
      # narrator (architect is optional).
      # Replace every example/REPLACE_ME below with a real provider/model-id
      # (e.g. zai/glm-5.3). thinking is optional: off|minimal|low|medium|high|xhigh|max.
      # Once saved, the next /loop or architect command picks the file up.
      version: 1
      roles:
        architect:
          model: example/REPLACE_ME
          thinking: high
        spec:
          model: example/REPLACE_ME
          thinking: high
        builder:
          model: example/REPLACE_ME
          thinking: high
        judge:
          model: example/REPLACE_ME
          thinking: high
        coordinator:
          model: example/REPLACE_ME
          thinking: high
        narrator:
          model: example/REPLACE_ME
          thinking: low
    YAML

    # The one canonical cure line appended to default_model_inform's last-resort
    # inform — self-punctuating, appended after a single space by the caller.
    INIT_HINT = "Create one: `architect routing init` (beside space.yaml) or `architect routing init --global` (~/.config/space-architect/architect.yaml).".freeze

    def self.global_path
      env = ENV["SPACE_ARCHITECT_GLOBAL_CONFIG"]
      return Pathname.new(env) unless env.nil?
      Pathname.new("~/.config/space-architect/architect.yaml").expand_path
    end

    def self.space_path(space_dir)
      Pathname.new(space_dir).join("architect.yaml")
    end

    # Parse one file's text into { role => {"model" => id, "thinking" => level|nil} }.
    # +path+ is used only in error messages. Frozen v1 rules: integer version 1,
    # the six known roles, entries ⊆ {model, thinking} with a non-empty model,
    # duplicate mapping keys rejected (psych's plain load silently keeps the
    # last — the npm yaml the extension parses with throws), aliases accepted,
    # a trailing :level suffix on model parsed via Harness.parse_model_suffix
    # and beating the thinking key.
    def self.parse(text, path)
      assert_unique_keys!(text, path)
      doc = YAML.safe_load(text, aliases: true)
      unless doc.is_a?(Hash)
        raise Space::Core::Error, "architect.yaml (#{path}): <top> — expected a YAML mapping, got #{doc.inspect}"
      end
      version = doc["version"]
      unless version.is_a?(Integer) && version == 1
        raise Space::Core::Error, "architect.yaml (#{path}): version — expected integer 1, got #{version.inspect}"
      end
      roles = doc["roles"]
      unless roles.is_a?(Hash)
        raise Space::Core::Error, "architect.yaml (#{path}): roles — expected a mapping of role → entry, got #{roles.inspect}"
      end

      parsed = {}
      roles.each do |role, entry|
        unless ROLES.include?(role)
          raise Space::Core::Error,
            "architect.yaml (#{path}): roles.#{role} — expected one of #{ROLES.join('|')}, got #{role.inspect}"
        end
        unless entry.is_a?(Hash)
          raise Space::Core::Error,
            "architect.yaml (#{path}): roles.#{role} — expected a {model, thinking?} mapping, got #{entry.inspect}"
        end
        entry.each_key do |entry_key|
          unless ENTRY_KEYS.include?(entry_key)
            raise Space::Core::Error,
              "architect.yaml (#{path}): roles.#{role}.#{entry_key} — expected one of #{ENTRY_KEYS.join('|')}, got #{entry_key.inspect}"
          end
        end
        raw_model = entry["model"]
        unless raw_model.is_a?(String) && !raw_model.strip.empty?
          raise Space::Core::Error,
            "architect.yaml (#{path}): roles.#{role}.model — expected non-empty 'provider/model-id[:level]', got #{raw_model.inspect}"
        end
        model, suffix_level = Harness.parse_model_suffix(raw_model.strip)

        thinking = nil
        if entry.key?("thinking")
          raw_thinking = entry["thinking"]
          # psych implements YAML 1.1, where a bare `off` is boolean false; the
          # extension's YAML 1.2 parser reads it as the string "off". Coerce so
          # `thinking: off` parses identically on both sides.
          raw_thinking = "off" if raw_thinking == false
          unless raw_thinking.is_a?(String) && Harness::THINKING_LEVELS.include?(raw_thinking.strip)
            raise Space::Core::Error,
              "architect.yaml (#{path}): roles.#{role}.thinking — expected one of " \
              "#{Harness::THINKING_LEVELS.join('|')}, got #{entry['thinking'].inspect}"
          end
          thinking = raw_thinking.strip
        end
        parsed[role] = { "model" => model, "thinking" => suffix_level || thinking }
      end
      parsed
    rescue Psych::Exception => e
      raise Space::Core::Error, "architect.yaml (#{path}): malformed YAML — #{e.message}"
    end

    # The merged routing for a space: [global, space-local] merged per role key
    # (a space file may override only builder and inherit the rest). nil when
    # NEITHER file exists — no config is a normal state: no error, no side
    # effects. Any found file that is malformed/invalid fails loud at parse;
    # after the merge all four agent roles must be routed.
    def self.for_space(space_dir)
      global = global_path
      local  = space_path(space_dir)
      found  = [global, local].select { |p| File.file?(p.to_s) }
      return nil if found.empty?

      merged = {}
      found.each { |p| merged.merge!(parse(File.read(p.to_s), p)) }
      missing = REQUIRED_ROLES - merged.keys
      if missing.any?
        raise Space::Core::Error,
          "architect.yaml (#{found.join(' + ')}): roles.#{missing.first} — expected all agent roles " \
          "#{REQUIRED_ROLES.join('|')} to be routed, got (missing)"
      end
      merged
    end

    # Duplicate mapping keys anywhere in the document fail loud. Walks the psych
    # node tree (a second, cheap parse) because YAML.safe_load cannot report them.
    # An empty document parses to `false` (no root node) — skip the walk and let
    # safe_load surface it as the loud not-a-mapping error.
    def self.assert_unique_keys!(text, path)
      tree = Psych.parse(text, filename: path.to_s)
      return if tree == false
      walk_unique_keys(tree.root, path)
    end

    def self.walk_unique_keys(node, path)
      return unless node.is_a?(Psych::Nodes::Mapping) || node.is_a?(Psych::Nodes::Sequence)
      if node.is_a?(Psych::Nodes::Mapping)
        seen = {}
        node.children.each_slice(2) do |key, _value| # paths:exempt — psych AST walk, not filesystem enumeration
          next unless key.is_a?(Psych::Nodes::Scalar)
          if seen[key.value]
            raise Space::Core::Error,
              "architect.yaml (#{path}): duplicate mapping key '#{key.value}' — map keys must be unique"
          end
          seen[key.value] = true
        end
      end
      node.children.each { |child| walk_unique_keys(child, path) } # paths:exempt — psych AST walk, not filesystem enumeration
    end
  end
end
