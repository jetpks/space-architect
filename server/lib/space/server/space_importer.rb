# frozen_string_literal: true

require "yaml"
require "json"
require "open3"
require "time"
require_relative "normalizer"
require_relative "runs/persistor"
require_relative "section_parser"

module Space
  module Server
    # Ingests an architect-loop space directory into the database.
    # Uses constructor injection (matching Runs::Persistor) since it lives in lib/.
    #
    # Usage:
    #   importer = SpaceImporter.new(spaces_repo: ..., iterations_repo: ..., ...)
    #   space = importer.import!(space_dir, user: current_user)
    class SpaceImporter
      def initialize(spaces_repo:, iterations_repo:, artifacts_repo:,
                     runs_repo:, conversations_repo:, messages_repo:)
        @spaces_repo        = spaces_repo
        @iterations_repo    = iterations_repo
        @artifacts_repo     = artifacts_repo
        @runs_repo          = runs_repo
        @conversations_repo = conversations_repo
        @messages_repo      = messages_repo
      end

      # Imports the space directory, upserting all records. Returns the Space struct.
      # claude_projects_root: base dir for architect session logs (default ~/.claude/projects).
      def import!(space_dir, user:, claude_projects_root: File.expand_path("~/.claude/projects"))
        space_dir = space_dir.to_s
        yaml      = YAML.load_file(File.join(space_dir, "space.yaml"))

        slug   = yaml["id"]
        title  = yaml["title"]
        status = yaml["status"] || yaml.dig("architect", "status")
        repos  = Array(yaml["repos"]).map { |r| r.is_a?(Hash) ? r["full_name"] : r }.compact

        space = @spaces_repo.upsert_by_slug(user.id, slug, {
          title:       title,
          status:      status,
          source_path: space_dir,
          repos:       repos
        })

        arch       = yaml.fetch("architect", nil) || {}
        arch_iters = Array(arch["iterations"])

        iteration_map = upsert_iterations(space, arch_iters)
        import_artifacts(space_dir, space, arch_iters, iteration_map)
        import_runs(space_dir, space, arch_iters, iteration_map, user: user)
        import_architect_runs(space, user: user, claude_projects_root: claude_projects_root)

        @spaces_repo.update(space.id, imported_at: Time.now)
        @spaces_repo.by_pk(space.id)
      end

      # Maps a source_path to the Claude Code project-dir name by replacing / with -.
      # e.g. /Users/eric/spaces/foo → -Users-eric-spaces-foo
      def mangle(source_path)
        source_path.to_s.gsub("/", "-")
      end

      private

      def upsert_iterations(space, arch_iters)
        arch_iters.each_with_object({}) do |iter_data, map|
          ordinal = iter_data["ordinal"]
          sha     = iter_data["freeze_sha"]
          iter = @iterations_repo.upsert_by_ordinal(space.id, ordinal, {
            name:        iter_data["name"],
            freeze_sha:  sha,
            verdict:     iter_data["verdict"],
            status:      iter_data["status"],
            occurred_at: git_commit_time(space.source_path, sha)
          })
          map[ordinal] = iter
        end
      end

      def import_artifacts(space_dir, space, arch_iters, iteration_map)
        brief_path = File.join(space_dir, "architecture", "BRIEF.md")
        if File.exist?(brief_path)
          upsert_artifact(space, nil, "brief", "architecture/BRIEF.md", File.read(brief_path))
        end

        index_path = File.join(space_dir, "architecture", "ARCHITECT.md")
        if File.exist?(index_path)
          upsert_artifact(space, nil, "architect_index", "architecture/ARCHITECT.md",
                          File.read(index_path))
        end

        Dir.glob(File.join(space_dir, "architecture", "I[0-9][0-9]-*.md")).sort.each do |path|
          rel_path = File.join("architecture", File.basename(path))
          ordinal  = File.basename(path).match(/^I(\d+)-/i)&.then { |m| m[1].to_i }
          iter     = iteration_map[ordinal]
          upsert_artifact(space, iter, "iteration", rel_path, File.read(path))
        end

        arch_iters.each do |iter_data|
          ordinal = iter_data["ordinal"]
          iter    = iteration_map[ordinal]
          Array(iter_data["lanes"]).each do |lane_data|
            worktree = lane_data["worktree"]
            next unless worktree

            build_dir = File.join(space_dir, File.dirname(worktree))

            prompt_path = File.join(build_dir, "prompt.md")
            if File.exist?(prompt_path)
              rel = File.join(File.dirname(worktree), "prompt.md")
              upsert_artifact(space, iter, "lane_prompt", rel, File.read(prompt_path))
            end

            report_path = File.join(build_dir, "report.md")
            if File.exist?(report_path)
              rel = File.join(File.dirname(worktree), "report.md")
              upsert_artifact(space, iter, "lane_report", rel, File.read(report_path))
            end
          end
        end
      end

      def upsert_artifact(space, iteration, kind, path, raw)
        title = SectionParser.first_heading(raw)
        @artifacts_repo.upsert_by_path(space.id, path, {
          iteration_id: iteration&.id,
          kind:         kind,
          title:        title,
          raw:          raw
        })
      end

      def import_runs(space_dir, space, arch_iters, iteration_map, user:)
        lane_map = build_lane_map(space_dir, arch_iters, iteration_map)

        Dir.glob(File.join(space_dir, "build", "*", "run.jsonl")).sort.each do |run_jsonl|
          dir_name  = File.basename(File.dirname(run_jsonl))
          build_rel = File.join("build", dir_name)
          meta      = lane_map[build_rel] || orphan_meta(dir_name, iteration_map)
          import_builder_run(run_jsonl, space: space, user: user, **meta)
        end
      end

      def build_lane_map(space_dir, arch_iters, iteration_map)
        arch_iters.each_with_object({}) do |iter_data, map|
          ordinal = iter_data["ordinal"]
          iter    = iteration_map[ordinal]
          Array(iter_data["lanes"]).each do |lane_data|
            worktree = lane_data["worktree"]
            next unless worktree
            build_rel = File.dirname(worktree)
            map[build_rel] = { iteration: iter, lane: lane_data["name"] }
          end
        end
      end

      def orphan_meta(dir_name, iteration_map)
        m = dir_name.match(/^I(\d+)-.+-([^-]+)$/)
        if m
          ordinal = m[1].to_i
          { iteration: iteration_map[ordinal], lane: m[2] }
        else
          { iteration: nil, lane: dir_name }
        end
      end

      def import_builder_run(run_jsonl, space:, iteration:, lane:, user:)
        existing = @runs_repo.find_builder_run(space.id, iteration&.id, lane)

        if existing&.conversation_id
          @conversations_repo.delete(existing.conversation_id)
          @runs_repo.update(existing.id, conversation_id: nil, updated_at: Time.now)
        end

        run = existing || @runs_repo.create(
          user_id:      user.id,
          space_id:     space.id,
          iteration_id: iteration&.id,
          lane:         lane,
          role:         "builder",
          status:       0,
          published:    false,
          created_at:   Time.now,
          updated_at:   Time.now
        )

        persistor  = Runs::Persistor.new(@conversations_repo, @messages_repo)
        persistor.setup(run)

        parser     = nil
        producer   = nil
        session_id = nil

        File.open(run_jsonl) do |io|
          io.each_line do |line|
            line = line.strip
            next if line.empty?

            record = begin
              JSON.parse(line)
            rescue JSON::ParserError
              next
            end

            unless parser
              klass    = Normalizer.select(record)
              producer = producer_name(klass)
              parser   = klass.new
            end

            parser.process(record).each do |event|
              persistor.process(event)
              session_id ||= event[:session_id] if event[:type] == :run_init
            end
          end
        end

        @runs_repo.update(run.id, {
          status:          2,
          producer:        producer,
          session_id:      session_id,
          conversation_id: persistor.conversation_id,
          updated_at:      Time.now
        }.compact)
      end

      def import_architect_runs(space, user:, claude_projects_root:)
        project_dir = File.join(claude_projects_root, mangle(space.source_path))
        return unless Dir.exist?(project_dir)

        Dir.glob(File.join(project_dir, "*.jsonl")).sort.each do |session_jsonl|
          import_architect_run(session_jsonl, space: space, user: user)
        end
      end

      def import_architect_run(session_jsonl, space:, user:)
        session_id = File.basename(session_jsonl, ".jsonl")
        existing   = @runs_repo.find_architect_run(space.id, session_id)

        if existing&.conversation_id
          @conversations_repo.delete(existing.conversation_id)
          @runs_repo.update(existing.id, conversation_id: nil, updated_at: Time.now)
        end

        run = existing || @runs_repo.create(
          user_id:      user.id,
          space_id:     space.id,
          iteration_id: nil,
          lane:         nil,
          role:         "architect",
          status:       0,
          published:    false,
          created_at:   Time.now,
          updated_at:   Time.now
        )

        persistor   = Runs::Persistor.new(@conversations_repo, @messages_repo)
        persistor.setup(run)

        parser      = Normalizer::ClaudeSession.new
        occurred_at = nil

        File.open(session_jsonl) do |io|
          io.each_line do |line|
            line = line.strip
            next if line.empty?

            record = begin
              JSON.parse(line)
            rescue JSON::ParserError
              next
            end

            occurred_at ||= parse_iso8601(record["timestamp"])

            parser.process(record).each { |event| persistor.process(event) }
          end
        end

        @runs_repo.update(run.id, {
          status:          2,
          producer:        "claude_session",
          session_id:      session_id,
          occurred_at:     occurred_at,
          conversation_id: persistor.conversation_id,
          updated_at:      Time.now
        }.compact)
      end

      def producer_name(normalizer_class)
        case normalizer_class.name
        when /ClaudeSession/ then "claude_session"
        when /ClaudeCode/    then "claude_code"
        when /Opencode/      then "opencode"
        else "unknown"
        end
      end

      # Returns the git committer timestamp for +sha+ in +space_dir+, or nil on any failure.
      # sha is passed as a positional arg to avoid shell interpolation.
      def git_commit_time(space_dir, sha)
        return nil if sha.nil? || sha.to_s.strip.empty?

        out, status = Open3.capture2e("git", "-C", space_dir.to_s, "show", "-s", "--format=%cI", sha.to_s)
        return nil unless status.success?

        ts = out.lines.first&.strip
        parse_iso8601(ts)
      rescue StandardError
        nil
      end

      def parse_iso8601(str)
        return nil if str.nil? || str.strip.empty?
        Time.iso8601(str.strip).utc
      rescue ArgumentError
        nil
      end
    end
  end
end
