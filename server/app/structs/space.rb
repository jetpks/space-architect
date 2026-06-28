# frozen_string_literal: true

module Space
  module Server
    module Structs
      class Space < ::Space::Server::DB::Struct
        def owned_by?(user)
          !user.nil? && user.id == user_id
        end

        def visible_to?(user)
          owned_by?(user)
        end
      end
    end
  end
end
