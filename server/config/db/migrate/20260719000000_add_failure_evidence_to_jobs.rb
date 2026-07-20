# frozen_string_literal: true

# Durable env-build-failure evidence (I07 D2 / I11). The executor's
# fail_before_spawn path already writes the build log / rejection reason onto
# the ephemeral raw stream (TTL 1800s, lib/space/server/jobs/stream_key.rb);
# this column keeps the same text queryable from the job row after the stream
# self-evicts. Nullable: only set on the failure path.
Sequel.migration do
  up do
    alter_table(:jobs) do
      add_column :failure_evidence, :text
    end
  end

  down do
    alter_table(:jobs) do
      drop_column :failure_evidence
    end
  end
end
