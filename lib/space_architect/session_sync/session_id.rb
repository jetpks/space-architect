# frozen_string_literal: true

module Space::Architect
  module SessionSync
    # Frozen session-id derivation rules for the two store shapes:
    #   pi:     <mangled-cwd>/<timestamp>_<sessionId>.jsonl -> part after the last "_"
    #   claude: <mangled-cwd>/<sessionId>.jsonl             -> basename minus ".jsonl"
    module SessionId
      def self.for_pi(path)
        base = File.basename(path, ".jsonl")
        idx = base.rindex("_")
        idx ? base[(idx + 1)..] : base
      end

      def self.for_claude(path)
        File.basename(path, ".jsonl")
      end
    end
  end
end
