# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:conversations) do
      add_column :source_file_data, :text
    end
  end
end
