# auto_register: false
# frozen_string_literal: true

require "shrine"
require "shrine/storage/file_system"
require "shrine/storage/memory"

if Hanami.env?(:test)
  Shrine.storages = {
    cache: Shrine::Storage::Memory.new,
    store: Shrine::Storage::Memory.new
  }
else
  # Resolve from __dir__ so the path is cwd-invariant (mirrors config/providers/vite.rb).
  # __dir__ = <architect>/app → parent = <architect>
  root = Pathname(__dir__).parent
  Shrine.storages = {
    cache: Shrine::Storage::FileSystem.new(root.join("storage", "cache").to_s),
    store: Shrine::Storage::FileSystem.new(root.join("storage", "store").to_s)
  }
end

module Space
  module Server
    class SourceFileUploader < Shrine
      def self.store(io) = upload(io, :store).to_json
    end
  end
end
