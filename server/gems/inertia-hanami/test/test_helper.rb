# frozen_string_literal: true

require "minitest/autorun"
require "rack/mock"
require "rack/lint"
require "json"
require "inertia_hanami"

# Reset global config between test classes that configure it
module InertiaConfigReset
  def setup
    InertiaHanami.reset_configuration!
    super
  end
end
