# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:spaces) do
      primary_key :id, type: :Bignum
      foreign_key :user_id, :users, null: false, type: :bigint, on_delete: :cascade
      column :slug,        String, null: false
      column :title,       String
      column :status,      String
      column :source_path, String
      column :repos,       :jsonb, default: Sequel.lit("'[]'::jsonb")
      column :imported_at, :timestamptz
      column :created_at,  :timestamptz, null: false
      column :updated_at,  :timestamptz, null: false
      index [:user_id, :slug], unique: true, name: :index_spaces_on_user_id_and_slug
    end

    create_table(:iterations) do
      primary_key :id, type: :Bignum
      foreign_key :space_id, :spaces, null: false, type: :bigint, on_delete: :cascade
      column :ordinal,    Integer, null: false
      column :name,       String,  null: false
      column :slug,       String
      column :freeze_sha, String
      column :verdict,    String
      column :status,     String
      column :created_at, :timestamptz, null: false
      column :updated_at, :timestamptz, null: false
      index [:space_id, :ordinal], unique: true, name: :index_iterations_on_space_id_and_ordinal
    end

    create_table(:artifacts) do
      primary_key :id, type: :Bignum
      foreign_key :space_id,     :spaces,     null: false, type: :bigint, on_delete: :cascade
      foreign_key :iteration_id, :iterations, null: true,  type: :bigint, on_delete: :set_null
      column :kind,       String, null: false
      column :path,       String, null: false
      column :title,      String
      column :raw,        :text,  null: false
      column :created_at, :timestamptz, null: false
      column :updated_at, :timestamptz, null: false
      index [:space_id, :path], unique: true, name: :index_artifacts_on_space_id_and_path
    end

    alter_table(:runs) do
      add_foreign_key :space_id,     :spaces,     null: true, type: :bigint, on_delete: :set_null
      add_foreign_key :iteration_id, :iterations, null: true, type: :bigint, on_delete: :set_null
      add_column :lane, String
      add_column :role, String, default: "builder", null: false
      add_index :space_id,     name: :index_runs_on_space_id
      add_index :iteration_id, name: :index_runs_on_iteration_id
    end
  end

  down do
    alter_table(:runs) do
      drop_index :iteration_id, name: :index_runs_on_iteration_id
      drop_index :space_id,     name: :index_runs_on_space_id
      drop_column :role
      drop_column :lane
      drop_column :iteration_id
      drop_column :space_id
    end
    drop_table(:artifacts)
    drop_table(:iterations)
    drop_table(:spaces)
  end
end
