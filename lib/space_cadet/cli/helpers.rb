# frozen_string_literal: true

module SpaceCadet
  module CLI
    module Helpers
      def project_config
        @project_config ||= SpaceCadet::Config.load
      end

      def state
        @state ||= SpaceCadet::State.load
      end

      def store
        @store ||= SpaceCadet::SpaceStore.new(config: project_config, state: state)
      end

      def terminal
        @terminal
      end

      def setup_terminal(color: "auto", colors: nil)
        @terminal = Terminal.new(
          config: project_config,
          stdout: out,
          stderr: err,
          color_mode: colors || color || "auto"
        )
      end

      def display_date(space)
        id_date = space.id.match(/\A(\d{4})(\d{2})(\d{2})/)
        return "#{id_date[1]}-#{id_date[2]}-#{id_date[3]}" if id_date

        space.data["created_at"].to_s[0, 10]
      end

      def handle_errors
        yield
      rescue SpaceCadet::Error => e
        err.puts e.message
        CLI.record_outcome(Outcome.new(exit_code: 1, message: e.message))
      end
    end

    class RepoProgress
      def initialize(total)
        @total = total
        @statuses = {}
      end

      def start(addition)
        source = addition[:evergreen_source]
        @statuses[addition.fetch(:reference).full_name] = source&.directory? ? :copying : :cloning
      end

      def trust(addition)
        @statuses[addition.fetch(:reference).full_name] = :trusting
      end

      def finish(addition)
        @statuses[addition.fetch(:reference).full_name] = :done
      end

      def fail(addition)
        @statuses[addition.fetch(:reference).full_name] = :failed
      end

      def message
        done = @statuses.count { |_repo, status| status == :done }
        failed = @statuses.count { |_repo, status| status == :failed }
        copying = @statuses.select { |_repo, status| status == :copying }.keys
        cloning = @statuses.select { |_repo, status| status == :cloning }.keys
        trusting = @statuses.select { |_repo, status| status == :trusting }.keys

        if @total == 1
          copying_repo = copying.first
          cloning_repo = cloning.first
          trusting_repo = trusting.first
          return "Copying #{copying_repo}" if copying_repo
          return "Cloning #{cloning_repo}" if cloning_repo
          return "Trusting #{trusting_repo}" if trusting_repo
          return "Fetch failed" if failed.positive?

          "Preparing repos"
        else
          active = []
          active << "copying #{copying.join(', ')}" unless copying.empty?
          active << "cloning #{cloning.join(', ')}" unless cloning.empty?
          active << "trusting #{trusting.join(', ')}" unless trusting.empty?
          suffix = active.empty? ? nil : ": #{active.join('; ')}"
          failed_text = failed.positive? ? ", #{failed} failed" : ""
          "Fetching repos #{done}/#{@total}#{failed_text}#{suffix}"
        end
      end
    end
  end
end
