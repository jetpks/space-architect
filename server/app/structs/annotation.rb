# frozen_string_literal: true

module Architect
  module Structs
    class Annotation < Architect::DB::Struct
      def owned_by?(user)
        !user.nil? && user.id == user_id
      end
    end
  end
end
