# frozen_string_literal: true

# Minimal support for serializer unit tests.
# Does NOT require hanami/prepare — no DB, no app boot needed.
$LOAD_PATH.unshift File.expand_path("../../app", __dir__)

require "minitest/autorun"
require "serializers/conversation"

# Duck-typed plain-Ruby fixtures — the serializer only calls methods, never
# inspects class identity, so these satisfy the duck-type contract fully.

TestUser = Data.define(:id, :username, :name, :avatar_url)

TestMsg = Data.define(:id, :role, :model, :position, :published, :blocks)

TestRound = Data.define(:anchor_id, :messages)

TestTurn = Data.define(:anchor_id, :prompt, :rounds)

TestShare = Data.define(:id, :grantee_kind, :github_login, :access, :github_id)

TestAnnotation = Data.define(:id, :body, :user, :user_id, :target_kind,
                              :anchor_message_id, :tool_use_id, :selector)

# Conversation with explicit owner_id + grantee ID sets for predicate derivation.
# view_grantee_ids: IDs with at least :view access.
# note_grantee_ids: IDs with :note access (implicitly satisfies :view too).
TestConversation = Data.define(
  :id, :title, :status, :published, :source, :original_cwd, :git_branch,
  :agent_version, :user, :owner_id, :view_grantee_ids, :note_grantee_ids
) do
  def owned_by?(viewer)
    viewer&.id == owner_id
  end

  def shared_with?(viewer, access:)
    return false unless viewer
    case access
    when :view then view_grantee_ids.include?(viewer.id) || note_grantee_ids.include?(viewer.id)
    when :note then note_grantee_ids.include?(viewer.id)
    else false
    end
  end

  def annotatable_by?(viewer)
    owned_by?(viewer) || shared_with?(viewer, access: :note)
  end
end
