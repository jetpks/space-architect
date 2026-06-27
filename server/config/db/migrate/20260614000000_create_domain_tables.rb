# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:users) do
      primary_key :id, type: :Bignum
      column :avatar_url, String
      column :created_at, :timestamptz, null: false
      column :email, String
      column :github_orgs, :jsonb, null: false, default: Sequel.lit("'[]'::jsonb")
      column :github_uid, String, null: false
      column :name, String
      column :orgs_synced_at, :timestamptz
      column :updated_at, :timestamptz, null: false
      column :username, String, null: false
      index :github_uid, unique: true, name: :index_users_on_github_uid
    end

    create_table(:conversations) do
      primary_key :id, type: :Bignum
      column :agent_version, String
      column :created_at, :timestamptz, null: false
      column :git_branch, String
      column :original_cwd, String
      column :published, TrueClass, null: false, default: false
      column :session_id, String
      column :source, String
      column :status, Integer, null: false, default: 0
      column :title, String
      column :updated_at, :timestamptz, null: false
      foreign_key :user_id, :users, null: false, type: :bigint
      index :published, name: :index_conversations_on_published
      index :session_id, name: :index_conversations_on_session_id
      index :user_id, name: :index_conversations_on_user_id
    end

    create_table(:messages) do
      primary_key :id, type: :Bignum
      column :content, :jsonb, null: false, default: Sequel.lit("'[]'::jsonb")
      foreign_key :conversation_id, :conversations, null: false, type: :bigint
      column :created_at, :timestamptz, null: false
      column :model, String
      column :occurred_at, :timestamptz
      column :parent_uuid, String
      column :position, Integer, null: false
      column :published, TrueClass, null: false, default: false
      column :role, String, null: false
      column :updated_at, :timestamptz, null: false
      column :uuid, String
      index [:conversation_id, :position], name: :index_messages_on_conversation_id_and_position
      index [:conversation_id, :uuid], unique: true, name: :index_messages_on_conversation_id_and_uuid
      index :conversation_id, name: :index_messages_on_conversation_id
      index :published, name: :index_messages_on_published
    end

    create_table(:annotations) do
      primary_key :id, type: :Bignum
      foreign_key :anchor_message_id, :messages, null: true, type: :bigint
      column :body, :text, null: false
      foreign_key :conversation_id, :conversations, null: false, type: :bigint
      column :created_at, :timestamptz, null: false
      column :selector, :jsonb
      column :target_kind, String, null: false
      column :tool_use_id, String
      column :updated_at, :timestamptz, null: false
      foreign_key :user_id, :users, null: false, type: :bigint
      index :anchor_message_id, name: :index_annotations_on_anchor_message_id
      index :conversation_id, name: :index_annotations_on_conversation_id
      index :user_id, name: :index_annotations_on_user_id
    end

    create_table(:conversation_shares) do
      primary_key :id, type: :Bignum
      column :access, String, null: false, default: "view"
      foreign_key :conversation_id, :conversations, null: false, type: :bigint
      column :created_at, :timestamptz, null: false
      column :github_id, String, null: false
      column :github_login, String, null: false
      column :grantee_kind, String, null: false
      column :updated_at, :timestamptz, null: false
      index :conversation_id, name: :index_conversation_shares_on_conversation_id
      index [:grantee_kind, :github_id], name: :index_conversation_shares_on_grantee_kind_and_github_id
    end

    run "CREATE UNIQUE INDEX index_conversation_shares_unique_grantee ON conversation_shares (conversation_id, grantee_kind, lower((github_login)::text))"
  end

  down do
    drop_table(:conversation_shares)
    drop_table(:annotations)
    drop_table(:messages)
    drop_table(:conversations)
    drop_table(:users)
  end
end
