# frozen_string_literal: true

require "yaml"
require "pathname"

module Space::Architect
  module Research
    class Registry
      def initialize(path)
        @path = Pathname.new(path)
      end

      def add(run)
        runs = load_runs
        runs.reject! { |r| r[:id] == run.id }
        runs << serialize(run)
        write(runs)
        run
      end

      def all
        load_runs.map { |h| deserialize(h) }
      end

      def find(id)
        load_runs.find { |h| h[:id] == id }.then { |h| h ? deserialize(h) : nil }
      end

      private

      def load_runs
        return [] unless @path.exist?
        YAML.safe_load(@path.read, aliases: false) || []
      end

      def write(runs)
        @path.parent.mkpath
        @path.write(YAML.dump(runs))
      end

      def serialize(run)
        {
          "id"            => run.id,
          "topic"         => run.topic,
          "pid"           => run.pid,
          "dir"           => run.dir.to_s,
          "prompt_path"   => run.prompt_path.to_s,
          "run_log_path"  => run.run_log_path.to_s,
          "report_path"   => run.report_path.to_s,
          "model"         => run.model,
          "dispatched_at" => run.dispatched_at.iso8601
        }
      end

      def deserialize(h)
        Run.new(
          id:            h["id"],
          topic:         h["topic"],
          pid:           h["pid"].to_i,
          dir:           Pathname.new(h["dir"]),
          prompt_path:   Pathname.new(h["prompt_path"]),
          run_log_path:  Pathname.new(h["run_log_path"]),
          report_path:   Pathname.new(h["report_path"]),
          model:         h["model"],
          dispatched_at: Time.parse(h["dispatched_at"].to_s)
        )
      end
    end
  end
end
