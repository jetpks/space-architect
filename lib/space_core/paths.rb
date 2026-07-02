# frozen_string_literal: true

module Space::Core
  module Paths
    module_function

    def contract(path, env: ENV)
      value = path.to_s
      home  = XDG.home(env: env)
      [home, realpath_or_nil(home)].compact.uniq.each do |h|
        return "~"  if value == h
        return "~#{value.delete_prefix(h)}" if value.start_with?("#{h}/")
      end
      value
    end

    def realpath_or_nil(path)
      File.realpath(path)
    rescue SystemCallError
      nil
    end
  end
end
