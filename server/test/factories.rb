# frozen_string_literal: true

require "rom/factory"
require "faker"

# Force-load ConversationShare before ROM::Factory accesses db.rom (which triggers
# ROM's struct compiler to create Space::Server::Structs::Space, after which any
# file loaded inside module Space::Server::Structs that references Space::Server::...
# would find Space resolving to the struct instead of the ::Space module).
_ = Space::Server::Structs::ConversationShare

Factory = ROM::Factory.configure do |c|
  c.rom = Space::Server::App["db.rom"]
end

Factory.define(:user) do |f|
  f.github_uid    { Faker::Internet.unique.uuid }
  f.username      { Faker::Internet.unique.username }
  f.name          { Faker::Name.name }
  f.email         { Faker::Internet.unique.email }
  f.avatar_url    { Faker::Internet.url }
  f.github_orgs   { [] }
  f.created_at    { Time.now }
  f.updated_at    { Time.now }
end

Factory.define(:conversation) do |f|
  f.association(:user)
  f.status    { 0 }
  f.published { false }
  f.created_at { Time.now }
  f.updated_at { Time.now }
end

Factory.define(:message) do |f|
  f.association(:conversation)
  f.role     { "user" }
  f.content  { [] }
  f.position { Faker::Number.unique.between(from: 1, to: 9999) }
  f.published { false }
  f.created_at { Time.now }
  f.updated_at { Time.now }
end

Factory.define(:annotation) do |f|
  f.association(:conversation)
  f.association(:user)
  f.body        { Faker::Lorem.sentence }
  f.target_kind { "conversation" }
  f.created_at  { Time.now }
  f.updated_at  { Time.now }
end

Factory.define(:conversation_share) do |f|
  f.association(:conversation)
  f.github_id    { Faker::Internet.uuid }
  f.github_login { Faker::Internet.unique.username }
  f.grantee_kind { "user" }
  f.access       { "view" }
  f.created_at   { Time.now }
  f.updated_at   { Time.now }
end

Factory.define(:run) do |f|
  f.association(:user)
  f.status    { 0 }
  f.published { false }
  f.role      { "builder" }
  f.created_at { Time.now }
  f.updated_at { Time.now }
end

Factory.define(:job) do |f|
  f.association(:user)
  f.spec {
    {
      "harness" => { "type" => "claude", "model" => "sonnet", "backend" => { "base_url" => "https://api.example.com" } },
      "prompt" => "do the thing",
      "environment" => { "env" => {}, "secrets" => [], "deps" => [], "permissions" => { "network" => false, "mounts" => [] } }
    }
  }
  f.status    { "queued" }
  f.created_at { Time.now }
  f.updated_at { Time.now }
end

Factory.define(:profile) do |f|
  f.association(:user)
  f.name         { Faker::Lorem.unique.word }
  f.harness_type { "claude" }
  f.spec {
    {
      "harness" => { "type" => "claude", "model" => "sonnet", "backend" => { "base_url" => "https://api.example.com" } },
      "environment" => { "env" => {}, "secrets" => [], "deps" => [], "npm" => [], "files" => [], "permissions" => { "network" => false, "mounts" => [] } }
    }
  }
  f.created_at { Time.now }
  f.updated_at { Time.now }
end

Factory.define(:space) do |f|
  f.association(:user)
  f.slug      { Faker::Internet.unique.slug }
  f.title     { Faker::Lorem.words(number: 3).join(" ") }
  f.status    { "active" }
  f.repos     { [] }
  f.created_at { Time.now }
  f.updated_at { Time.now }
end

Factory.define(:iteration) do |f|
  f.association(:space)
  f.ordinal    { Faker::Number.unique.between(from: 1, to: 999) }
  f.name       { Faker::Lorem.words(number: 2).join("-") }
  f.created_at { Time.now }
  f.updated_at { Time.now }
end

Factory.define(:artifact) do |f|
  f.association(:space)
  f.kind       { "brief" }
  f.path       { "architecture/#{Faker::Internet.unique.slug}.md" }
  f.raw        { "# Test Artifact\n\nContent." }
  f.title      { "Test Artifact" }
  f.created_at { Time.now }
  f.updated_at { Time.now }
end
