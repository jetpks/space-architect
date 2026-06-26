# frozen_string_literal: true

require "pathname"

module Space::Core
  RepoReference = Data.define(:provider, :owner, :name, :clone_url, :source) do
    def full_name
      "#{provider}/#{owner}/#{name}"
    end

    def directory_name
      name
    end

    def src_path(root)
      Pathname.new(root).join(provider, owner, name)
    end
  end
end
