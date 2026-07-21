# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:conversations) do
      add_column :turns_count, Integer, null: false, default: 0
    end
  end

  down do
    alter_table(:conversations) do
      drop_column :turns_count
    end
  end
end
