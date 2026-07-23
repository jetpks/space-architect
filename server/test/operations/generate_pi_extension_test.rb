# frozen_string_literal: true

# Minimal bootstrap for the generate_pi_extension unit test — does NOT boot
# Hanami (no DB needed: GeneratePiExtension is a pure render of a plain
# provider-shaped object + a model id list). Mirrors
# test/jobs/executor/sandbox_argv_test.rb's approach for the same reason.
require_relative "../../app/operations/generate_pi_extension"
require "minitest/autorun"

class GeneratePiExtensionTest < Minitest::Test
  Provider = Struct.new(:name, :base_url, :api_key_ref)

  def generator = Space::Server::Operations::GeneratePiExtension.new

  def test_path_is_slugified_provider_name
    result = generator.call(Provider.new("My Gateway!", "https://gw.example.com", nil), [])
    assert_equal "/root/.pi/agent/extensions/my-gateway.ts", result[:path]
  end

  def test_content_registers_provider_with_slug_and_joined_base_url
    result = generator.call(Provider.new("Studio", "https://studio.slush.systems", nil), ["m1"])
    assert_includes result[:content], 'pi.registerProvider("studio", {'
    assert_includes result[:content], 'baseUrl: "https://studio.slush.systems/v1"'
    assert_includes result[:content], 'api: "openai-completions"'
  end

  def test_content_has_one_model_entry_per_fetched_id
    result = generator.call(Provider.new("Studio", "https://studio.slush.systems", nil), ["model-a", "model-b"])
    assert_includes result[:content], 'id: "model-a"'
    assert_includes result[:content], 'id: "model-b"'
  end

  def test_keyless_provider_gets_dummy_api_key_and_nil_env_key
    result = generator.call(Provider.new("Studio", "https://studio.slush.systems", nil), [])
    assert_includes result[:content], 'apiKey: "local-proxy"'
    assert_nil result[:env_key]
  end

  def test_key_bearing_provider_gets_env_indirection
    result = generator.call(Provider.new("Studio", "https://studio.slush.systems", "op://vault/item"), [])
    assert_includes result[:content], "apiKey: process.env.PI_PROVIDER_API_KEY"
    assert_equal "PI_PROVIDER_API_KEY", result[:env_key]
  end

  def test_content_never_contains_the_op_ref
    result = generator.call(Provider.new("Studio", "https://studio.slush.systems", "op://vault/item/field"), [])
    refute_includes result[:content], "op://vault/item/field"
  end

  # pi-coding-agent's ProviderConfigInput has no top-level `compat` — it lives
  # per-model at Model#compat (model-registry.d.ts).
  def test_compat_is_per_model_not_provider_level
    result = generator.call(Provider.new("Studio", "https://studio.slush.systems", nil), ["model-a", "model-b"])
    provider_config, models_config = result[:content].split("models: [", 2)
    refute_includes provider_config, "compat:"
    assert_equal 2, models_config.scan("compat:").size
  end
end
