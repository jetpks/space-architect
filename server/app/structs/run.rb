# frozen_string_literal: true

module Space
  module Server
    module Structs
      class Run < ::Space::Server::DB::Struct
        def pending?  = status == :pending
        def live?     = status == :live
        def complete? = status == :complete
        def failed?   = status == :failed
        def canceled? = status == :canceled

        def published?
          !!published
        end

        def owned_by?(user)
          !user.nil? && user.id == user_id
        end

        def visible_to?(user)
          published? || owned_by?(user)
        end
      end
    end
  end
end
