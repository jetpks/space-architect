# frozen_string_literal: true

# In-process regression test for falcon.rb's service topology — no ports, no boot.
# Loads falcon.rb the same way `falcon host falcon.rb` does (Async::Service::Configuration.load,
# see falcon/environment/configured.rb) and asserts all four services are present with
# sane container options.
#
# Guards against a value-form `count Integer(ENV.fetch(...))` DSL call: async-service's
# Builder (Environment::Builder < BasicObject, environment.rb) has no Kernel, so bare
# `Integer(...)` at DSL-eval time resolves via Builder#method_missing instead of
# Kernel#Integer — it defines a throwaway `Integer` method on the facet and returns the
# Symbol :Integer, which becomes `count`'s value. That only blows up later, inside
# async-container's `count.times` (NoMethodError) at actual container boot — the rest of
# the suite never boots falcon host, so nothing else catches it.

require_relative "../test_helper"
require "async/service/configuration"

class FalconConfigurationTest < Minitest::Test
  FALCON_RB = File.expand_path("../../falcon.rb", __dir__)
  EXPECTED_SERVICE_NAMES = %w[
    architect.web
    architect.import-worker
    architect.executor-worker
    architect.consumer-worker
  ].freeze

  def test_all_services_present_with_integer_counts
    configuration = Async::Service::Configuration.load([FALCON_RB])
    services = configuration.services.to_a

    assert_equal EXPECTED_SERVICE_NAMES.sort, services.map(&:name).sort

    services.each do |service|
      container_options = service.environment.evaluator.container_options
      next unless container_options.key?(:count)

      assert_kind_of Integer, container_options[:count],
        "#{service.name} container_options[:count] must be an Integer, got #{container_options[:count].inspect}"
    end
  end
end
