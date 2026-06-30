# frozen_string_literal: true

module Space::Architect
  # Evaluates a single gate's captured output against its frozen expect block.
  # Pure — no I/O. Mirrors GateLint's class shape.
  #
  # GateEvaluator.call(stdout:, exit_code:, expect:) → Result
  #   result.pass?  → Boolean
  #   result.reason → String (empty on pass, first failing matcher on fail)
  class GateEvaluator
    Result = Data.define(:pass, :reason) do
      def pass? = pass
    end

    def self.call(stdout:, exit_code:, expect:) = new.call(stdout: stdout, exit_code: exit_code, expect: expect)

    def call(stdout:, exit_code:, expect:)
      e = (expect || {}).transform_keys(&:to_s)

      if e.key?("exit_code")
        expected = e["exit_code"]
        unless exit_code == expected
          return Result.new(pass: false, reason: "exit_code #{exit_code.inspect} != #{expected}")
        end
      end

      if (pattern = e["stdout_match"])
        unless Regexp.new(pattern).match?(stdout.to_s)
          return Result.new(pass: false, reason: "stdout did not match /#{pattern}/")
        end
      end

      if (thresh = e["threshold"])
        result = check_threshold(stdout.to_s, thresh.transform_keys(&:to_s))
        return result unless result.pass?
      end

      Result.new(pass: true, reason: "")
    end

    private

    def check_threshold(stdout, thresh)
      re = Regexp.new(thresh["match"])
      m  = nil
      stdout.scan(re) { m = Regexp.last_match }
      return Result.new(pass: false, reason: "metric not found") unless m

      captured = m.captures.first
      begin
        num = Float(captured)
      rescue ArgumentError
        return Result.new(pass: false, reason: "metric capture #{captured.inspect} is not numeric")
      end

      op    = thresh["op"]
      value = thresh["value"]
      unless num.public_send(op, value)
        return Result.new(pass: false, reason: "threshold: #{num} #{op} #{value} is false")
      end

      Result.new(pass: true, reason: "")
    end
  end
end
