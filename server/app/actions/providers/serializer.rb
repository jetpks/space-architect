# frozen_string_literal: true

module Space
  module Server
    module Actions
      module Providers
        # The frozen `providers` prop shape (BRIEF I23 shape 1), shared by
        # Providers::Index, Jobs::New and Profiles::New.
        module Serializer
          def self.call(providers)
            providers.map do |provider|
              { id: provider.id, name: provider.name, base_url: provider.base_url,
                api_key_ref: provider.api_key_ref, flavors: provider.flavors }
            end
          end
        end
      end
    end
  end
end
