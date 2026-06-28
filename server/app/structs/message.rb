# frozen_string_literal: true

module Space
  module Server
    module Structs
      class Message < ::Space::Server::DB::Struct
        # Interface contract: blocks == Array(content) — consumed by lane-02 POROs.
        def blocks
          Array(content)
        end
      end
    end
  end
end
