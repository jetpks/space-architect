# frozen_string_literal: true

ROM::SQL.migration do
  up do
    alter_table(:runs) do
      add_column :harness, :text
      add_column :model,   :text
    end
  end

  down do
    alter_table(:runs) do
      drop_column :harness
      drop_column :model
    end
  end
end
