# frozen_string_literal: true

require_relative "../test_helper"

class SourceFileUploaderTest < Minitest::Test
  def conn
    @conn ||= Space::Server::App["db.gateway"].connection
  end

  def setup
    Faker::Internet.unique.clear
    Faker::Number.unique.clear
    [:annotations, :conversation_shares, :messages, :conversations, :users].each do |t|
      conn[t].delete
    end
  end

  # G3 — storages configured at uploader load (not via provider), test env = Memory
  def test_storages_configured_as_memory_in_test
    storages = Space::Server::SourceFileUploader.storages
    assert storages.key?(:cache), "storages missing :cache"
    assert storages.key?(:store), "storages missing :store"
    assert_equal "Shrine::Storage::Memory", storages[:cache].class.name
    assert_equal "Shrine::Storage::Memory", storages[:store].class.name
  end

  # G4 — round-trip: store → repo → reload struct → open → read/each_line
  def test_round_trip_store_persist_reload_read
    content = "hello shrine\nline two\n"
    data = Space::Server::SourceFileUploader.store(StringIO.new(content))

    assert_kind_of String, data
    parsed = JSON.parse(data)
    assert parsed.key?("id")
    assert_equal "store", parsed["storage"]

    conv = Factory[:conversation]
    conversations_repo.update(conv.id, source_file_data: data)
    reloaded = conversations_repo.by_pk(conv.id)

    sf = reloaded.source_file
    refute_nil sf
    assert_instance_of Space::Server::SourceFileUploader::UploadedFile, sf

    read_bytes = sf.open { |io| io.read }
    assert_equal content, read_bytes

    lines = sf.open { |io| io.each_line.to_a }
    assert_equal ["hello shrine\n", "line two\n"], lines
  end

  # G4 — nil when unattached
  def test_source_file_nil_when_no_data
    conv = Factory[:conversation]
    reloaded = conversations_repo.by_pk(conv.id)
    assert_nil reloaded.source_file
  end

  private

  def conversations_repo = Space::Server::Repos::ConversationsRepo.new
end
