# frozen_string_literal: true

module Space
  module Server
    module Serializers
      # Single-line, length-capped preview of a job's prompt — shared by
      # Runs::Index and Jobs::Index so both prop lists render byte-identical
      # snippets.
      module PromptSnippet
        module_function

        PROMPT_SNIPPET_LENGTH = 140

        def call(prompt)
          single_line = prompt.to_s.tr("\n", " ").squeeze(" ").strip
          single_line.length > PROMPT_SNIPPET_LENGTH ? "#{single_line[0, PROMPT_SNIPPET_LENGTH]}…" : single_line
        end
      end
    end
  end
end
