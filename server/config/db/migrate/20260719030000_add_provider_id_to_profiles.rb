# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:profiles) do
      add_foreign_key :provider_id, :providers, null: true, type: :bigint, on_delete: :set_null
      add_index :provider_id, name: :index_profiles_on_provider_id
    end
  end

  down do
    alter_table(:profiles) do
      drop_index :provider_id, name: :index_profiles_on_provider_id
      drop_column :provider_id
    end
  end
end
