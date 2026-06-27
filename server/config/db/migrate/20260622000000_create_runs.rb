# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:runs) do
      primary_key :id, type: :Bignum
      foreign_key :user_id, :users, null: false, type: :bigint, on_delete: :cascade
      column :status, Integer, null: false, default: 0  # 0=pending, 1=live, 2=complete, 3=failed
      column :producer, String                           # "claude_code" | "opencode" (set at ingest)
      column :session_id, String                         # producer session ID (from run_init)
      column :published, TrueClass, null: false, default: false
      column :created_at, :timestamptz, null: false
      column :updated_at, :timestamptz, null: false
      index :user_id, name: :index_runs_on_user_id
      index :session_id, name: :index_runs_on_session_id
      index :published, name: :index_runs_on_published
    end
  end

  down do
    drop_table(:runs)
  end
end
