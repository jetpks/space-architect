# auto_register: false
# frozen_string_literal: true

module Space
  module Server
    module Importers
      # Postgres text/jsonb columns reject the NUL byte outright
      # (PG::UntranslatableCharacter) — recursively strip it from anything about
      # to be persisted. Shared by every importer (claude_code, codex, pi) and
      # Runs::Persistor, the two places transcript content reaches the database.
      module NulScrub
        module_function

        def scrub_nul(value)
          case value
          when String then value.delete("\0")
          when Array  then value.map { |v| scrub_nul(v) }
          when Hash   then value.transform_values { |v| scrub_nul(v) }
          else value
          end
        end
      end
    end
  end
end
