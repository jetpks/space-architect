# frozen_string_literal: true

require "base64"
require "digest"
require "erb"
require "fileutils"
require "json"
require "pathname"
require "tmpdir"
require "dry/monads"

module Space
  module Server
    module Jobs
      # Turns a job's declared `environment` (Contracts::CreateJob shape) into a
      # content-addressed OCI image tag, building the image only on a cache miss.
      #
      # Environment values, secret refs, and permissions never influence the tag,
      # the rendered Dockerfile, or any image layer — only `debs` (merged with its
      # `deps` back-compat alias), `gems`, `mise`, `npm`, `files`, and the sorted
      # `env` KEY NAMES do. Construction takes the CLI-spawn seam so the test suite
      # (and any caller) never has to shell out to the real `container` CLI
      # directly.
      #
      # The spawn seam: any object responding to #call(*argv) and returning
      # [output, status] — output a combined stdout+stderr String, status any
      # object responding to #success? (i.e. Open3.capture2e's own contract, so
      # `Open3.method(:capture2e)` is a valid production seam).
      #
      # Documented-unsupported: `gems` with no `mise` ruby fails at build time
      # with ruby's own "gem: not found"; a native-ext gem without
      # build-essential (+ headers) declared in `debs` fails with ruby's mkmf
      # message. Neither is guarded against — both are surfaced as an ordinary
      # build failure. `mise` toolchain entries are resolved to their latest
      # matching patch level at build time and are not pinned.
      class EnvImage
        include Dry::Monads[:result]

        DEFAULT_BASE_IMAGE = "debian:stable-slim"
        TEMPLATE_PATH = Pathname.new(__dir__).join("env_image", "dockerfile.erb").freeze

        # Pulled onto the apt layer ahead of `debs` whenever `mise` is declared —
        # mise's bootstrap script needs curl/ca-certificates, and some of its tool
        # backends shell out to git.
        MISE_BOOTSTRAP_DEBS = %w[curl ca-certificates git].freeze

        def initialize(spawn:, base_image: DEFAULT_BASE_IMAGE)
          @spawn = spawn
          @base_image = base_image
        end

        # environment: { env: {K=>V}, secrets: [{ref:, name:}], deps: [String],
        # debs: [String], gems: [String], mise: [String], npm: [String],
        # files: [{path:, content_b64:}], permissions: {network:, mounts:} } —
        # keys may be Strings or Symbols (upstream producers differ:
        # Contracts::CreateJob yields Symbol keys pre-persistence, the jobs.spec
        # jsonb column round-trips String keys), so every lookup below is
        # key-type indifferent.
        def call(environment)
          debs  = Array(lookup(environment, :debs)) + Array(lookup(environment, :deps))
          gems  = Array(lookup(environment, :gems))
          mise  = Array(lookup(environment, :mise))
          npm   = Array(lookup(environment, :npm))
          files = normalize_files(lookup(environment, :files))
          tag   = tag_for(debs: debs, gems: gems, mise: mise, npm: npm, files: files,
                           env_keys: env_keys(environment), base_image: base_image)

          return Success(tag) if image_exists?(tag)

          build(tag, debs: debs, gems: gems, mise: mise, npm: npm, files: files)
        end

        private

        attr_reader :spawn, :base_image

        def lookup(hash, key)
          hash[key] || hash[key.to_s]
        end

        def env_keys(environment)
          (lookup(environment, :env) || {}).keys.map(&:to_s).sort
        end

        # Key-type-indifferent, same reasoning as #lookup — a files[] entry may
        # arrive Symbol-keyed (fresh from the contract) or String-keyed (jsonb
        # round-trip), but never mixed within one entry.
        def normalize_files(files)
          Array(files).map { |f| { path: lookup(f, :path), content_b64: lookup(f, :content_b64) } }
        end

        # Canonical serialization is a JSON object over exactly the fields that
        # participate in the tag — debs (the deps-alias-merged list)/gems/mise/npm
        # in their given order, files (path + content, so a changed file changes
        # the tag) in their given order, env key NAMES sorted, and the base image
        # (two jobs with identical debs/gems/mise/npm/files/env but different base
        # images must never share a cache entry). deps: ["x"] and debs: ["x"]
        # merge to the same debs list, so they yield the same tag. JSON.generate
        # on a Hash with a fixed key order is deterministic within one Ruby
        # process, which is all a cache tag needs (it does not need to be stable
        # across Ruby versions/GC layouts).
        def tag_for(debs:, gems:, mise:, npm:, files:, env_keys:, base_image:)
          canonical = JSON.generate({ debs: debs, gems: gems, mise: mise, npm: npm, files: files,
                                       env_keys: env_keys, base_image: base_image })
          "space-job-env:#{Digest::SHA256.hexdigest(canonical)[0, 12]}"
        end

        def image_exists?(tag)
          _output, status = spawn.call("container", "image", "inspect", tag)
          status.success?
        end

        def build(tag, debs:, gems:, mise:, npm:, files:)
          Dir.mktmpdir("space-job-env-") do |dir|
            write_files(dir, files)
            dockerfile = File.join(dir, "Dockerfile")
            File.write(dockerfile, render_dockerfile(debs: debs, gems: gems, mise: mise, npm: npm, files: files))

            output, status = spawn.call("container", "build", "-f", dockerfile, "-t", tag, dir)
            status.success? ? Success(tag) : Failure(output)
          end
        end

        # Decoded bytes are staged under <build-context>/files/<index> and pulled
        # into the image with COPY (see dockerfile.erb) rather than a RUN +
        # base64-decode step — content never transits a shell command line, and
        # COPY needs no base64/mkdir tooling present in the base image before any
        # deps layer has run.
        def write_files(dir, files)
          return if files.empty?

          files_dir = File.join(dir, "files")
          FileUtils.mkdir_p(files_dir)
          files.each_with_index do |f, i|
            File.binwrite(File.join(files_dir, i.to_s), Base64.decode64(f[:content_b64]))
          end
        end

        def render_dockerfile(debs:, gems:, mise:, npm:, files:)
          apt_debs = (mise.any? ? MISE_BOOTSTRAP_DEBS + debs : debs).uniq
          ERB.new(TEMPLATE_PATH.read, trim_mode: "-").result(binding)
        end
      end
    end
  end
end
