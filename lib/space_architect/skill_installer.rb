# frozen_string_literal: true

require "fileutils"
require "pathname"

module SpaceArchitect
  module SkillInstaller
    PROVIDERS = %w[claude codex opencode pi].freeze

    class << self
      def source_root
        Pathname.new(__dir__).parent.parent.join("skill")
      end

      def dest_root(provider, project:, env:, cwd: Dir.pwd)
        case provider.to_s
        when "claude"
          base = project ? Pathname.new(cwd) : Pathname.new(XDG.home(env: env))
          base.join(".claude", "skills")
        when "codex"
          base = project ? Pathname.new(cwd) : Pathname.new(XDG.home(env: env))
          base.join(".agents", "skills")
        when "opencode"
          project ? Pathname.new(cwd).join(".opencode", "skills") : XDG.config_home(env: env).join("skills")
        when "pi"
          base = project ? Pathname.new(cwd) : Pathname.new(pi_agent_dir(env: env))
          base.join("skills")
        else
          raise Error, "Unknown provider '#{provider}'. Expected one of: #{PROVIDERS.join(', ')}"
        end
      end

      def install(provider, project:, force:, env:, cwd: Dir.pwd, dry_run: false)
        validate_provider!(provider)
        dest = dest_root(provider, project: project, env: env, cwd: cwd)
        results = []

        source_skills.each do |skill_dir|
          name = skill_dir.basename.to_s
          skill_dest = dest.join(name)
          results << install_skill(skill_dir, skill_dest, force: force, dry_run: dry_run)
        end

        { dest_root: dest, skills: results, dry_run: dry_run }
      end

      def source_skills
        source_root.children.select(&:directory?)
      end

      private

      def validate_provider!(provider)
        return if PROVIDERS.include?(provider.to_s)

        raise Error, "Unknown provider '#{provider}'. Expected one of: #{PROVIDERS.join(', ')}"
      end

      def pi_agent_dir(env:)
        Pathname.new(env.fetch("PI_CODING_AGENT_DIR", File.join(XDG.home(env: env), ".pi", "agent")))
      end

      def install_skill(source, dest, force:, dry_run:)
        name = source.basename.to_s

        if dest.exist?
          if same_content?(source, dest)
            return { name: name, action: :unchanged, path: dest }
          end

          unless force
            return { name: name, action: :conflict, path: dest } if dry_run

            raise Error,
              "Refusing to overwrite existing skill at #{dest}. Re-run with --force."
          end

          unless dry_run
            FileUtils.rm_rf(dest)
            FileUtils.cp_r(source, dest)
          end
          { name: name, action: dry_run ? :would_update : :updated, path: dest }
        else
          unless dry_run
            FileUtils.mkdir_p(dest.parent)
            FileUtils.cp_r(source, dest)
          end
          { name: name, action: dry_run ? :would_install : :installed, path: dest }
        end
      end

      def same_content?(source, dest)
        return false unless dest.directory?

        source_files = Dir.glob("#{source}/**/*").reject { |f| File.directory?(f) }
        dest_files = Dir.glob("#{dest}/**/*").reject { |f| File.directory?(f) }

        return false if source_files.length != dest_files.length

        source_files.sort.zip(dest_files.sort).all? do |sf, df|
          rel = sf.sub("#{source}/", "")
          df.end_with?(rel) && File.read(sf) == File.read(df)
        end
      end
    end
  end
end
