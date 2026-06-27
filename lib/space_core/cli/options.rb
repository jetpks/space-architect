# frozen_string_literal: true

module Space::Core::CLI
module GlobalOptions
  def self.included(base)
    base.option :color, type: :string, default: "auto", desc: "Color output: auto, always, never"
    base.option :colors, type: :string, desc: "Alias for --color"
  end
end
end
