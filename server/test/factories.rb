# frozen_string_literal: true

require "rom/factory"
require "faker"

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
  f.created_at { Time.now }
  f.updated_at { Time.now }
end
