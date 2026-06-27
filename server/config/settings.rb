# frozen_string_literal: true

module Architect
  class Settings < Hanami::Settings
    setting :database_url, constructor: Types::String
    setting :session_secret, constructor: Types::String
    setting :github_client_id, default: nil
    setting :github_client_secret, default: nil

    setting :ingest_token,   default: nil
    setting :ingest_user_id, default: nil, constructor: ->(v) { Integer(v) if v }

    # Transport security — production values via ENV/credentials (S2 deploy slice).
    # Defaults are dev/test-safe: no redirect lockout, all hosts permitted.
    setting :force_ssl,        default: false, constructor: Types::Params::Bool
    setting :assume_ssl,       default: false, constructor: Types::Params::Bool
    setting :permitted_hosts,  default: [],    constructor: ->(v) {
      case v
      when Array  then v
      when String then v.split(",").map(&:strip).reject(&:empty?)
      else []
      end
    }
  end
end
