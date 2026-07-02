# frozen_string_literal: true

require "fileutils"
require "pathname"

module Space
  module Architect
    module BugReport
      REPO = "jetpks/space-architect"

      class << self
        def generate(space: nil, env: ENV, cwd: Dir.pwd, now: Time.now)
          body_path = resolve_body_path(space, cwd, now)
          FileUtils.mkdir_p(body_path.dirname)
          body = build_body(space)
          body_path.write(body)
          contracted = Space::Core::Paths.contract(body_path, env: env)
          command = %(gh issue create -R #{REPO} --title "<one-line summary>" --body-file #{contracted})
          { body_path: body_path, command: command, body: body }
        end

        private

        def resolve_body_path(space, cwd, now)
          filename = "architect-bug-report-#{now.strftime('%Y%m%d-%H%M%S')}.md"
          if space
            space.path.join("build", "bug-report", filename)
          else
            Pathname.new(cwd).join(filename)
          end
        end

        def build_body(space)
          body = +template_header
          body << diagnostics_section
          body << space_section(space) if space
          body
        end

        def template_header
          <<~MD
            <!-- Title: <one-line summary> -->

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
