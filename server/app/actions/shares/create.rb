# frozen_string_literal: true

require_relative "../../contracts/create_share"
require "rom/sql"

module Architect
  module Actions
    module Shares
      class Create < Architect::Action
        include Architect::Deps["repos.conversations_repo", "repos.conversation_shares_repo"]

        CONTRACT = Contracts::CreateShare.new

        def handle(req, res)
          conversation_id = req.params[:conversation_id].to_i
          conversation = conversations_repo.by_pk(conversation_id)
          halt_not_found(res) unless conversation

          require_owner(req, res, conversation)

          result = CONTRACT.call(req.params.to_h)
          halt_unprocessable(res, result.errors.to_h) if result.failure?

          login = result.to_h[:share][:login].strip
          access_raw = result.to_h[:share][:access]
          access = (access_raw.nil? || access_raw.empty?) ? "view" : access_raw

          account = Architect::Github.lookup(login)
          grantee = account.kind == "org" ? "members of #{account.login}" : account.login

          conversation_shares_repo.create(
            conversation_id: conversation_id,
            grantee_kind: account.kind,
            github_login: account.login,
            github_id: account.id,
            access: access,
            created_at: Time.now,
            updated_at: Time.now
          )

          redirect_back_with_flash(req, res,
            fallback: "/conversations/#{conversation_id}",
            notice: "Shared with #{grantee}.")
        rescue Architect::Github::NotFound
          redirect_back_with_flash(req, res,
            fallback: "/conversations/#{conversation_id}",
            alert: "No GitHub user or organization named #{login}.")
        rescue Architect::Github::Error
          redirect_back_with_flash(req, res,
            fallback: "/conversations/#{conversation_id}",
            alert: "GitHub lookup failed — try again.")
        rescue ROM::SQL::UniqueConstraintError
          redirect_back_with_flash(req, res,
            fallback: "/conversations/#{conversation_id}",
            alert: "Github login has already been taken.")
        end
      end
    end
  end
end
