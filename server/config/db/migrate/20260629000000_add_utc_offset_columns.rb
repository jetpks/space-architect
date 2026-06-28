# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:spaces) do
      add_column :git_utc_offset, :integer, null: true
    end

    alter_table(:iterations) do
      add_column :occurred_at_utc_offset, :integer, null: true
    end
  end

  down do
    alter_table(:iterations) do
      drop_column :occurred_at_utc_offset
    end

    alter_table(:spaces) do
      drop_column :git_utc_offset
    end
  end
end
