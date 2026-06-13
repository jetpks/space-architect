# frozen_string_literal: true

require "dry/monads"
require "repo_tender/config/model"

module RepoTender
  module Forge
    # Abstract forge interface. The GitHub implementation lists the
    # repos belonging to an OrgRef. The interface is intentionally
    # narrow: a forge is a source of (host, owner, name) triples. The
    # sync engine expands an OrgRef into RepoRefs at sync time; it
    # never asks the forge about a specific repo.
    class Client
      extend Dry::Monads[:result]

      # Returns Success([RepoRef, ...]) or Failure. Honors the
      # include_archived / include_forks flags on the OrgRef.
      def list_org(org_ref)
        raise NotImplementedError
      end
    end
  end
end
