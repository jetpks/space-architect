# frozen_string_literal: true

# Claim/lease columns for the executor worker (I07). Partial indexes serve the
# two hot predicates: the claim's oldest-queued scan and the stale-lease sweep.
Sequel.migration do
  up do
    alter_table(:jobs) do
      add_column :leased_until, :timestamptz
      add_column :attempts, Integer, null: false, default: 0
      add_index :created_at,  name: :index_jobs_queued_on_created_at,    where: { status: "queued" }
      add_index :leased_until, name: :index_jobs_running_on_leased_until, where: { status: "running" }
    end
  end

  down do
    alter_table(:jobs) do
      drop_index :created_at,  name: :index_jobs_queued_on_created_at
      drop_index :leased_until, name: :index_jobs_running_on_leased_until
      drop_column :leased_until
      drop_column :attempts
    end
  end
end
