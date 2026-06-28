# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:runs) do
      add_column :occurred_at, :timestamptz, null: true
    end

    alter_table(:iterations) do
      add_column :occurred_at, :timestamptz, null: true
    end
  end

  down do
    alter_table(:iterations) do
      drop_column :occurred_at
    end

    alter_table(:runs) do
      drop_column :occurred_at
    end
  end
end
