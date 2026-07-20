# frozen_string_literal: true

module Space
  module Server
    module Jobs
      class Executor
        # Resolves op:// secret refs to values by shelling the 1Password CLI.
        # NEVER exercised in tests (an injected fake takes its seat) and never
        # logs values — resolved secrets exist only in the returned hash, which
        # the executor passes solely into the child's spawn environment.
        class SecretResolver
          # [{ "ref" => "op://...", "name" => "ENV_NAME" }, ...] => { name => value }
          def call(secret_refs)
            secret_refs.to_h { |secret| [secret["name"], read(secret["ref"])] }
          end

          private

          def read(ref)
            value = IO.popen(["op", "read", ref], &:read)
            raise "op read failed for #{ref}" unless $?.success?

            value.chomp
          end
        end
      end
    end
  end
end
