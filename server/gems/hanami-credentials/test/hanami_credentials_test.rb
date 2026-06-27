# frozen_string_literal: true

require_relative "test_helper"

class EncryptedFileTest < Minitest::Test
  def setup
    @key = OpenSSL::Random.random_bytes(32)
    @dir = Dir.mktmpdir
    @path = File.join(@dir, "creds.yml.enc")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def ef(key = @key)
    HanamiCredentials::EncryptedFile.new(content_path: @path, key: key)
  end

  # G2(a): round-trip recovers exact plaintext
  def test_round_trip
    ef.write("session_secret: hunter2\n")
    assert_equal "session_secret: hunter2\n", ef.read
  end

  # G2(b): per-write random IV — same key+plaintext produces distinct ciphertexts
  def test_distinct_ciphertexts_random_iv
    ef.write("foo: bar")
    first = File.read(@path)
    ef.write("foo: bar")
    second = File.read(@path)
    refute_equal first, second
  end

  # G2(b): IV is 12 bytes, auth tag is 16 bytes — verified from encoded payload
  def test_iv_and_tag_lengths
    ef.write("test: value")
    parts = File.read(@path).split("--")
    assert_equal 12, Base64.strict_decode64(parts[0]).bytesize, "IV must be 12 bytes"
    assert_equal 16, Base64.strict_decode64(parts[2]).bytesize, "auth tag must be 16 bytes"
  end

  # G2(c): tamper with ciphertext bytes → raises OpenSSL::Cipher::CipherError
  def test_tamper_raises
    ef.write("secret: value")
    parts = File.read(@path).split("--")
    ct = Base64.strict_decode64(parts[1])
    ct.setbyte(0, ct.getbyte(0) ^ 0xFF)
    parts[1] = Base64.strict_encode64(ct)
    File.write(@path, parts.join("--"))
    assert_raises(OpenSSL::Cipher::CipherError) { ef.read }
  end

  # G2(c): wrong key → raises OpenSSL::Cipher::CipherError
  def test_wrong_key_raises
    ef.write("secret: value")
    wrong = OpenSSL::Random.random_bytes(32)
    assert_raises(OpenSSL::Cipher::CipherError) { ef(wrong).read }
  end

  def test_change_helper_read_modify_write
    ef.write("foo: original\n")
    ef.change { |_| "foo: updated\n" }
    assert_equal "foo: updated\n", ef.read
  end
end

class StoreTest < Minitest::Test
  def setup
    @dir      = Dir.mktmpdir
    @path     = File.join(@dir, "creds.yml.enc")
    @key_raw  = OpenSSL::Random.random_bytes(32)
    @key_hex  = @key_raw.unpack1("H*")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def write_creds(hash)
    ef = HanamiCredentials::EncryptedFile.new(content_path: @path, key: @key_raw)
    ef.write(YAML.dump(hash))
  end

  def store(env = {})
    HanamiCredentials::Store.new(
      content_path: @path,
      env_key: "TEST_MASTER_KEY",
      key_path: nil,
      env: env
    )
  end

  def store_with_key(env = {})
    store(env.merge("TEST_MASTER_KEY" => @key_hex))
  end

  # G1(a): returns present value
  def test_fetch_returns_present_env_value
    s = store("SOME_SETTING" => "found_it")
    assert_equal "found_it", s.fetch(:some_setting)
  end

  # G1(a): returns default when absent
  def test_fetch_returns_default_when_absent
    assert_equal "fallback", store.fetch(:missing, "fallback")
  end

  # G1(a): yields block when absent
  def test_fetch_yields_block_when_absent
    result = store.fetch(:missing) { |k| "block_#{k}" }
    assert_equal "block_missing", result
  end

  # G1(a): raises KeyError when absent with no default or block
  def test_fetch_raises_key_error_when_absent
    assert_raises(KeyError) { store.fetch(:missing) }
  end

  # G3(a): ENV-first — ENV value wins over file value
  def test_env_first_precedence
    write_creds("session_secret" => "from_file")
    s = store_with_key("SESSION_SECRET" => "from_env")
    assert_equal "from_env", s.fetch(:session_secret)
  end

  # G3(b): file fallback — key in file only resolves through store
  def test_file_fallback
    write_creds("session_secret" => "from_file_only")
    s = store_with_key
    assert_equal "from_file_only", s.fetch(:session_secret)
  end

  # G3(b): file fallback with default — file value wins over default
  def test_file_fallback_wins_over_default
    write_creds("db_pass" => "secret_from_file")
    s = store_with_key
    assert_equal "secret_from_file", s.fetch(:db_pass, "default_val")
  end

  # G3(c): no-key degradation — env still resolves, no crash
  def test_no_key_degradation_env_resolves
    s = store("SOME_KEY" => "env_value")
    assert_equal "env_value", s.fetch(:some_key)
  end

  # G3(c): no-key degradation — missing key raises KeyError (not crash on file)
  def test_no_key_degradation_missing_raises_key_error
    assert_raises(KeyError) { store.fetch(:totally_missing) }
  end

  # G3(c): no-key degradation — default is returned when no key and key absent from env
  def test_no_key_degradation_returns_default
    assert_equal "d", store.fetch(:missing, "d")
  end
end

class ReadKeyTest < Minitest::Test
  def setup
    @dir     = Dir.mktmpdir
    @key_raw = OpenSSL::Random.random_bytes(32)
    @key_hex = @key_raw.unpack1("H*")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_reads_from_env
    key = HanamiCredentials.read_key(env_key: "MASTER_KEY", key_path: nil, env: {"MASTER_KEY" => @key_hex})
    assert_equal @key_raw, key
  end

  def test_reads_from_file
    key_path = File.join(@dir, "master.key")
    File.write(key_path, @key_hex)
    key = HanamiCredentials.read_key(env_key: "MASTER_KEY", key_path: key_path, env: {})
    assert_equal @key_raw, key
  end

  def test_env_wins_over_file
    other_hex = OpenSSL::Random.random_bytes(32).unpack1("H*")
    key_path  = File.join(@dir, "master.key")
    File.write(key_path, other_hex)
    key = HanamiCredentials.read_key(env_key: "MASTER_KEY", key_path: key_path, env: {"MASTER_KEY" => @key_hex})
    assert_equal @key_raw, key
  end

  def test_returns_nil_when_absent
    assert_nil HanamiCredentials.read_key(env_key: "MASTER_KEY", key_path: nil, env: {})
  end

  def test_returns_nil_when_key_file_missing
    assert_nil HanamiCredentials.read_key(
      env_key: "MASTER_KEY",
      key_path: File.join(@dir, "nonexistent.key"),
      env: {}
    )
  end
end
