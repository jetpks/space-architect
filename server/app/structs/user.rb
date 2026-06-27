# frozen_string_literal: true

module Space
  module Server
    module Structs
      class User < Space::Server::DB::Struct
        def org_ids
          Array(github_orgs).map { |o| o["id"].to_s }
        end
      end
    end
  end
end
