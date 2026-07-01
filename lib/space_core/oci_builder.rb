# frozen_string_literal: true

require "open3"
require "pathname"
require "dry/monads"

module Space::Core
  class OciBuilder
    include Dry::Monads[:result]

    def initialize(space:, output_dir:)
      @space = space
      @output_dir = Pathname.new(output_dir)
    end

    def version
      compute_version.value!
    end

    def image
      "#{space.id}:#{version}"
    end

    def latest
      "#{space.id}:latest"
    end

    def command
      compute_version.fmap do |ver|
        [
          "container", "build",
          "-f", @output_dir.join("Dockerfile").to_s,
          "-t", "#{space.id}:#{ver}",
          "-t", latest,
          space.path.to_s
        ]
      end
    end

    private

    attr_reader :space

    def compute_version
      sha_out, _, sha_status = Open3.capture3("git", "-C", space.path.to_s, "rev-parse", "--short=12", "HEAD")
      unless sha_status.success?
        return Failure("space is not a git repository with a commit; cannot compute a version tag")
      end

      sha = sha_out.strip
      status_out, _, _ = Open3.capture3("git", "-C", space.path.to_s, "status", "--porcelain")
      dirty = !status_out.strip.empty?
      Success(dirty ? "#{sha}-dirty" : sha)
    end
  end
end
