# frozen_string_literal: true

require_relative "../oci_packer"
require_relative "../oci_builder"

module Space::Core::CLI
class Build < BaseCommand
  desc "Build (and tag) the OCI image for the current space"

  def call(**opts)
    setup_terminal(**opts.slice(:color, :colors))
    handle_errors do
      result = store.current.bind do |space|
        out_dir = space.path.join("build", "oci")
        Space::Core::OciPacker.new(space: space, output_dir: out_dir).generate.bind do
          Space::Core::OciBuilder.new(space: space, output_dir: out_dir).command
        end
      end
      render(result) do |argv|
        terminal.say "Building: #{argv.join(' ')}"
        out.flush
        Kernel.exec(*argv)
      end
    end
  end
end
end
