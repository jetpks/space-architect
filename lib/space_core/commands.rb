# frozen_string_literal: true

module Space::Core
  module Commands
    module_function

    # Render a multi-flag command with trailing " \" continuations broken at
    # "--flag" boundaries, continuation lines indented two spaces. Commands
    # without "--" flags are returned unchanged.
    def wrap(command)
      parts = command.split(/(?= --)/)
      return command if parts.size <= 1

      parts.each_with_index.map do |part, i|
        segment = i.zero? ? part.rstrip : "  #{part.lstrip}"
        i < parts.size - 1 ? "#{segment} \\" : segment
      end.join("\n")
    end
  end
end
