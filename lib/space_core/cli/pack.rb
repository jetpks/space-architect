# frozen_string_literal: true

require "pathname"
require_relative "../oci_packer"

module Space::Core::CLI
class Pack < BaseCommand
  desc "Generate a portable OCI build context for the current space"
  option :output, aliases: ["-o"], type: :string, default: nil,
         desc: "Output directory (default: build/oci/ under the space root)"

  def call(output: nil, **opts)
    setup_terminal(**opts.slice(:color, :colors))
    handle_errors do
      result = store.current.bind do |space|
        out_dir = output ? Pathname.new(output).expand_path : space.path.join("build", "oci")
        Space::Core::OciPacker.new(space: space, output_dir: out_dir).generate
          .fmap { |dir| { space: space, dir: dir } }
      end
      render(result) do |r|
        terminal.success "Generated OCI context: #{r[:dir]}"
        terminal.say "Build: docker build -f #{r[:dir]}/Dockerfile -t #{r[:space].id}:latest ."
        terminal.say "  (run from: #{r[:space].path})"
        CLI.record_outcome(Outcome.new(exit_code: 0))
      end
    end
  end
end
end
