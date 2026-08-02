# frozen_string_literal: true

require "fileutils"
require "pathname"

module Space
  module Architect
    module BugReport
      REPO = "jetpks/space-architect"

      class << self
        def generate(space: nil, env: ENV, cwd: Dir.pwd, now: Time.now, title: nil)
          body_path = resolve_body_path(space, cwd, now)
          FileUtils.mkdir_p(body_path.dirname)
          body = build_body(space, title)
          body_path.write(body)
          contracted = Space::Core::Paths.contract(body_path, env: env)
          title_flag = title ? " --title #{quote_title(title)}" : ""
          command = Space::Core::Commands.wrap(
            %(gh issue create -R #{REPO}#{title_flag} --body-file #{contracted})
          )
          { body_path: body_path, command: command, body: body }
        end

        private

        # Double-quote a title for a POSIX shell: quotes preserve spaces
        # literally, only the characters special inside double quotes are escaped.
        def quote_title(title)
          %("#{title.gsub(/(["\\$`])/) { "\\#{$1}" }}")
        end

        def resolve_body_path(space, cwd, now)
          filename = "architect-bug-report-#{now.strftime('%Y%m%d-%H%M%S')}.md"
          if space
            space.path.join("build", "bug-report", filename)
          else
            Pathname.new(cwd).join(filename)
          end
        end

        def build_body(space, title)
          body = +""
          body << "# #{title}\n\n" if title
          body << template_header
          body << diagnostics_section
          body << space_section(space) if space
          body
        end

        def template_header
          <<~MD
            **Kind:** <!-- process / tooling / both -->

            ## Summary

            <!-- One sentence describing the bug. -->

            ## What happened

            <!-- Describe what you observed. -->

            ## What was expected

            <!-- Describe what you expected to happen. -->

            ## Repro steps

            <!-- Numbered steps to reproduce. -->

          MD
        end

        def diagnostics_section
          <<~MD
            ## Diagnostics

            - space-architect: #{Space::Core::VERSION}
            - ruby: #{RUBY_VERSION} (#{RUBY_PLATFORM})
          MD
        end

        def space_section(space)
          iterations = Array(space.data.dig("project", "iterations"))
          iter_lines = iterations.map do |s|
            nn = format("%02d", s["ordinal"])
            verdict = s["verdict"] || "—"
            "- I#{nn} #{s["name"]} — #{verdict}"
          end.join("\n")

          +"\n## Space context\n\n" \
            "- Space id: #{space.id}\n" \
            "- Space title: #{space.title}\n" \
            "\n### Iterations\n\n" \
            "#{iter_lines.empty? ? "(none)" : iter_lines}\n"
        end
      end
    end
  end
end
