# frozen_string_literal: true

require "dry/struct"
require "dry/types"

module Space::Src
  module UI
    Types = Dry.Types()

    # Resolved output mode — immutable dry-struct constructed once per command
    # invocation from (flags, env, out.tty?) using precedence: flag > env > autodetect.
    #
    # Frozen contract (PRD §3.1):
    #
    #   format:  :pretty | :plain | :json
    #   color:   true | false
    #   animate: true | false  (always false in Slice A; Slice B gates on this)
    #   quiet:   true | false
    #
    # Color precedence: --no-color (flag) > CLICOLOR_FORCE (env-force) >
    #   NO_COLOR/TERM=dumb/non-:pretty/non-TTY (env+autodetect).
    class Mode < Dry::Struct
      FORMATS = %i[pretty plain json].freeze

      attribute :color, Types::Bool
      attribute :animate, Types::Bool
      attribute :quiet, Types::Bool
      attribute :format, Types::Symbol.constrained(included_in: FORMATS)

      # @param flags [Hash] CLI flags: :plain, :json, :no_color, :quiet (truthy = set)
      # @param env   [Hash] environment hash (use CLI.env for the injectable test seam)
      # @param out   [IO]  the output stream; tested with out.tty?
      def self.resolve(flags:, env:, out:)
        json = !!flags[:json]
        plain = !!flags[:plain]
        no_color = !!flags[:no_color]
        quiet = !!flags[:quiet]

        format = if json
          :json
        elsif plain || !out.tty?
          :plain
        else
          :pretty
        end

        no_color_env = env["NO_COLOR"] && !env["NO_COLOR"].empty?
        clicolor_force = env["CLICOLOR_FORCE"] && !env["CLICOLOR_FORCE"].empty?
        term_dumb = env["TERM"] == "dumb"

        color = if no_color
          false
        elsif clicolor_force
          true
        elsif no_color_env || term_dumb || format != :pretty || !out.tty?
          false
        else
          true
        end

        ci = env["CI"] && !env["CI"].empty?
        animate = format == :pretty && out.tty? && !quiet && !ci

        new(color: color, animate: animate, quiet: quiet, format: format)
      end
    end
  end
end
