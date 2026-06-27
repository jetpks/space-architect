# frozen_string_literal: true

module HanamiCredentials
  # Hanami::Settings-compatible store implementing Hash#fetch semantics.
  # Resolution order: ENV (uppercase) → decrypted file (YAML, lowercase key) → default/block/KeyError.
  # With no master key present, the file layer is skipped (pure-ENV degradation).
  class Store
    NO_ARG = Object.new.freeze

    def initialize(content_path:, env_key:, key_path:, env: ENV)
      @content_path = content_path.to_s
      @env_key      = env_key
      @key_path     = key_path&.to_s
      @env          = env
    end

    def fetch(name, default_value = NO_ARG, &block)
      env_key = name.to_s.upcase

      return @env[env_key] if @env.key?(env_key)

      if (data = credentials_data)
        str_name = name.to_s
        return data[str_name] if data.key?(str_name)
      end

      return default_value unless default_value.equal?(NO_ARG)
      return yield(name) if block

      raise KeyError, "key not found: #{name.inspect}"
    end

    private

    def credentials_data
      return @credentials_data if defined?(@credentials_data)

      master_key = HanamiCredentials.read_key(env_key: @env_key, key_path: @key_path, env: @env)
      return @credentials_data = nil unless master_key
      return @credentials_data = nil unless File.exist?(@content_path)

      encrypted = EncryptedFile.new(content_path: @content_path, key: master_key)
      @credentials_data = YAML.safe_load(encrypted.read) || {}
    end
  end
end
