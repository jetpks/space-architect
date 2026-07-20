# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:profiles) do
      primary_key :id, type: :Bignum
      foreign_key :user_id, :users, null: false, type: :bigint, on_delete: :cascade
      column :name, String, null: false
      column :harness_type, String, null: false
      column :spec, :jsonb, null: false, default: Sequel.lit("'{}'::jsonb")
      column :created_at, :timestamptz, null: false
      column :updated_at, :timestamptz, null: false
      index [:user_id, :name], unique: true, name: :index_profiles_on_user_id_and_name
    end
  end

  down do
    drop_table(:profiles)
  end
end
