# frozen_string_literal: true

module SpaceArchitect
  module Slugger
    module_function

    def slug(value)
      slug = value.to_s.downcase.strip
                  .gsub(/[^a-z0-9]+/, "-")
                  .gsub(/\A-+|-+\z/, "")
                  .gsub(/-+/, "-")

      slug.empty? ? "space" : slug
    end
  end
end
