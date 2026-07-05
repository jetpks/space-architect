# frozen_string_literal: true

require_relative "test_helper"

class SpaceTest < Space::ArchitectTest
  PROJECT_BLOCK = { "status" => "active", "current_iteration" => "I01-foo", "iterations" => [{ "name" => "I01-foo" }] }.freeze
  EMPTY_PROJECT_BLOCK = { "status" => "active", "current_iteration" => nil, "iterations" => [] }.freeze
  OTHER_PROJECT_BLOCK = { "status" => "active", "current_iteration" => "I02-bar", "iterations" => [{ "name" => "I02-bar" }] }.freeze

  def deep_copy(hash)
    Marshal.load(Marshal.dump(hash))
  end

  def test_v1a_legacy_architect_key_loads_readable_and_saves_canonical
    space = write_and_load("version" => 1, "id" => "x", "title" => "x", "architect" => PROJECT_BLOCK)

    assert_equal PROJECT_BLOCK, space.architect
    assert_equal 2, space.data["version"]
    refute space.data.key?("architect")

    space.save
    on_disk = YAML.safe_load(space.metadata_path.read, aliases: false)
    assert_equal PROJECT_BLOCK, on_disk["project"]
    assert_equal 2, on_disk["version"]
    refute on_disk.key?("architect")
  end

  def test_v1b_project_key_loads_unchanged_and_bumps_version_on_save
    space = write_and_load("version" => 1, "id" => "x", "title" => "x", "project" => PROJECT_BLOCK)

    assert_equal PROJECT_BLOCK, space.architect
    assert_equal 2, space.data["version"]

    space.save
    on_disk = YAML.safe_load(space.metadata_path.read, aliases: false)
    assert_equal PROJECT_BLOCK, on_disk["project"]
    assert_equal 2, on_disk["version"]
  end

  def test_canonical_v2_space_is_idempotent_under_load_save_load
    space = write_and_load("version" => 2, "id" => "x", "title" => "x", "project" => PROJECT_BLOCK)
    space.save
    first_bytes = space.metadata_path.read

    reloaded = Space::Core::Space.load(space.path)
    reloaded.save
    second_bytes = reloaded.metadata_path.read

    assert_equal first_bytes, second_bytes
    assert_equal PROJECT_BLOCK, reloaded.architect
    assert_equal 2, reloaded.data["version"]
  end

  def test_both_keys_with_empty_project_and_nonempty_architect_self_heals
    space = write_and_load(
      "version" => 1, "id" => "x", "title" => "x",
      "architect" => PROJECT_BLOCK, "project" => EMPTY_PROJECT_BLOCK
    )

    assert_equal PROJECT_BLOCK, space.architect
    refute space.data.key?("architect")

    space.save
    on_disk = YAML.safe_load(space.metadata_path.read, aliases: false)
    assert_equal PROJECT_BLOCK, on_disk["project"]
    refute on_disk.key?("architect")
  end

  def test_both_keys_with_differing_nonempty_blocks_raises
    dir = Dir.mktmpdir("space-schema-test")
    write_yaml(dir, "version" => 1, "id" => "x", "title" => "x",
                     "architect" => PROJECT_BLOCK, "project" => OTHER_PROJECT_BLOCK)

    error = assert_raises(Space::Core::Error) { Space::Core::Space.load(dir) }
    assert_includes error.message, "space.yaml"
    assert_includes error.message, "architect"
    assert_includes error.message, "project"
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  def test_both_keys_with_identical_nonempty_blocks_loads_without_raising
    space = write_and_load(
      "version" => 1, "id" => "x", "title" => "x",
      "architect" => PROJECT_BLOCK, "project" => deep_copy(PROJECT_BLOCK)
    )

    assert_equal PROJECT_BLOCK, space.architect
    refute space.data.key?("architect")
  end

  def test_future_schema_version_raises
    dir = Dir.mktmpdir("space-schema-test")
    write_yaml(dir, "version" => 3, "id" => "x", "title" => "x", "project" => PROJECT_BLOCK)

    error = assert_raises(Space::Core::Error) { Space::Core::Space.load(dir) }
    assert_includes error.message, "3"
    assert_includes error.message, "2"
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  private

  def write_yaml(dir, data)
    File.write(File.join(dir, Space::Core::Space::METADATA_FILE), YAML.dump(data))
  end

  def write_and_load(data)
    @dirs ||= []
    dir = Dir.mktmpdir("space-schema-test")
    @dirs << dir
    write_yaml(dir, data)
    Space::Core::Space.load(dir)
  end

  def teardown
    (@dirs || []).each { |dir| FileUtils.rm_rf(dir) }
  end
end
