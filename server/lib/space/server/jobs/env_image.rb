# frozen_string_literal: true

require "digest"
require "erb"
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
      # the rendered Dockerfile, or any image layer — only `deps`, `files`, and the
      # sorted `env` KEY NAMES do. Construction takes the CLI-spawn seam so the
      # test suite (and any caller) never has to shell out to the real `container`
      # CLI directly.
      #
      # The spawn seam: any object responding to #call(*argv) and returning
      # [output, status] — output a combined stdout+stderr String, status any
      # object responding to #success? (i.e. Open3.capture2e's own contract, so
      # `Open3.method(:capture2e)` is a valid production seam).
      class EnvImage
        include Dry::Monads[:result]

        DEFAULT_BASE_IMAGE = "debian:stable-slim"
        TEMPLATE_PATH = Pathname.new(__dir__).join("env_image", "dockerfile.erb").freeze

        def initialize(spawn:, base_image: DEFAULT_BASE_IMAGE)
          @spawn = spawn
          @base_image = base_image
        end

        # environment: { env: {K=>V}, secrets: [{ref:, name:}], deps: [String],
        # files: optional String ref, permissions: {network:, mounts:} } — keys may
        # be Strings or Symbols (upstream producers differ: Contracts::CreateJob
        # yields Symbol keys pre-persistence, the jobs.spec jsonb column round-trips
        # String keys), so every lookup below is key-type indifferent.
        def call(environment)
          deps = Array(lookup(environment, :deps))
          tag  = tag_for(deps: deps, files_ref: lookup(environment, :files), env_keys: env_keys(environment),
                          base_image: base_image)

          return Success(tag) if image_exists?(tag)

          build(tag, deps)
        end

        private

        attr_reader :spawn, :base_image

        def lookup(hash, key)
          hash[key] || hash[key.to_s]
        end

        def env_keys(environment)
          (lookup(environment, :env) || {}).keys.map(&:to_s).sort
        end

        # Canonical serialization is a JSON object over exactly the fields that
        # participate in the tag — deps in their given order, the files ref
        # verbatim, env key NAMES sorted, and the base image (two jobs with
        # identical deps/files/env but different base images must never share
        # a cache entry). JSON.generate on a Hash with a fixed key order is
        # deterministic within one Ruby process, which is all a cache tag
        # needs (it does not need to be stable across Ruby versions/GC layouts).
        def tag_for(deps:, files_ref:, env_keys:, base_image:)
          canonical = JSON.generate({ deps: deps, files_ref: files_ref, env_keys: env_keys, base_image: base_image })
          "space-job-env:#{Digest::SHA256.hexdigest(canonical)[0, 12]}"
        end

        def image_exists?(tag)
          _output, status = spawn.call("container", "image", "inspect", tag)
          status.success?
        end

        def build(tag, deps)
          Dir.mktmpdir("space-job-env-") do |dir|
            dockerfile = File.join(dir, "Dockerfile")
            File.write(dockerfile, render_dockerfile(deps))

            output, status = spawn.call("container", "build", "-f", dockerfile, "-t", tag, dir)
            status.success? ? Success(tag) : Failure(output)
          end
        end

        def render_dockerfile(deps)
          ERB.new(TEMPLATE_PATH.read, trim_mode: "-").result(binding)
        end
      end
    end
  end
end
