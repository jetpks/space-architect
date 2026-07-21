# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:conversations) do
      add_column :parent_session_id, :text
    end
  end

  down do
    alter_table(:conversations) do
      drop_column :parent_session_id
    end
  end
end
