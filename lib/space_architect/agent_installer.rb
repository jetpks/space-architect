# frozen_string_literal: true

require "open3"

module Space
  module Architect
    # Installs the role playbooks (architect-spec/builder/judge/narrator) to
    # ~/.pi/agent/agents and removes a stale architect-coordinator.md left by a
    # pre-driver-era install (I10: the coordinator role retired — the architect
    # session itself drives the loop). The playbook text is rendered by the
    # installed architect-loop extension itself — the extension owns that text
    # (it renders the per-space .pi/agents files from the same source), so this
    # installer carries no second copy to drift. Routing pins come from the
    # global architect.yaml (ENV["SPACE_ARCHITECT_GLOBAL_CONFIG"] overrides the
    # path, honored inside the extension): the user-level files are the
    # machine-wide fallback for sessions that cannot see a space's .pi dir;
    # a space's own .pi/agents files always win inside that space.
    module AgentInstaller
      ROLES = %w[spec builder judge narrator].freeze

      # Renders each role's agent file and prints it between ===FILE===<role>
      # markers. Dynamic import (node -e runs CJS; import() is legal there) so
      # the .ts source — type-stripped by node — loads with its own package's
      # node_modules. The scratch startDir forces global-only routing.
      RENDER_SCRIPT = <<~JS
        const { pathToFileURL } = require("node:url");
        const fs = require("node:fs"), os = require("node:os"), path = require("node:path");
        import(pathToFileURL(process.argv[1]).href).then(({ renderAgentFile, resolveConfig }) => {
          const config = resolveConfig(fs.mkdtempSync(path.join(os.tmpdir(), "architect-agents-")), {});
          if (!config) {
            console.error("no architect.yaml found — run `architect routing init --global` to scaffold the machine-wide config first");
            process.exit(1);
          }
          for (const role of ["spec", "builder", "judge", "narrator"]) {
            console.log("===FILE===" + role);
            console.log(renderAgentFile(role, config));
          }
        }).catch((error) => {
          console.error(error && error.message ? error.message : String(error));
          process.exit(1);
        });
      JS

      class << self
        def install(env: ENV, force: false, dry_run: false, dest: nil, extension_dir: nil)
          source = extension_dir ? Pathname.new(extension_dir).join("architect-loop.ts") : locate_extension(env)
          unless source&.exist?
            raise Space::Core::Error,
                  "architect-loop.ts not found under #{search_root(env)} — run `architect install-extensions` first " \
                  "(install-agents renders its playbooks from the installed extension)"
          end

          dest ||= default_dest(env)
          rendered = render_via_node(source, env)
          results = ROLES.map do |role|
            write_agent(dest.join("architect-#{role}.md"), rendered.fetch(role), force: force, dry_run: dry_run)
          end
          results.concat(remove_stale_coordinator(dest, dry_run: dry_run))
          { dest_root: dest, agents: results, dry_run: dry_run }
        end

        private

        # The retired coordinator playbook: remove, never update — the loop is
        # driven by the architect session itself, so a leftover fifth playbook
        # can only mislead. A dry run reports the would-be removal untouched.
        def remove_stale_coordinator(dest, dry_run:)
          stale = dest.join("architect-coordinator.md")
          return [] unless stale.exist?

          FileUtils.rm(stale) unless dry_run
          [{ name: stale.basename.to_s, action: dry_run ? :would_remove : :removed, path: stale }]
        end

        def default_dest(env)
          Pathname.new(env.fetch("PI_AGENTS_DIR", File.join(pi_agent_dir(env), "agents")))
        end

        # Same convention as SkillInstaller: PI_CODING_AGENT_DIR or ~/.pi/agent.
        def pi_agent_dir(env)
          Pathname.new(env.fetch("PI_CODING_AGENT_DIR", File.join(Space::Core::XDG.home(env: env), ".pi", "agent")))
        end

        def search_root(env)
          File.join(pi_agent_dir(env), "git", "**")
        end

        # The installed extension package: pi clones it under
        # <agent dir>/git/<host>/<owner>/pi-extensions/. First match wins;
        # --extension-dir (tests) bypasses discovery.
        def locate_extension(env)
          Dir.glob(File.join(search_root(env), "pi-extensions", "architect-loop.ts")).first # paths:exempt — enumerates pi's own managed install layout (git/<host>/<owner>/pi-extensions), matching exactly the declared package, never user project files
            &.then { |p| Pathname.new(p) }
        end

        def render_via_node(source, env)
          out, err, status = Open3.capture3(env, "node", "-e", RENDER_SCRIPT, source.to_s)
          unless status.success?
            raise Space::Core::Error, "rendering playbooks via node failed (exit #{status.exitstatus}):\n#{out + err}"
          end

          rendered = {}
          marker = nil
          out.each_line do |line|
            if (m = line.match(/\A===FILE===(\w+)\n?\z/))
              marker = m[1]
              rendered[marker] = +""
            elsif marker
              rendered[marker] << line
            end
          end
          missing = ROLES - rendered.keys
          raise Space::Core::Error, "rendered output missing roles: #{missing.join(', ')}" if missing.any?
          rendered
        rescue Errno::ENOENT
          raise Space::Core::Error,
                "node: command not found — install-agents renders playbooks through the installed " \
                "architect-loop extension, which needs node on PATH (it ships with pi)."
        end

        def write_agent(dest, content, force:, dry_run:)
          name = dest.basename.to_s
          if dest.exist?
            return { name: name, action: :unchanged, path: dest } if File.read(dest) == content
            return { name: name, action: :conflict, path: dest } if dry_run

            raise Space::Core::Error,
                  "Refusing to overwrite existing playbook at #{dest}. Re-run with --force." unless force

            File.write(dest, content)
            { name: name, action: :updated, path: dest }
          else
            FileUtils.mkdir_p(dest.parent)
            File.write(dest, content) unless dry_run
            { name: name, action: dry_run ? :would_install : :installed, path: dest }
          end
        end
      end
    end
  end
end
