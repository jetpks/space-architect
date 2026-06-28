# auto_register: false
# frozen_string_literal: true

module Space
  module Server
    module Importers
      # Returns the importer class for a pre-parsed first record.
      # Does NOT open files or instantiate importers — pure classification.
      def self.select(record)
        return Importers::ClaudeCode unless record
        return Importers::Codex if Importers::Codex.matches?(record)
        return Importers::Pi   if Importers::Pi.matches?(record)
        Importers::ClaudeCode
      end
    end
  end
end
