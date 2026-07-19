# frozen_string_literal: true

# Minimal bootstrap for the env_image unit test — does NOT boot Hanami (no DB
# needed: EnvImage's only collaborator is the injected CLI-spawn seam, faked
# below). Mirrors test/runs/support.rb's approach for the same reason.
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "space/server/jobs/env_image"
require "minitest/autorun"

class EnvImageTest < Minitest::Test
  FakeStatus = Struct.new(:ok) do
    alias_method :success?, :ok
  end

  # Records every argv it's called with. Existence checks ("image" "inspect")
  # answer `exists`; build calls ("build") answer `build_ok`/`build_output` and
  # snapshot the rendered Dockerfile — read while it still exists on disk,
  # i.e. from inside this call, since EnvImage's Dir.mktmpdir block is still
  # open at the point it invokes the spawn seam.
  class FakeSpawn
    attr_reader :calls, :dockerfiles

    def initialize(exists: false, build_ok: true, build_output: "")
      @exists = exists
      @build_ok = build_ok
      @build_output = build_output
      @calls = []
      @dockerfiles = []
    end

    def call(*argv)
      @calls << argv
      if argv[1] == "build"
        @dockerfiles << File.read(argv[argv.index("-f") + 1])
        [@build_output, FakeStatus.new(@build_ok)]
      else
        ["", FakeStatus.new(@exists)]
      end
    end

    def build_calls = @calls.select { |argv| argv[1] == "build" }
  end

  def env(overrides = {})
    { env: { "FOO" => "bar" }, deps: ["git"], files: "sha256:abc" }.merge(overrides)
  end

  def image(spawn) = Space::Server::Jobs::EnvImage.new(spawn: spawn)

  def test_tag_shape
    tag = image(FakeSpawn.new(exists: true)).call(env).value!
    assert_match(/\Aspace-job-env:[0-9a-f]{12}\z/, tag)
  end

  def test_same_environment_produces_same_tag
    tag_a = image(FakeSpawn.new(exists: true)).call(env).value!
    tag_b = image(FakeSpawn.new(exists: true)).call(env).value!
    assert_equal tag_a, tag_b
  end

  def test_changed_deps_changes_tag
    tag_a = image(FakeSpawn.new(exists: true)).call(env).value!
    tag_b = image(FakeSpawn.new(exists: true)).call(env(deps: ["git", "curl"])).value!
    refute_equal tag_a, tag_b
  end

  def test_changed_env_values_keeps_same_tag
    tag_a = image(FakeSpawn.new(exists: true)).call(env).value!
    tag_b = image(FakeSpawn.new(exists: true)).call(env(env: { "FOO" => "a-totally-different-value" })).value!
    assert_equal tag_a, tag_b
  end

  def test_string_and_symbol_keyed_environment_agree
    sym_env    = { env: { FOO: "bar" }, deps: ["git"], files: "sha256:abc" }
    string_env = { "env" => { "FOO" => "bar" }, "deps" => ["git"], "files" => "sha256:abc" }
    tag_a = image(FakeSpawn.new(exists: true)).call(sym_env).value!
    tag_b = image(FakeSpawn.new(exists: true)).call(string_env).value!
    assert_equal tag_a, tag_b
  end

  def test_skips_build_on_hit
    spawn  = FakeSpawn.new(exists: true)
    result = image(spawn).call(env)
    assert result.success?
    assert_empty spawn.build_calls
  end

  def test_builds_on_miss
    spawn  = FakeSpawn.new(exists: false)
    result = image(spawn).call(env)
    assert result.success?
    assert_equal 1, spawn.build_calls.size
    assert_equal result.value!, spawn.build_calls.first[5]  # ["container","build","-f",path,"-t",TAG,dir]
  end

  def test_build_failure_returns_failure_with_log_and_never_retries
    spawn  = FakeSpawn.new(exists: false, build_ok: false, build_output: "gcc: error: missing package\n")
    result = image(spawn).call(env)
    assert result.failure?
    assert_equal "gcc: error: missing package\n", result.failure
    assert_equal 1, spawn.build_calls.size
  end

  def test_secret_shaped_env_value_excluded_from_digest_and_dockerfile
    secret = "sk-live-supersecret-token-12345"

    spawn_a = FakeSpawn.new(exists: false)
    tag_with_secret = image(spawn_a).call(env(env: { "OPENAI_API_KEY" => secret })).value!

    spawn_b = FakeSpawn.new(exists: false)
    tag_without_secret = image(spawn_b).call(env(env: { "OPENAI_API_KEY" => "harmless" })).value!

    assert_equal tag_with_secret, tag_without_secret, "an env VALUE must never affect the tag"
    refute_includes spawn_a.dockerfiles.first, secret
  end

  def test_dockerfile_uses_default_base_image_and_a_deps_layer
    spawn = FakeSpawn.new(exists: false)
    image(spawn).call(env(deps: ["git", "curl"]))
    dockerfile = spawn.dockerfiles.first
    assert_match(/\AFROM debian:stable-slim/, dockerfile)
    assert_match(/git/, dockerfile)
    assert_match(/curl/, dockerfile)
  end

  def test_configurable_base_image
    spawn = FakeSpawn.new(exists: false)
    Space::Server::Jobs::EnvImage.new(spawn: spawn, base_image: "alpine:3.20").call(env)
    assert_match(/\AFROM alpine:3.20/, spawn.dockerfiles.first)
  end

  def test_changed_base_image_changes_tag
    tag_a = Space::Server::Jobs::EnvImage.new(spawn: FakeSpawn.new(exists: true)).call(env).value!
    tag_b = Space::Server::Jobs::EnvImage.new(spawn: FakeSpawn.new(exists: true), base_image: "alpine:3.20").call(env).value!
    refute_equal tag_a, tag_b
  end

  def test_same_base_image_keeps_tag_stable
    tag_a = Space::Server::Jobs::EnvImage.new(spawn: FakeSpawn.new(exists: true), base_image: "alpine:3.20").call(env).value!
    tag_b = Space::Server::Jobs::EnvImage.new(spawn: FakeSpawn.new(exists: true), base_image: "alpine:3.20").call(env).value!
    assert_equal tag_a, tag_b
  end
end
