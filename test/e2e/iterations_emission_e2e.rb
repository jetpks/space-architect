#!/usr/bin/env ruby
# frozen_string_literal: true

# I16 — the emission end-to-end driver: the first natively-surfaced iteration.
#
# Run by the gem's `rake test:e2e` (see Rakefile) UNDER the all-fax-no-printer
# checkout's bundle context (cd $SPACE_E2E_AFNP_DIR && mise exec ruby@4.0.5 --
# bundle exec ruby <gem-root>/test/e2e/iterations_emission_e2e.rb <gem-root>):
# the driver boots the REAL Hanami app on a real ephemeral TCP port via
# Async::HTTP::Server + Protocol::Rack::Adapter (the ingest_falcon pattern),
# mints a real user + sat_ bearer, drives the REAL architect CLI as scrubbed-env
# subprocesses through a full loop dance on a throwaway mini-space, and reads
# the modeled record back through the server's own record read.
#
# ENV SEAM: gates/drivers run as children of the architect process, whose mise
# gem-binstub exports GEM_HOME into the child env — with that GEM_HOME the
# `bundle exec architect` subprocess double-loads bundler and crashes. The
# driver's child env therefore strips GEM_HOME/GEM_PATH (and all BUNDLE_*
# inherited from afnp's bundle, setting only BUNDLE_GEMFILE).

require "json"
require "net/http"
require "open3"
require "fileutils"
require "tmpdir"
require "yaml"
require "securerandom"

gem_root = ARGV.shift
unless gem_root && File.directory?(File.join(gem_root, "lib"))
  abort "usage: iterations_emission_e2e.rb <gem-root> — run from the all-fax-no-printer checkout under its bundle"
end
GEM_ROOT = File.expand_path(gem_root)

ENV["HANAMI_ENV"] = "test"
require "hanami/boot"
Space::Server::App.start(:redis)

require "async"
require "async/http/server"
require "async/http/endpoint"
require "protocol/rack/adapter"
require File.expand_path(File.join(Dir.pwd, "test", "factories"))

# ---- the real app on a real socket ------------------------------------------

PORT = 49600 + rand(400)
# localhost, not 127.0.0.1 — the afnp app's HostRedirect middleware 301s any
# HTTP_HOST starting with 127.0.0.1 (to keep browser/Vite on one origin); a
# machine mouth must not be redirected away from the POST.
ENDPOINT = Async::HTTP::Endpoint.parse("http://localhost:#{PORT}")
$server_stop = false
$server_ready = false

server_thread = Thread.new do
  Sync do |parent|
    task = parent.async do
      Async::HTTP::Server.new(Protocol::Rack::Adapter.new(Space::Server::App), ENDPOINT).run
    end
    parent.sleep(0.3)
    $server_ready = true
    until $server_stop
      parent.sleep 0.1
    end
    task.stop
  end
end

deadline = Time.now + 5
sleep 0.1 until $server_ready || Time.now > deadline
abort "server did not bind within 5s" unless $server_ready
at_exit { server_thread.join(2) }

HOST = "http://localhost:#{PORT}"

def http(method, path, token: nil)
  uri = URI.parse("#{HOST}#{path}")
  req = Net::HTTP.const_get(method.capitalize).new(uri)
  req["Authorization"] = "Bearer #{token}" if token
  res = Net::HTTP.start(uri.host, uri.port, open_timeout: 2, read_timeout: 5) { |h| h.request(req) }
  [res.code.to_i, res.body.to_s]
end

# ---- fixtures ----------------------------------------------------------------

SLUG = "emission-e2e-#{SecureRandom.hex(4)}"
HOME = Dir.mktmpdir("e2e-home")
ROOT = Dir.mktmpdir("e2e-space")
SPACE_DIR = File.join(ROOT, SLUG)
MINI_TITLE = "Emission E2E"
PROJECT_BRANCH = "project/emission-e2e" # the space-slug rule applied to MINI_TITLE

def fail_step(step, transcript)
  puts "FAIL: #{step}"
  puts transcript
  exit 1
end

def run_architect(*args)
  # Strip EVERY bundler-state variable: BUNDLE_*, the BUNDLER_* preserver
  # markers (BUNDLER_ORIG_* — "BUNDLER_" is not the "BUNDLE_" prefix!),
  # BUNDLER_SETUP/VERSION, GEM_HOME/GEM_PATH, RUBYOPT. An incomplete strip is
  # the corruption seam: the child's `bundle exec` re-injects BUNDLE_LOCKFILE
  # from the PARENT's bundler context while BUNDLE_GEMFILE is the gem's — an
  # inconsistent pair that makes the child re-resolve and REWRITE the parent
  # checkout's Gemfile.lock (observed: afnp's lock overwritten mid-run).
  env = {}
  ENV.each do |k, v|
    next if k.start_with?("BUNDLE_") || k.start_with?("BUNDLER_")
    next if %w[GEM_HOME GEM_PATH RUBYOPT RUBYLIB].include?(k)

    env[k] = v
  end
  env["HOME"] = HOME
  # The pinned, SELF-CONSISTENT pair (the lockfile explicitly, because the
  # exec chain re-injects BUNDLE_LOCKFILE from the parent context otherwise).
  env["BUNDLE_GEMFILE"] = File.join(GEM_ROOT, "Gemfile")
  env["BUNDLE_LOCKFILE"] = File.join(GEM_ROOT, "Gemfile.lock")
  env["SPACE_ARCHITECT_EMISSION_GLOBAL_CONFIG"] = File.join(HOME, "absent-emission.yaml")
  env["SPACE_ARCHITECT_EMISSION_HOST"] = HOST
  env["SPACE_ARCHITECT_EMISSION_TOKEN"] = $bearer

  out, err, st = Open3.capture3(env, "bundle", "exec", "ruby",
    File.join(GEM_ROOT, "exe", "architect"), *args, chdir: SPACE_DIR)
  [st.success?, st.exitstatus, out, err]
end

def expect_architect(step, *args)
  ok, code, out, err = run_architect(*args)
  fail_step(step, "exit=#{code}\n--- stdout ---\n#{out}\n--- stderr ---\n#{err}") unless ok
  puts "step ok: #{step} (exit 0)"
  [out, err]
end

begin
  # Sanity: the structured-iterations tables must exist (run `hanami db
  # prepare` in the afnp checkout first — the test:e2e gate does).
  conn = Space::Server::App["db.gateway"].connection
  unless conn.table_exists?(:iterations) && conn.table_exists?(:gate_results)
    abort "the afnp test database is not prepared — run (cd $SPACE_E2E_AFNP_DIR && mise exec ruby@4.0.5 -- bundle exec hanami db prepare)"
  end

  # 1. Real user + real sat_ bearer (the ingest_falcon minting pattern).
  user = Factory[:user]
  $bearer, = Space::Server::App["repos.api_tokens_repo"].create(user_id: user.id, name: "e2e-emission")
  puts "step ok: minted user ##{user.id} + sat_ bearer"

  # 2. Throwaway mini-space: git init, minimal space.yaml, tracked repos/demo-repo.
  FileUtils.mkdir_p([File.join(SPACE_DIR, "architecture"), File.join(SPACE_DIR, "repos"),
                     File.join(SPACE_DIR, "tmp"), HOME])
  space_yaml = {
    "version" => 1, "id" => SLUG, "title" => MINI_TITLE, "status" => "active",
    "created_at" => "2026-06-19T00:00:00Z", "updated_at" => "2026-06-19T00:00:00Z",
    "repos" => ["demo-repo"], "notes" => [], "tickets" => [], "tags" => []
  }
  File.write(File.join(SPACE_DIR, "space.yaml"), YAML.dump(space_yaml))

  def git(dir, *args)
    out, err, st = Open3.capture3("git", "-C", dir, *args)
    st.success? || (puts "git failed: #{args.inspect}\n#{err}"; exit 1)
    out
  end
  git(SPACE_DIR, "init", "-q", "-b", "main")
  git(SPACE_DIR, "config", "user.name", "E2E Driver")
  git(SPACE_DIR, "config", "user.email", "e2e@example.com")
  git(SPACE_DIR, "add", "space.yaml")
  git(SPACE_DIR, "commit", "-q", "-m", "mini-space")

  repo_dir = File.join(SPACE_DIR, "repos", "demo-repo")
  FileUtils.mkdir_p(repo_dir)
  git(repo_dir, "init", "-q", "-b", "main")
  git(repo_dir, "config", "user.name", "E2E Driver")
  git(repo_dir, "config", "user.email", "e2e@example.com")
  File.write(File.join(repo_dir, "README.md"), "# demo-repo\n")
  git(repo_dir, "add", "README.md")
  git(repo_dir, "commit", "-q", "-m", "init")
  base_sha = git(repo_dir, "rev-parse", "main").strip
  puts "step ok: mini-space built at #{SPACE_DIR}"

  # 3. SMOKE — verify the exact child invocation shape FIRST.
  smoke_out, = expect_architect("smoke: architect status", "status")
  fail_step("smoke", smoke_out) unless smoke_out.include?("Project status")
  puts "step ok: smoke — child invocation shape verified"

  # 4. The loop dance (spec section (spec with ```lanes; ONE sentinel gate)
  #    → freeze --skip-rehearse → provision → in-touch write → gate --lane →
  #    evidence → verdict (with ```rulings) → integrate).
  spec_body = <<~SPEC
    - Objective — the first natively-surfaced iteration.
    ```lanes
    - name: lane-a
      repo: demo-repo
      touch: ["feature.rb"]
    ```
  SPEC
  ac_body = <<~AC
    **AC1.** the sentinel file exists.
    ```gates
    - id: G0
      ac: AC1
      cmd: "test -f feature.rb"
      expect:
        exit_code: 0
    ```
  AC
  verdict_body = <<~VERDICT
    Gates green, lane clean.
    ```rulings
    ac_rulings:
      - ac: AC1
        ruling: PASS
        note: sentinel present
    phase0_resolutions:
      - topic: child env gem leak
        resolution: scrubbed GEM_HOME in the driver's child env
    ```
  VERDICT

  spec_file = File.join(SPACE_DIR, "tmp", "spec.md")
  ac_file = File.join(SPACE_DIR, "tmp", "ac.md")
  verdict_file = File.join(SPACE_DIR, "tmp", "verdict.md")
  File.write(spec_file, spec_body)
  File.write(ac_file, ac_body)
  File.write(verdict_file, verdict_body)

  expect_architect("init", "init")
  expect_architect("new", "new", "dance")
  expect_architect("spec section", "section", "dance", "specification", "--from", spec_file)
  expect_architect("ac section", "section", "dance", "acceptance-criteria", "--from", ac_file)
  expect_architect("freeze", "freeze", "dance", "--skip-rehearse", "e2e driver — rehearsal lives in the gem suite")
  expect_architect("provision", "provision", "dance", "--base", "main")

  worktree = File.join(SPACE_DIR, "build", "I01-dance-lane-a", "wt")
  File.write(File.join(worktree, "feature.rb"), "puts 'sentinel'\n")
  puts "step ok: in-touch file write"

  expect_architect("gate --lane", "gate", "dance", "lane-a")
  report_dir = File.join(SPACE_DIR, "build", "I01-dance-lane-a")
  File.write(File.join(report_dir, "report.md"), "raw numbers\nSTATUS: COMPLETE\n")
  expect_architect("evidence", "evidence", "dance", "--lane", "lane-a")
  expect_architect("verdict", "verdict", "dance", "continue", "--from", verdict_file)
  expect_architect("integrate", "integrate", "dance", "--lanes", "lane-a")

  freeze_sha = YAML.safe_load(File.read(File.join(SPACE_DIR, "space.yaml")))
                 .dig("project", "iterations", 0, "freeze_sha")
  merge_sha = git(repo_dir, "rev-parse", PROJECT_BRANCH).strip
  puts "step ok: full loop dance (freeze #{freeze_sha[0, 8]}, merge #{merge_sha[0, 8]})"

  # 5. Over the socket: the full modeled record, read through the server.
  # The server names the space by the X-Space-Slug header — the mini-space's
  # slugified TITLE, scoped to the minted user.
  space_id = conn[:spaces].where(user_id: user.id, slug: "emission-e2e").first&.fetch(:id)
  fail_step("space row", "no space row for #{SLUG} — the structured path did not create it") unless space_id
  code1, body1 = http("get", "/spaces/#{space_id}/iterations/1", token: $bearer)
  fail_step("record read", "GET rc=#{code1} body=#{body1}") unless code1 == 200
  record = JSON.parse(body1)

  expectations = lambda do |rec|
    it = rec.fetch("iteration")
    checks = {
      "iteration.ordinal"     => [1, it.fetch("ordinal")],
      "iteration.name"        => ["dance", it.fetch("name")],
      "iteration.freeze_sha"  => [freeze_sha, it.fetch("freeze_sha")],
      "iteration.branch"      => ["main", it.fetch("branch")],
      "iteration.status"      => ["integrated", it.fetch("status")],
      "gate.count"            => [1, rec["iteration"]["gates"].size],
      "gate.id"               => ["G0", rec["iteration"]["gates"].first&.fetch("gate_id")],
      "gate.cmd"              => ["test -f feature.rb", rec["iteration"]["gates"].first&.fetch("cmd")],
      "lane.name"             => ["lane-a", rec["iteration"]["lanes"].first&.fetch("name")],
      "lane.status"           => ["integrated", rec["iteration"]["lanes"].first&.fetch("status")],
      "lane.repo"             => ["demo-repo", rec["iteration"]["lanes"].first&.fetch("repo")],
      "lane.base_sha"         => [base_sha, rec["iteration"]["lanes"].first&.fetch("base_sha")],
      "lane.merge_sha"        => [merge_sha, rec["iteration"]["lanes"].first&.fetch("merge_sha")],
      "lane.integration_branch" => [PROJECT_BRANCH, rec["iteration"]["lanes"].first&.fetch("integration_branch")],
      "lane.touch_set"        => [["feature.rb"], rec["iteration"]["lanes"].first&.fetch("touch_set")],
      "gate_result.gate_id"   => ["G0", rec["iteration"]["lanes"].first["gate_results"].first&.fetch("gate_id")],
      "gate_result.status"    => ["pass", rec["iteration"]["lanes"].first["gate_results"].first&.fetch("status")],
      "verdict.decision"      => ["continue", rec.dig("iteration", "verdict_detail", "decision")],
      "verdict.ac_rulings"    => [["AC1"], [rec.dig("iteration", "verdict_detail", "ac_rulings").to_a.first&.fetch("ac")]],
      "verdict.ruling"        => ["PASS", rec.dig("iteration", "verdict_detail", "ac_rulings").to_a.first&.fetch("ruling")],
      "verdict.phase0"        => ["child env gem leak",
                                  rec.dig("iteration", "verdict_detail", "phase0_resolutions").to_a.first&.fetch("topic")]
    }
    checks
  end

  bad = expectations.call(record).reject { |_k, (want, got)| want == got }
  fail_step("record asserts", "mismatched: #{bad.keys.join(', ')}\n#{JSON.pretty_generate(record)}") unless bad.empty?
  puts "step ok: modeled record read back through the server's own record read"

  # 6. `emit --facet freeze` — the pinned replay command. The freeze mouth
  #    re-upserts iteration scalars (status "frozen"), so assert: the gates
  #    re-applied WITHOUT duplication and lane/verdict untouched.
  emit_out, emit_err = expect_architect("emit --facet freeze", "emit", "dance", "--facet", "freeze")
  fail_step("emit freeze output", emit_out) unless emit_out.include?("emitted freeze →")
  code2, body2 = http("get", "/spaces/#{space_id}/iterations/1", token: $bearer)
  fail_step("post-emit read", "GET rc=#{code2}") unless code2 == 200
  rec2 = JSON.parse(body2)
  stable = expectations.call(rec2).reject do |k, _|
    k.start_with?("iteration.status") # the freeze replay re-stamps status "frozen" — see report
  end
  bad = stable.reject { |_k, (want, got)| want == got }
  fail_step("post-emit-freeze asserts", "mismatched: #{bad.keys.join(', ')}\n#{JSON.pretty_generate(rec2)}") unless bad.empty?
  fail_step("freeze replay status", "expected status 'frozen' after the freeze replay, got #{rec2['iteration']['status']}") unless rec2["iteration"]["status"] == "frozen"
  puts "step ok: emit --facet freeze replayed idempotently (gates not duplicated, status re-stamped)"

  # 7. Full-facet replay restores the integrated state byte-stably.
  emit_all_out, = expect_architect("emit (all)", "emit", "dance")
  %w[freeze lane verdict integration].each do |facet|
    fail_step("emit all output", emit_all_out) unless emit_all_out.include?("emitted #{facet} →")
  end
  code3, body3 = http("get", "/spaces/#{space_id}/iterations/1", token: $bearer)
  fail_step("final read", "GET rc=#{code3}") unless code3 == 200
  # integrated_at is re-stamped by the server on EVERY integration upsert (its
  # own scalar semantics) — the one documented volatile field of a full
  # replay; everything else must be byte-stable and nothing duplicated.
  norm = lambda do |body|
    rec = JSON.parse(body)
    rec["iteration"]["lanes"]&.each { |l| l.delete("integrated_at") }
    JSON.generate(rec)
  end
  fail_step("byte-stability", "record changed across the full replay:\nBEFORE:\n#{body1}\nAFTER:\n#{body3}") unless norm.call(body3) == norm.call(body1)
  puts "step ok: full-facet replay is byte-stable (idempotent re-send duplicates nothing)"

  puts "E2E_EMISSION_OK"
  $e2e_ok = true
ensure
  # Cleanup: the run's rows cascade off the user row; tmp dirs are throwaway.
  if user
    begin
      conn[:users].where(id: user.id).delete
    rescue StandardError => e
      puts "cleanup warning: #{e.class}: #{e.message}"
    end
  end
  FileUtils.rm_rf([ROOT, HOME])
  $server_stop = true
end

exit($e2e_ok ? 0 : 1)
