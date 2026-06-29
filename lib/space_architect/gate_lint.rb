# frozen_string_literal: true

require "dry/monads"

module Space::Architect
  # Validates the structured gates block parsed from an iteration's
  # ## Acceptance Criteria section. Returns a Dry::Monads::Result:
  #   Success(gates) — well-formed (or empty list)
  #   Failure([messages]) — aggregated lint errors
  class GateLint
    include Dry::Monads[:result]

    VALID_GATE_KEYS     = %w[id ac cwd cmd expect].freeze
    VALID_EXPECT_KEYS   = %w[exit_code stdout_match threshold].freeze
    VALID_OPS           = %w[>= <= > < == !=].freeze
    VALID_THRESHOLD_KEYS = %w[match op value].freeze

    def self.call(gates) = new.call(gates)

    def call(gates)
      return Success([]) if gates.nil? || (gates.is_a?(Array) && gates.empty?)

      unless gates.is_a?(Array)
        return Failure(["gates block must be a YAML list, got #{gates.class}"])
      end

      errors  = []
      seen_ids = {}

      gates.each.with_index(1) do |gate, i|
        pfx = "gate[#{i}]"

        unless gate.is_a?(Hash)
          errors << "#{pfx}: must be a hash, got #{gate.class}"
          next
        end

        # Stringify all keys for uniform access
        g = gate.transform_keys(&:to_s)

        unknown = g.keys - VALID_GATE_KEYS
        errors << "#{pfx}: unknown keys: #{unknown.join(', ')}" if unknown.any?

        # id — required, non-empty String, unique
        id = g["id"]
        if id.nil? || (id.respond_to?(:empty?) && id.empty?)
          errors << "#{pfx}: id is required and must be a non-empty string"
        elsif !id.is_a?(String)
          errors << "#{pfx}: id must be a String"
        elsif seen_ids.key?(id)
          errors << "#{pfx}: duplicate id '#{id}' (also at gate[#{seen_ids[id]}])"
        else
          seen_ids[id] = i
        end

        # ac — required, non-empty String
        ac = g["ac"]
        if ac.nil? || (ac.is_a?(String) && ac.strip.empty?)
          errors << "#{pfx}: ac is required and must be a non-empty string"
        elsif !ac.is_a?(String)
          errors << "#{pfx}: ac must be a String"
        end

        # cmd — required, non-empty String
        cmd = g["cmd"]
        if cmd.nil? || (cmd.is_a?(String) && cmd.strip.empty?)
          errors << "#{pfx}: cmd is required and must be a non-empty string"
        elsif !cmd.is_a?(String)
          errors << "#{pfx}: cmd must be a String"
        end

        # cwd — optional String
        cwd = g["cwd"]
        errors << "#{pfx}: cwd must be a String" if !cwd.nil? && !cwd.is_a?(String)

        # expect — required Hash with >=1 known key, no unknown keys
        expect = g["expect"]
        if expect.nil?
          errors << "#{pfx}: expect is required"
        elsif !expect.is_a?(Hash)
          errors << "#{pfx}: expect must be a hash"
        else
          ex = expect.transform_keys(&:to_s)
          unknown_ex = ex.keys - VALID_EXPECT_KEYS
          errors << "#{pfx}.expect: unknown keys: #{unknown_ex.join(', ')}" if unknown_ex.any?

          valid_present = ex.keys & VALID_EXPECT_KEYS
          errors << "#{pfx}.expect: must have at least one of: #{VALID_EXPECT_KEYS.join(', ')}" if valid_present.empty?

          # exit_code — Integer
          if ex.key?("exit_code")
            errors << "#{pfx}.expect.exit_code: must be an Integer" unless ex["exit_code"].is_a?(Integer)
          end

          # stdout_match — String
          if ex.key?("stdout_match")
            errors << "#{pfx}.expect.stdout_match: must be a String" unless ex["stdout_match"].is_a?(String)
          end

          # threshold — Hash {match:String, op:String, value:Number}
          if ex.key?("threshold")
            thresh = ex["threshold"]
            if !thresh.is_a?(Hash)
              errors << "#{pfx}.expect.threshold: must be a hash"
            else
              th = thresh.transform_keys(&:to_s)
              unknown_th = th.keys - VALID_THRESHOLD_KEYS
              errors << "#{pfx}.expect.threshold: unknown keys: #{unknown_th.join(', ')}" if unknown_th.any?

              th_match = th["match"]
              th_op    = th["op"]
              th_value = th["value"]

              if th_match.nil? || !th_match.is_a?(String)
                errors << "#{pfx}.expect.threshold.match: must be a String"
              else
                begin
                  # Force a match with empty alternation to count capture groups
                  n_captures = Regexp.new("#{th_match}|(?:)").match("").captures.size
                  unless n_captures == 1
                    errors << "#{pfx}.expect.threshold.match: must contain exactly one capture group (found #{n_captures})"
                  end
                rescue RegexpError => e
                  errors << "#{pfx}.expect.threshold.match: invalid regexp: #{e.message}"
                end
              end

              unless th_op.is_a?(String) && VALID_OPS.include?(th_op)
                errors << "#{pfx}.expect.threshold.op: must be one of #{VALID_OPS.join(', ')}"
              end

              unless th_value.is_a?(Numeric)
                errors << "#{pfx}.expect.threshold.value: must be a Number"
              end
            end
          end
        end
      end

      errors.empty? ? Success(gates) : Failure(errors)
    end
  end
end
