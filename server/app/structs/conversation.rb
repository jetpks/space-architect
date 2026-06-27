# frozen_string_literal: true

module Architect
  module Structs
    # Authz predicates require :messages and :shares combined — accessed via
    # conversations_repo.with_messages_and_shares(id) or visible_to(user).
    # ROM raises loudly if those associations are accessed un-combined; that is
    # the intentional safe failure mode.
    class Conversation < Architect::DB::Struct
      def published?
        !!published
      end

      def owned_by?(user)
        !user.nil? && user.id == user_id
      end

      def shared_with?(user, access:)
        return false unless user
        shares.any? { |s| s.matches?(user) && s.grants?(access) }
      end

      # Whole-conversation visibility: published, owned, shared, or has a
      # published snippet.
      def visible_to?(user)
        published? ||
          owned_by?(user) ||
          shared_with?(user, access: :view) ||
          messages.any?(&:published)
      end

      # Owners, grantees, and viewers of a published conversation see all
      # messages; others only see individually-published messages.
      def visible_messages(viewer)
        return messages if published? || owned_by?(viewer) || shared_with?(viewer, access: :view)
        messages.select(&:published)
      end

      # Noting requires ownership or an explicit note grant; published
      # conversations are view-only for the world.
      def annotatable_by?(user)
        return false unless user
        owned_by?(user) || shared_with?(user, access: :note)
      end

      def source_file
        return nil unless source_file_data
        Architect::SourceFileUploader.uploaded_file(source_file_data)
      end
    end
  end
end
