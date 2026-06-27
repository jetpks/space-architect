# frozen_string_literal: true

module Architect
  module Structs
    class User < Architect::DB::Struct
      def org_ids
        Array(github_orgs).map { |o| o["id"].to_s }
      end
    end
  end
end
