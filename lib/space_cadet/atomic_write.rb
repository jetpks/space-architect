# frozen_string_literal: true

require "fileutils"

module SpaceCadet
  module AtomicWrite
    module_function

    def write(path, content)
      path = path.to_s
      dir = File.dirname(path)
      FileUtils.mkdir_p(dir)
      tmp_path = File.join(dir, ".#{File.basename(path)}.#{Process.pid}.tmp")

      File.write(tmp_path, content)
      File.rename(tmp_path, path)
    ensure
      FileUtils.rm_f(tmp_path) if defined?(tmp_path) && tmp_path && File.exist?(tmp_path)
    end
  end
end
