# frozen_string_literal: true

module Space::Architect
  module Research
    Run = Data.define(:id, :topic, :pid, :dir, :prompt_path, :run_log_path, :report_path, :model, :dispatched_at)
  end
end
