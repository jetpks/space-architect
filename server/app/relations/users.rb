# frozen_string_literal: true

module Architect
  module Relations
    class Users < Architect::DB::Relation
      schema(:users, infer: true) do
        associations do
          has_many :conversations
          has_many :annotations
        end
      end
    end
  end
end
