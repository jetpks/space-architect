# frozen_string_literal: true

require_relative "inertia_hanami/version"
require_relative "inertia_hanami/config"
require_relative "inertia_hanami/middleware"
require_relative "inertia_hanami/renderer"
require_relative "inertia_hanami/action"

module InertiaHanami
  class << self
    def configuration
      @configuration ||= Config.new
    end

    def configure
      yield configuration
    end

    def reset_configuration!
      @configuration = Config.new
    end
  end
end
