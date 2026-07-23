# frozen_string_literal: true

# Minimal bootstrap for the env_image unit test — does NOT boot Hanami (no DB
# needed: EnvImage's only collaborator is the injected CLI-spawn seam, faked
# below). Mirrors test/runs/support.rb's approach for the same reason.
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "base64"
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
    attr_reader :calls, :dockerfiles, :materialized_files

    def initialize(exists: false, build_ok: true, build_output: "")
      @exists = exists
      @build_ok = build_ok
      @build_output = build_output
      @calls = []
      @dockerfiles = []
      @materialized_files = []
    end

    # Snapshots the Dockerfile and any files/<i> content while the build
    # context tmpdir still exists — #call runs synchronously inside
    # EnvImage's Dir.mktmpdir block, which deletes the dir once this returns.
    def call(*argv)
      @calls << argv
      if argv[1] == "build"
        @dockerfiles << File.read(argv[argv.index("-f") + 1])
        files_dir = File.join(argv.last, "files")
        @materialized_files << (Dir.exist?(files_dir) ? Dir.children(files_dir).sort.to_h { |f| [f, File.binread(File.join(files_dir, f))] } : {})
        [@build_output, FakeStatus.new(@build_ok)]
      else
        ["", FakeStatus.new(@exists)]
      end
    end

    def build_calls = @calls.select { |argv| argv[1] == "build" }

    def materialized_file(index) = materialized_files.last.fetch(index.to_s)
  end

  def env(overrides = {})
    { env: { "FOO" => "bar" }, deps: ["git"] }.merge(overrides)
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
    sym_env = { env: { FOO: "bar" }, deps: ["git"], npm: ["cowsay"],
                files: [{ path: "/root/x", content_b64: "Zm9v" }] }
    string_env = { "env" => { "FOO" => "bar" }, "deps" => ["git"], "npm" => ["cowsay"],
                   "files" => [{ "path" => "/root/x", "content_b64" => "Zm9v" }] }
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
    assert_match(/\AFROM space-claude-base:v1/, dockerfile)
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

  # --- npm layer -----------------------------------------------------------

  def test_no_npm_layer_when_npm_absent
    spawn = FakeSpawn.new(exists: false)
    image(spawn).call(env)
    refute_match(/npm install/, spawn.dockerfiles.first)
  end

  def test_npm_layer_present_when_npm_specified
    spawn = FakeSpawn.new(exists: false)
    image(spawn).call(env(npm: ["cowsay", "left-pad"]))
    dockerfile = spawn.dockerfiles.first
    assert_match(/RUN npm install -g/, dockerfile)
    assert_match(/cowsay/, dockerfile)
    assert_match(/left-pad/, dockerfile)
  end

  def test_changed_npm_changes_tag
    tag_a = image(FakeSpawn.new(exists: true)).call(env).value!
    tag_b = image(FakeSpawn.new(exists: true)).call(env(npm: ["cowsay"])).value!
    refute_equal tag_a, tag_b
  end

  # --- files layer -----------------------------------------------------------

  def test_no_files_layer_when_files_absent
    spawn = FakeSpawn.new(exists: false)
    image(spawn).call(env)
    refute_match(/COPY/, spawn.dockerfiles.first)
  end

  def test_files_layer_materializes_file_at_its_absolute_path_with_content_intact
    spawn = FakeSpawn.new(exists: false)
    content = "export const extension = {}\n"
    files = [{ path: "/root/.pi/agent/extensions/local-inference.ts", content_b64: Base64.strict_encode64(content) }]
    image(spawn).call(env(files: files))

    dockerfile = spawn.dockerfiles.first
    assert_match(%r{COPY files/0 /root/\.pi/agent/extensions/local-inference\.ts}, dockerfile)
    assert_equal content, spawn.materialized_file(0)
  end

  def test_changed_file_content_changes_tag
    files_a = [{ path: "/root/x", content_b64: Base64.strict_encode64("one") }]
    files_b = [{ path: "/root/x", content_b64: Base64.strict_encode64("two") }]
    tag_a = image(FakeSpawn.new(exists: true)).call(env(files: files_a)).value!
    tag_b = image(FakeSpawn.new(exists: true)).call(env(files: files_b)).value!
    refute_equal tag_a, tag_b
  end

  def test_unchanged_npm_and_files_keep_tag_stable
    files = [{ path: "/root/x", content_b64: Base64.strict_encode64("same") }]
    tag_a = image(FakeSpawn.new(exists: true)).call(env(npm: ["cowsay"], files: files)).value!
    tag_b = image(FakeSpawn.new(exists: true)).call(env(npm: ["cowsay"], files: files)).value!
    assert_equal tag_a, tag_b
  end

  # --- debs / deps alias -----------------------------------------------------

  def test_deps_and_debs_yield_the_same_tag
    tag_deps = image(FakeSpawn.new(exists: true)).call(env(deps: ["jq"])).value!
    tag_debs = image(FakeSpawn.new(exists: true)).call(env.reject { |k, _| k == :deps }.merge(debs: ["jq"])).value!
    assert_equal tag_deps, tag_debs
  end

  def test_deps_and_debs_are_merged_into_the_apt_layer
    spawn = FakeSpawn.new(exists: false)
    image(spawn).call(env(deps: ["git"]).merge(debs: ["jq"]))
    dockerfile = spawn.dockerfiles.first
    assert_match(/git/, dockerfile)
    assert_match(/jq/, dockerfile)
  end

  def test_changed_debs_changes_tag
    tag_a = image(FakeSpawn.new(exists: true)).call(env).value!
    tag_b = image(FakeSpawn.new(exists: true)).call(env.merge(debs: ["jq"])).value!
    refute_equal tag_a, tag_b
  end

  # --- gems layer --------------------------------------------------------

  def test_no_gems_layer_when_gems_absent
    spawn = FakeSpawn.new(exists: false)
    image(spawn).call(env)
    refute_match(/gem install/, spawn.dockerfiles.first)
  end

  def test_gems_layer_present_when_gems_specified
    spawn = FakeSpawn.new(exists: false)
    image(spawn).call(env(gems: ["rspec", "rubocop"]))
    dockerfile = spawn.dockerfiles.first
    assert_match(/RUN gem install --no-document/, dockerfile)
    assert_match(/rspec/, dockerfile)
    assert_match(/rubocop/, dockerfile)
  end

  def test_changed_gems_changes_tag
    tag_a = image(FakeSpawn.new(exists: true)).call(env).value!
    tag_b = image(FakeSpawn.new(exists: true)).call(env(gems: ["rspec"])).value!
    refute_equal tag_a, tag_b
  end

  # --- mise layer --------------------------------------------------------

  def test_no_mise_layer_when_mise_absent
    spawn = FakeSpawn.new(exists: false)
    image(spawn).call(env)
    dockerfile = spawn.dockerfiles.first
    refute_match(/mise/, dockerfile)
  end

  def test_mise_layer_present_when_mise_specified
    spawn = FakeSpawn.new(exists: false)
    image(spawn).call(env(mise: ["ruby@3.3", "node@22"]))
    dockerfile = spawn.dockerfiles.first
    assert_match(%r{RUN curl -fsSL https://mise\.run \| sh}, dockerfile)
    assert_match(/ENV PATH="\/root\/\.local\/bin:\/root\/\.local\/share\/mise\/shims:\$PATH"/, dockerfile)
    assert_match(/mise settings ruby\.compile=false/, dockerfile)
    assert_match(/mise use -g/, dockerfile)
    assert_match(/ruby@3\.3/, dockerfile)
    assert_match(/node@22/, dockerfile)
  end

  def test_mise_bootstrap_debs_present_in_apt_layer_only_when_mise_declared
    spawn = FakeSpawn.new(exists: false)
    image(spawn).call(env.reject { |k, _| k == :deps }.merge(mise: ["ruby@3.3"]))
    apt_layer = spawn.dockerfiles.first[/RUN apt-get.*?rm -rf \/var\/lib\/apt\/lists\/\*/m]
    assert_match(/curl/, apt_layer)
    assert_match(/ca-certificates/, apt_layer)
    assert_match(/git/, apt_layer)
  end

  def test_no_apt_bootstrap_when_mise_absent_and_debs_empty
    spawn = FakeSpawn.new(exists: false)
    image(spawn).call(env.reject { |k, _| k == :deps })
    refute_match(/apt-get/, spawn.dockerfiles.first)
  end

  def test_changed_mise_changes_tag
    tag_a = image(FakeSpawn.new(exists: true)).call(env).value!
    tag_b = image(FakeSpawn.new(exists: true)).call(env(mise: ["ruby@3.3"])).value!
    refute_equal tag_a, tag_b
  end

  # --- layer order ---------------------------------------------------------

  def test_layer_order_is_apt_then_mise_then_gems_then_npm_then_files
    spawn = FakeSpawn.new(exists: false)
    files = [{ path: "/root/x", content_b64: Base64.strict_encode64("hi") }]
    image(spawn).call(env(deps: ["git"], mise: ["ruby@3.3"], gems: ["rspec"], npm: ["cowsay"], files: files))
    dockerfile = spawn.dockerfiles.first

    apt_i   = dockerfile.index("apt-get")
    mise_i  = dockerfile.index("mise.run")
    gems_i  = dockerfile.index("gem install")
    npm_i   = dockerfile.index("npm install")
    files_i = dockerfile.index("COPY")

    assert_operator apt_i, :<, mise_i
    assert_operator mise_i, :<, gems_i
    assert_operator gems_i, :<, npm_i
    assert_operator npm_i, :<, files_i
  end

  def test_debs_npm_files_only_environment_renders_todays_shape
    spawn = FakeSpawn.new(exists: false)
    files = [{ path: "/root/x", content_b64: Base64.strict_encode64("hi") }]
    image(spawn).call(env(deps: ["git"], npm: ["cowsay"], files: files))
    dockerfile = spawn.dockerfiles.first

    assert_match(/\AFROM space-claude-base:v1/, dockerfile)
    assert_match(/RUN apt-get update -qq/, dockerfile)
    assert_match(/RUN npm install -g/, dockerfile)
    assert_match(/COPY files\/0/, dockerfile)
    refute_match(/mise/, dockerfile)
    refute_match(/gem install/, dockerfile)
  end
end
