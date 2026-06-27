# frozen_string_literal: true

require "dry/cli"

# dry-cli (1.4.x) treats `type: :array` options as comma-separated and OVERWRITES
# on each occurrence, so `-r a -r b` yields ["b"]. We want repeated flags to
# accumulate (`-r a -r b -r c` => ["a", "b", "c"]) the way git/docker-style CLIs
# do, while still accepting the comma form. dry-cli exposes no hook for this, so
# we reopen two private seams, each mirroring dry-cli 1.4.1 with a single change:
#
#   * Parser.call                  — concat instead of assign for array options.
#   * Banner.extended_command_options — drop the "=VALUE1,VALUE2,.." hint that
#     advertised the comma form as the only way; show the plain repeatable flag,
#     matching how you actually type it (-r VALUE).
#
# These mirror the released 1.4.1 source EXACTLY (not the dry-rb main branch,
# which already differs). Pinned via `~> 1.4`; if a future dry-cli reworks these
# methods, repeatable_options_test goes red and we re-sync. Rationale:
# notes/ruby-cli-gems-report.md.
module Dry
  class CLI
    module Parser
      def self.call(command, arguments, prog_name)
        original_arguments = arguments.dup
        parsed_options = {}

        OptionParser.new do |opts|
          command.options.each do |option|
            opts.on(*option.parser_options) do |value|
              if option.array?
                (parsed_options[option.name.to_sym] ||= []).concat(value)
              else
                parsed_options[option.name.to_sym] = value
              end
            end
          end

          opts.on_tail("-h", "--help") do
            return Result.help
          end
        end.parse!(arguments)

        parsed_options = command.default_params.merge(parsed_options)
        parse_required_params(command, arguments, prog_name, parsed_options)
      rescue ::OptionParser::ParseError, ValueError
        Result.failure("ERROR: \"#{prog_name}\" was called with arguments \"#{original_arguments.join(" ")}\"")
      end
    end

    module Banner
      def self.extended_command_options(command)
        result = command.options.map do |option|
          name = Inflector.dasherize(option.name)
          name = if option.boolean?
                   "[no-]#{name}"
                 elsif option.flag?
                   name
                 else
                   # array options included: repeated flags accumulate, so show
                   # the single repeatable form rather than "=VALUE1,VALUE2,..".
                   "#{name}=VALUE"
                 end
          name = "#{name}, #{option.alias_names.join(", ")}" if option.aliases.any?
          name = "  --#{name.ljust(30)}"
          name = "#{name}  # #{option.desc}"
          name = "#{name}, default: #{option.default.inspect}" unless option.default.nil?
          name
        end

        result << "  --#{"help, -h".ljust(30)}  # Print this help"
        result.join("\n")
      end
    end
  end
end
