# frozen_string_literal: true

module Space
  module Server
    module Structs
      class Profile < ::Space::Server::DB::Struct
        def owned_by?(user)
          !user.nil? && user.id == user_id
        end
      end
    end
  end
end
