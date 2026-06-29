# frozen_string_literal: true

require "dry/validation"
require "dry/validation/extensions/monads"
require "dry/monads"

module Space::Architect
  # Validates the structured gates block parsed from an iteration's
  # ## Acceptance Criteria section. Returns a Dry::Monads::Result:
  #   Success(gates) — well-formed (or empty list)
  #   Failure([messages]) — aggregated lint errors
  class GateLint
    include Dry::Monads[:result]

    class GateContract < Dry::Validation::Contract
      VALID_OPS = %w[>= <= > < == !=].freeze

      json do
        config.validate_keys = true

        required(:id).filled(:string)
        required(:ac).filled(:string)
        required(:cmd).filled(:string)
        optional(:cwd).maybe(:string)
        required(:expect).hash do
          optional(:exit_code)
          optional(:stdout_match).filled(:string)
          optional(:threshold).hash do
            required(:match).filled(:string)
            required(:op).filled(:string)
            required(:value)
          end
        end
      end

      rule(:cmd) { key.failure("must not be blank") if values[:cmd].is_a?(String) && values[:cmd].strip.empty? }
      rule(:id)  { key.failure("must not be blank") if values[:id].is_a?(String) && values[:id].strip.empty? }
      rule(:ac)  { key.failure("must not be blank") if values[:ac].is_a?(String) && values[:ac].strip.empty? }

      rule(:expect) do
        next unless values[:expect].is_a?(Hash)
        known = %i[exit_code stdout_match threshold]
        key.failure("must have at least one of: #{known.join(", ")}") if known.none? { |k| values[:expect].key?(k) }
      end

      rule("expect.exit_code") do
        val = values.dig(:expect, :exit_code)
        key.failure("must be an Integer") if !val.nil? && !val.is_a?(Integer)
      end

      rule("expect.threshold.op") do
        val = values.dig(:expect, :threshold, :op)
        key.failure("must be one of: #{VALID_OPS.join(", ")}") if val.is_a?(String) && !VALID_OPS.include?(val)
      end

      rule("expect.threshold.match") do
        val = values.dig(:expect, :threshold, :match)
        next unless val.is_a?(String)
        begin
          n = Regexp.new("#{val}|(?:)").match("").captures.size
          key.failure("must contain exactly one capture group (found #{n})") unless n == 1
        rescue RegexpError => e
          key.failure("invalid regexp: #{e.message}")
        end
      end

      rule("expect.threshold.value") do
        val = values.dig(:expect, :threshold, :value)
        key.failure("must be a Number") if !val.nil? && !val.is_a?(Numeric)
      end
    end

    def self.call(gates) = new.call(gates)

    def call(gates)
      return Success([]) if gates.nil? || (gates.is_a?(Array) && gates.empty?)
      return Failure(["gates block must be a YAML list, got #{gates.class}"]) unless gates.is_a?(Array)

      errors   = []
      seen_ids = {}
      contract = GateContract.new

      gates.each.with_index(1) do |gate, i|
        pfx = "gate[#{i}]"
        unless gate.is_a?(Hash)
          errors << "#{pfx}: must be a hash, got #{gate.class}"
          next
        end

        result = contract.call(gate)
        flatten_errors(result.errors.to_h, pfx, errors) unless result.success?

        id = gate["id"] || gate[:id]
        id = (id.is_a?(String) && !id.strip.empty?) ? id : nil
        next unless id

        if seen_ids.key?(id)
          errors << "#{pfx}: duplicate id '#{id}' (also at gate[#{seen_ids[id]}])"
        else
          seen_ids[id] = i
        end
      end

      errors.empty? ? Success(gates) : Failure(errors)
    end

    private

    # Recursively flatten the nested errors hash from dry-validation into
    # a flat Array<String>, translating "is not allowed" into "unknown key: <name>".
    def flatten_errors(node, prefix, acc)
      case node
      when Array
        node.each do |item|
          case item
          when String
            if item == "is not allowed"
              *parent_parts, key_name = prefix.split(".")
              acc << "#{parent_parts.join(".")}: unknown key: #{key_name}"
            else
              acc << "#{prefix}: #{item}"
            end
          when Array, Hash
            flatten_errors(item, prefix, acc)
          end
        end
      when Hash
        node.each do |k, v|
          flatten_errors(v, "#{prefix}.#{k}", acc)
        end
      end
    end
  end
end
