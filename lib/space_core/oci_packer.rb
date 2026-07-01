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
      validated = validate_provision_scripts(space.provision_scripts)
      return validated if validated.failure?
      validated = validate_persist_paths(space.persist_paths)
      return validated if validated.failure?
      write("Dockerfile",    render_template("dockerfile.erb"))
      write("entrypoint.sh", entrypoint_content, mode: 0o755)
      write("Dockerfile.dockerignore", render_template("dockerignore.erb"))
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

    def provision_scripts
      @space.provision_scripts
    end

    def persist_paths
      @space.persist_paths
    end

    def validate_provision_scripts(scripts)
      scripts.each do |rel_path|
        if Pathname.new(rel_path).absolute?
          return Failure("provision script '#{rel_path}' must not be an absolute path")
        end

        resolved = space.path.join(rel_path).cleanpath
        space_root = space.path.cleanpath
        unless resolved.to_s.start_with?("#{space_root}/") || resolved == space_root
          return Failure("provision script '#{rel_path}' escapes the space root")
        end

        return Failure("provision script '#{rel_path}' does not exist under the space root") unless resolved.exist?
      end
      Success(scripts)
    end

    def validate_persist_paths(paths)
      paths.each do |path|
        unless Pathname.new(path).absolute?
          return Failure("persist path '#{path}' must be an absolute path")
        end
      end
      Success(paths)
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
