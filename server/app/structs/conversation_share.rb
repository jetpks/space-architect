# frozen_string_literal: true

module Space
  module Server
    module Structs
      # Grants?/matches? live in a module so they can be included into either a
      # ConversationShare subclass (normal path) OR into the bare ROM::Struct
      # subclass that ROM's struct compiler pre-creates for the :shares combine
      # alias before Zeitwerk loads this file (recovery path). Putting ACCESS_RANK
      # inside the module keeps the constant in the lexical scope of both methods.
      module ShareMethods
        ACCESS_RANK = { "view" => 0, "note" => 1 }.freeze

        def grants?(required_access)
          ACCESS_RANK.fetch(access) >= ACCESS_RANK.fetch(required_access.to_s)
        end

        def matches?(user)
          case grantee_kind
          when "user" then github_id == user.github_uid
          when "org"  then user.org_ids.include?(github_id)
          else false
          end
        end
      end

      class ConversationShare < ::Space::Server::DB::Struct
        GRANTEE_KINDS = %w[user org].freeze
        ACCESS_RANK = ShareMethods::ACCESS_RANK

        include ShareMethods
      end

      # ROM resolves has_many :conversation_shares, as: :shares by looking for
      # Space::Server::Structs::Share (Inflector.classify(:shares)). If the struct
      # compiler runs before this file is autoloaded, it pre-creates Share as a
      # bare ROM::Struct subclass. We include ShareMethods into that pre-existing
      # class so the cached klass (which inherits from it) picks up the methods
      # via Ruby's live method lookup — no need to clear the struct compiler cache.
      if const_defined?(:Share, false) && !(Share <= ConversationShare)
        Share.include(ShareMethods)
      elsif !const_defined?(:Share, false)
        class Share < ConversationShare; end
      end
      # If Share <= ConversationShare already (happy path), it already has ShareMethods.
    end
  end
end
