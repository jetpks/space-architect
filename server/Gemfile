# frozen_string_literal: true

source "https://rubygems.org"

ruby "4.0.5"

# In-tree gems
gem "hanami-credentials", path: "gems/hanami-credentials"
gem "hanami-healthcheck", path: "gems/hanami-healthcheck"
gem "hanami-force-ssl", path: "gems/hanami-force-ssl"
gem "inertia-hanami", path: "gems/inertia-hanami"
gem "vite-hanami", path: "gems/vite-hanami"

# Authentication
gem "omniauth"
gem "omniauth-github"

# Web framework
gem "hanami", "2.3.2"
gem "hanami-db", "2.3.0"
gem "hanami-controller", "2.3.2"
gem "hanami-router", "2.3.1"

# Async server
gem "falcon", "0.55.5"

# Async job queue (web side enqueues, worker process dequeues)
gem "async-job", "0.11.1"
gem "async-job-processor-redis", "0.3.1"
gem "async-redis", "0.13.1"

# File attachments
gem "shrine", "3.7.1"

# Persistence
gem "rom", "5.4.3"
gem "rom-sql", "3.7.0"
gem "sequel", "5.105.0"
gem "pg", "1.6.3"

# dry-rb suite
gem "dry-types", "1.9.1"
gem "dry-validation", "1.11.1"
gem "dry-monads", "1.10.0"
gem "dry-operation", ">= 1.0.1"

# CLI + build
gem "hanami-cli", "2.3.5"
gem "rake"

# Former stdlib gems removed in Ruby 4.0
gem "ostruct"
gem "logger"
gem "bigdecimal"
gem "base64"

group :development, :test do
  gem "dotenv"
end

group :test do
  gem "minitest"
  gem "rom-factory", "0.13.0"
  gem "faker"
end
