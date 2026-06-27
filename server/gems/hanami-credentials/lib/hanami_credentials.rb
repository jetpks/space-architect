# frozen_string_literal: true

require "openssl"
require "base64"
require "yaml"

require_relative "hanami_credentials/version"
require_relative "hanami_credentials/encrypted_file"
require_relative "hanami_credentials/store"

module HanamiCredentials
  # Resolves a 32-byte master key from ENV var first, then key file.
  # Both sources store the key as 64-char lowercase hex.
  # Returns nil if neither source is present.
  def self.read_key(env_key:, key_path:, env: ENV)
    hex = env[env_key.to_s]
    return [hex].pack("H*") if hex && !hex.empty?

    str_path = key_path&.to_s
    if str_path && File.exist?(str_path)
      hex = File.read(str_path).strip
      return [hex].pack("H*") unless hex.empty?
    end

    nil
  end
end
