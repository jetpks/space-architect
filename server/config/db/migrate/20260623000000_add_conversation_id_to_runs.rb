# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:runs) do
      add_foreign_key :conversation_id, :conversations, null: true, type: :bigint, on_delete: :set_null
      add_index :conversation_id, name: :index_runs_on_conversation_id
    end
  end

  down do
    alter_table(:runs) do
      drop_index :conversation_id, name: :index_runs_on_conversation_id
      drop_column :conversation_id
    end
  end
end
