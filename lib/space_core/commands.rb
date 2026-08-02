# frozen_string_literal: true

module Space::Core
  module Commands
    module_function

    # Render a multi-flag command with trailing " \" continuations broken at
    # "--flag" boundaries, continuation lines indented two spaces. Commands
    # without "--" flags are returned unchanged.
    def wrap(command)
      parts = split_at_flag_boundaries(command)
      return command if parts.size <= 1

      parts.each_with_index.map do |part, i|
        segment = i.zero? ? part.rstrip : "  #{part.lstrip}"
        i < parts.size - 1 ? "#{segment} \\" : segment
      end.join("\n")
    end

    # Same split points as command.split(/(?= --)/), but blind to " --" that
    # falls inside a single- or double-quoted flag value, so a --title
    # containing " -- " isn't torn apart mid-argument.
    def split_at_flag_boundaries(command)
      parts = []
      start = 0
      in_squote = false
      in_dquote = false
      escaped = false
      command.each_char.with_index do |ch, i|
        if escaped
          escaped = false
          next
        end
        case ch
        # A backslash escapes the next character outside quotes and inside
        # double quotes, but is a literal character inside single quotes.
        when "\\" then escaped = true unless in_squote
        when "'" then in_squote = !in_squote unless in_dquote
        when '"' then in_dquote = !in_dquote unless in_squote
        when " "
          if !in_squote && !in_dquote && command[i + 1, 2] == "--"
            parts << command[start...i]
            start = i
          end
        end
      end
      parts << command[start..]
      parts
    end
  end
end
