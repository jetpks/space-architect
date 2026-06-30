# frozen_string_literal: true

require "erb"
require "fileutils"
require "pathname"
require "dry/monads"

module Space::Core
  class OciPacker
    include Dry::Monads[:result]

    TEMPLATE_DIR = Pathname.new(__dir__).join("templates", "oci").freeze

    def initialize(space:, output_dir:)
      @space = space
      @output_dir = Pathname.new(output_dir)
    end

    def generate
      FileUtils.mkdir_p(@output_dir)
      write("Dockerfile",    render_template("dockerfile.erb"))
      write("entrypoint.sh", entrypoint_content, mode: 0o755)
      write(".dockerignore", render_template("dockerignore.erb"))
      Success(@output_dir)
    rescue StandardError => e
      Failure(e)
    end

    private

    attr_reader :space, :output_dir

    def space_id
      @space.id
    end

    def repos
      @space.repos
    end

    def entrypoint_content
      @entrypoint_content ||= render_template("entrypoint.sh.erb")
    end

    def entrypoint_b64
      [entrypoint_content].pack("m0")
    end

    def render_template(name)
      template_path = TEMPLATE_DIR.join(name)
      ERB.new(template_path.read, trim_mode: "-").result(binding)
    end

    def write(filename, content, mode: 0o644)
      path = @output_dir.join(filename)
      File.write(path, content)
      File.chmod(mode, path)
      path
    end
  end
end
