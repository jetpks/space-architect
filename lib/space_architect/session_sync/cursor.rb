# frozen_string_literal: true

require "yaml"
require "fileutils"

module Space::Architect
  module SessionSync
    # Machine-managed cursor at $XDG_STATE_HOME/space-architect/session-sync.yaml
    # (imitates Space::Src::State::Store's load/write/emit shape). Keyed by
    # absolute source path; each entry records the size + mtime observed the
    # last time that file was uploaded.
    class Cursor
      Entry = Data.define(:size, :mtime) do
        def initialize(size:, mtime:) = super
      end

      def self.load(path)
        raw = read_yaml(path)
        raw.each_with_object({}) do |(k, v), acc|
          acc[k] = Entry.new(size: v["size"], mtime: v["mtime"])
        end
      end

      def self.write(path, entries)
        FileUtils.mkdir_p(File.dirname(path))
        payload = entries.each_with_object({}) { |(k, v), acc| acc[k] = {"size" => v.size, "mtime" => v.mtime} }
        tmp = "#{path}.tmp.#{Process.pid}"
        begin
          File.write(tmp, YAML.dump(payload, line_width: -1))
          File.rename(tmp, path)
        ensure
          File.delete(tmp) if File.exist?(tmp)
        end
      end

      def self.read_yaml(path)
        return {} unless File.exist?(path)

        YAML.safe_load_file(path, permitted_classes: [], aliases: false) || {}
      end
    end
  end
end
