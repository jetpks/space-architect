# frozen_string_literal: true

module Space
  module Server
    module Structs
      class Job < ::Space::Server::DB::Struct
        def queued?    = status == "queued"
        def running?   = status == "running"
        def succeeded? = status == "succeeded"
        def failed?    = status == "failed"
        def canceled?  = status == "canceled"

        def owned_by?(user)
          !user.nil? && user.id == user_id
        end
      end
    end
  end
end
