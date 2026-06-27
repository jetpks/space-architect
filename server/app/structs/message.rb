# frozen_string_literal: true

module Architect
  module Structs
    class Message < Architect::DB::Struct
      # Interface contract: blocks == Array(content) — consumed by lane-02 POROs.
      def blocks
        Array(content)
      end
    end
  end
end
