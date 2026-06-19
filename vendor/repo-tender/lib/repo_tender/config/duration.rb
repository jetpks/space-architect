# frozen_string_literal: true

require "dry/monads"

module RepoTender
  module Config
    # CF1: parse a human-duration string into integer seconds.
    #
    # The contract and model keep `refresh_interval` as an integer
    # (types::Integer.constrained(gt: 0)); this module is the load-
    # layer normalization that lets a hand-edited config.yaml contain
    # "6h" / "90m" / "45s" / "30d" and have it round-trip through
    # Config::Store.load as 21600 / 5400 / 45 / 2592000 — so a user
    # who writes `refresh_interval: 6h` in their config gets the
    # same effect as `refresh_interval: 21600` without ever touching
    # the contract.
    #
    # The write-back path emits integer seconds (the human form is
    # not preserved on rewrite — consistent with Slice 1's documented
    # YAML comment-loss limitation, see test_write_emits_only_managed_fields).
    #
    # Usage:
    #   Duration.parse("6h")   # => Success(21600)
    #   Duration.parse(21600)  # => Success(21600)
    #   Duration.parse("-3h")  # => Failure("invalid duration: \"-3h\"")
    #   Duration.parse("6x")   # => Failure("invalid duration: \"6x\"")
    module Duration
      extend Dry::Monads[:result]

      # Unit suffixes recognized (PRD §3.1 documents "6h" / "90m" /
      # integer seconds; we also accept "s" and "d" for completeness
      # — they're natural extensions and cost zero code).
      UNIT_SECONDS = {
        nil => 1,        # bare integer string ("21600") or Integer input
        "s" => 1,
        "m" => 60,
        "h" => 3600,
        "d" => 86_400
      }.freeze

      # Strictly positive integer (no sign, no decimal, no leading
      # zeros that change the value's magnitude). Bare integer
      # strings ("21600") are accepted by making the unit suffix
      # optional in the pattern.
      PATTERN = /\A(\d+)([smhd])?\z/

      def self.parse(value)
        case value
        when Integer
          return failure_for(value) if value <= 0
          Success(value)
        when String
          parse_string(value)
        else
          failure_for(value)
        end
      end

      def self.parse_string(str)
        s = str.strip
        return failure_for(str) if s.empty?
        m = PATTERN.match(s)
        return failure_for(str) unless m
        n = m[1].to_i
        unit = m[2]
        # The pattern guarantees n is a positive integer ("\d+" matches
        # 1+ digits, never "0" with no other digits… well, "0" would
        # match with n=0). Reject zero explicitly to keep the
        # contract's "gt?: 0" guarantee.
        return failure_for(str) if n <= 0
        Success(n * UNIT_SECONDS.fetch(unit))
      end

      def self.failure_for(value)
        Failure("invalid duration: #{value.inspect} (expected positive integer or \"<n>[s|m|h|d]\" e.g. \"6h\", \"90m\", \"21600\")")
      end
    end
  end
end
