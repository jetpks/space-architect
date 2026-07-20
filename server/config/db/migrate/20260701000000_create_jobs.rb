# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:jobs) do
      primary_key :id, type: :Bignum
      foreign_key :user_id, :users, null: false, type: :bigint, on_delete: :cascade
      column :spec, :jsonb, null: false, default: Sequel.lit("'{}'::jsonb")
      column :status, String, null: false, default: "queued"
      foreign_key :run_id, :runs, null: true, type: :bigint, on_delete: :set_null
      column :created_at, :timestamptz, null: false
      column :updated_at, :timestamptz, null: false
      index :user_id, name: :index_jobs_on_user_id
      index :status,  name: :index_jobs_on_status
      constraint(:jobs_status_check, status: %w[queued running succeeded failed canceled])
    end
  end

  down do
    drop_table(:jobs)
  end
end
