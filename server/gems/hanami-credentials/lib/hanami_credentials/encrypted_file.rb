# frozen_string_literal: true

module HanamiCredentials
  # AES-256-GCM file codec. On-disk format (single line):
  #   base64(iv)--base64(ciphertext)--base64(auth_tag)
  # Key must be 32 raw bytes. IV is 12 bytes (random per write). Tag is 16 bytes.
  class EncryptedFile
    CIPHER  = "aes-256-gcm"
    TAG_LEN = 16

    def initialize(content_path:, key:)
      @content_path = content_path.to_s
      @key = key
    end

    def read
      raw = File.binread(@content_path).strip
      iv_b64, ct_b64, tag_b64 = raw.split("--", 3)

      iv  = Base64.strict_decode64(iv_b64)
      ct  = Base64.strict_decode64(ct_b64)
      tag = Base64.strict_decode64(tag_b64)

      cipher = OpenSSL::Cipher.new(CIPHER)
      cipher.decrypt
      cipher.key      = @key
      cipher.iv       = iv
      cipher.auth_tag = tag
      cipher.auth_data = ""
      cipher.update(ct) + cipher.final
    end

    def write(plaintext)
      cipher = OpenSSL::Cipher.new(CIPHER)
      cipher.encrypt
      cipher.key = @key
      iv = cipher.random_iv
      cipher.auth_data = ""
      ct  = cipher.update(plaintext) + cipher.final
      tag = cipher.auth_tag(TAG_LEN)

      payload = [
        Base64.strict_encode64(iv),
        Base64.strict_encode64(ct),
        Base64.strict_encode64(tag)
      ].join("--")

      File.binwrite(@content_path, payload)
    end

    def change
      current = File.exist?(@content_path) ? read : ""
      write(yield(current))
    end
  end
end
