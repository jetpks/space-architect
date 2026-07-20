# frozen_string_literal: true

require_relative "../jobs/executor/secret_resolver"

module Space
  module Server
    module Boot
      # Resolves INGEST_TOKEN at process boot so falcon can be cold-restarted without
      # hand-minting a new token. Reuses Jobs::Executor::SecretResolver for the actual
      # `op read` — never duplicates the op-shelling.
      #
      # Fail-closed: a raising resolver or an empty resolved value aborts (never
      # populates ENV) because app/action.rb#token_user treats a nil/empty token as
      # "auth disabled", so booting with one would silently break all ingest auth.
      class IngestToken
        ENV_VAR = "INGEST_TOKEN"
        REF_ENV_VAR = "INGEST_TOKEN_REF"
        DEFAULT_REF = "op://ansible/space-architect-server/ingest-token"

        def initialize(resolver: Jobs::Executor::SecretResolver.new)
          @resolver = resolver
        end

        # Populates env[INGEST_TOKEN] and returns its value.
        #
        # - A non-empty env[INGEST_TOKEN] already present is used as-is; the resolver
        #   is not called (dev/test escape hatch).
        # - Otherwise resolves env[INGEST_TOKEN_REF] (default DEFAULT_REF) through the
        #   injected resolver.
        # - Raises RuntimeError, leaving env untouched, if the resolver raises or the
        #   resolved value is nil/empty.
        def resolve!(env: ENV)
          existing = env[ENV_VAR]
          return existing unless existing.nil? || existing.empty?

          ref = env.fetch(REF_ENV_VAR, DEFAULT_REF)
          resolved = @resolver.call([{"ref" => ref, "name" => ENV_VAR}]).fetch(ENV_VAR)
          raise "INGEST_TOKEN resolved empty from #{ref} — refusing to boot" if resolved.nil? || resolved.empty?

          env[ENV_VAR] = resolved
        end
      end
    end
  end
end
