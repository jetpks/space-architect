#!/usr/bin/env ruby
# frozen_string_literal: true

# Live end-to-end proof of the inference-job pipeline (BRIEF §8.2–§8.6):
# real `container` sandboxes from the claude-base image, the real `claude`
# harness, real HTTP enqueue with the Bearer ingest token, the supervised
# falcon topology, and a live backend.
#
# Env:
#   LIVE_PROOF_BASE_URL  backend base url         (default https://studio.slush.systems)
#   LIVE_PROOF_MODEL     harness model            (default qwen3-27b-optiq)
#   LIVE_PROOF_KEY_REF   op:// ref → backend.api_key_ref; resolved by `op read`
#                        at exec time, hygiene-swept afterwards. Absent →
#                        gateway mode: a dummy ANTHROPIC_API_KEY rides
#                        environment.env openly (the harness refuses headless
#                        runs without a key; the gateway applies no request
#                        auth) — NOT a secret.
#   LIVE_PROOF_TIMEOUT   per-job deadline seconds (default 600 — local 27B inference)
#   JOB_ENV_BASE_IMAGE   sandbox base image       (default space-claude-base:v1)
#
# Sequence: preflight → job A enqueued over real HTTP BEFORE falcon boots
# (§8.6 queued-job-survives) → falcon boots → job B enqueued while A runs,
# both observed `running` simultaneously (§8.5) → SSE display event observed
# mid-run (§8.3) → both succeed, distinct conversations, no cross-talk →
# job C's executor child SIGKILLed mid-run; lease expiry + sweep drives the
# job to a terminal state under the restarted child (§8.6) → anthropic mode
# only: resolved-secret hygiene sweep (§2.4/§8.4) → SIGTERM, zero orphans,
# zero leftover sandbox containers.
#
# Usage: cd server && HANAMI_ENV=development bundle exec ruby bin/live_proof.rb
# Exit 0 = every assertion held ("LIVE PROOF OK"); exit 1 = FAIL (stderr).

require "json"
require "net/http"
require "open3"
require "rbconfig"
require "securerandom"
require "socket"
require "time"
require "timeout"
require "uri"
require_relative "../lib/space/server/jobs/env_image"

SERVER_DIR = File.expand_path("..", __dir__)

BASE_URL   = ENV.fetch("LIVE_PROOF_BASE_URL", "https://studio.slush.systems")
MODEL      = ENV.fetch("LIVE_PROOF_MODEL", "qwen3-27b-optiq")
KEY_REF    = ENV["LIVE_PROOF_KEY_REF"]
JOB_WAIT   = Integer(ENV.fetch("LIVE_PROOF_TIMEOUT", "600"))
BASE_IMAGE = ENV.fetch("JOB_ENV_BASE_IMAGE", Space::Server::Jobs::EnvImage::DEFAULT_BASE_IMAGE)

CANONICAL_BASE_TAG = Space::Server::Jobs::EnvImage::DEFAULT_BASE_IMAGE
BASE_IMAGE_DIR     = File.join(SERVER_DIR, "images", "claude-base")

WEB_PORT     = 3000
PREBOOT_PORT = 3001
BOOT_WAIT    = 45   # falcon host + children
STOP_WAIT    = 15   # graceful shutdown
BUILD_WAIT   = 900  # base image build (npm install)
SWEEP_WAIT   = 180  # lease expiry (60 s) + sweep tick + supervisor restart slack
SSE_WINDOW   = JOB_WAIT
DUMMY_KEY    = "dummy-gateway-key-not-a-secret"

GATEWAY_MODE = KEY_REF.nil?
INGEST_TOKEN = SecureRandom.hex(32)

def fail!(msg)
  $stderr.puts "LIVE PROOF FAIL: #{msg}"
  exit 1
end

def log(msg)
  puts "[live_proof] #{msg}"
  $stdout.flush
end

def await(desc, deadline:, interval: 0.5)
  dl = Time.now + deadline
  until Time.now > dl
    result = yield
    return result if result
    sleep interval
  end
  fail! "timed out after #{deadline}s waiting for #{desc}"
end

# --- container helpers (explicit timeouts on every invocation) --------------

def container(*argv, timeout: 60)
  Timeout.timeout(timeout) { Open3.capture2e("container", *argv) }
rescue Timeout::Error
  fail! "`container #{argv.join(' ')}` exceeded #{timeout}s"
end

def sandbox_rows
  out, status = container("ls", "-a")
  fail! "`container ls` failed — is `container system start` needed?\n#{out}" unless status.success?
  out.lines.select { |l| l.include?("space-job-env") }
end

# ---------------------------------------------------------------------------
# Preflight (fail fast, before any state is created)
# ---------------------------------------------------------------------------
ENV["HANAMI_ENV"] ||= "development"
ENV["INGEST_TOKEN"] = INGEST_TOKEN
ENV["JOB_ENV_BASE_IMAGE"] = BASE_IMAGE

log "mode=#{GATEWAY_MODE ? 'gateway' : 'anthropic'} base_url=#{BASE_URL} model=#{MODEL} job_wait=#{JOB_WAIT}s"

resolved_secret = nil
unless GATEWAY_MODE
  resolved_secret = IO.popen(["op", "read", KEY_REF], &:read).chomp
  fail! "op read #{KEY_REF} failed" unless $?.success? && !resolved_secret.empty?
  log "resolved backend key via op read (#{resolved_secret.length} chars, held in memory only)"
end

# Gateway reachable from the HOST — never debug the studio, just report.
models_uri = URI("#{BASE_URL}/v1/models")
begin
  req = Net::HTTP::Get.new(models_uri)
  unless GATEWAY_MODE
    req["x-api-key"] = resolved_secret
    req["anthropic-version"] = "2023-06-01"
  end
  resp = Net::HTTP.start(models_uri.host, models_uri.port, use_ssl: models_uri.scheme == "https", open_timeout: 10, read_timeout: 20) { |h| h.request(req) }
  fail! "backend preflight GET #{models_uri} → HTTP #{resp.code}" unless resp.code == "200"
  if GATEWAY_MODE
    ids = JSON.parse(resp.body).fetch("data", []).map { |m| m["id"] }
    fail! "model #{MODEL} not registered on gateway (got: #{ids.join(', ')})" unless ids.include?(MODEL)
  end
  log "backend reachable from host — GET /v1/models → 200#{GATEWAY_MODE ? ", #{MODEL} registered" : ''}"
rescue SystemCallError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError => e
  fail! "backend unreachable from host: #{e.class}: #{e.message}"
end

fail! "leftover sandbox containers present before start:\n#{sandbox_rows.join}" unless sandbox_rows.empty?

# Base image present-or-built (canonical tag only — an operator override must already exist).
_, present = container("image", "inspect", BASE_IMAGE)
unless present.success?
  fail! "base image #{BASE_IMAGE} missing and not the canonical tag — build it first" unless BASE_IMAGE == CANONICAL_BASE_TAG
  log "base image #{BASE_IMAGE} missing — building from #{BASE_IMAGE_DIR} (≤#{BUILD_WAIT}s)"
  out, built = container("build", "-f", File.join(BASE_IMAGE_DIR, "Dockerfile"), "-t", BASE_IMAGE, BASE_IMAGE_DIR, timeout: BUILD_WAIT)
  fail! "base image build failed:\n#{out}" unless built.success?
end
log "base image #{BASE_IMAGE} present"

[WEB_PORT, PREBOOT_PORT].each do |port|
  begin
    TCPSocket.new("localhost", port).close
    fail! "port #{port} already in use"
  rescue Errno::ECONNREFUSED
    # free
  end
end
log "ports #{WEB_PORT}/#{PREBOOT_PORT} free"

# The ingest user must exist BEFORE this process boots Hanami: settings read
# INGEST_USER_ID from ENV exactly once at provider boot, so a subprocess
# creates the user first.
user_script = <<~RUBY
  require "hanami/boot"
  require "securerandom"
  user = Space::Server::Repos::UsersRepo.new.create(
    github_uid:  SecureRandom.uuid,
    username:    "live-proof-\#{SecureRandom.hex(4)}",
    name:        "Live Proof Ingest",
    email:       "live-proof@example.com",
    avatar_url:  "https://example.com/avatar.png",
    github_orgs: [],
    created_at:  Time.now,
    updated_at:  Time.now
  )
  puts "LIVE_PROOF_USER_ID=\#{user.id}"
RUBY
out, status = Open3.capture2e(RbConfig.ruby, "-e", user_script, chdir: SERVER_DIR)
user_id = out[/LIVE_PROOF_USER_ID=(\d+)/, 1]
fail! "ingest user creation failed:\n#{out}" unless status.success? && user_id
ENV["INGEST_USER_ID"] = user_id
log "ingest user id=#{user_id} (token configured via ENV)"

# ---------------------------------------------------------------------------
# Boot Hanami in THIS process (fixtures + DB assertions).
# ---------------------------------------------------------------------------
Dir.chdir(SERVER_DIR)
require "hanami/boot"
require "async"
require "async/http/endpoint"
require "async/http/server"
require "async/redis"
require "async/redis/endpoint"
require "protocol/rack"
require "rack/utils"

JOBS_REPO     = Space::Server::Repos::JobsRepo.new
RUNS_REPO     = Space::Server::Repos::RunsRepo.new
MESSAGES_REPO = Space::Server::Repos::MessagesRepo.new

redis_ep = ENV["REDIS_URL"] ? Async::Redis::Endpoint.parse(ENV["REDIS_URL"]) : Async::Redis.local_endpoint
Sync do
  client = Async::Redis::Client.new(redis_ep)
  client.call("PING")
  client.close
end
log "Redis OK"

busy = JOBS_REPO.jobs.where(status: %w[queued running]).to_a
unless busy.empty?
  fail! "jobs queue not quiescent: #{busy.length} queued/running job(s) " \
        "(ids: #{busy.map(&:id).join(', ')}) — resolve them before running the proof"
end
log "jobs queue quiescent, PG OK"

# ---------------------------------------------------------------------------
# Job spec + HTTP enqueue (Bearer ingest token; form-encoded like the actions'
# tests — no JSON body parser is configured).
# ---------------------------------------------------------------------------
def job_params(nonce)
  env = { "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" => "1" }
  env["ANTHROPIC_API_KEY"] = DUMMY_KEY if GATEWAY_MODE
  backend = { base_url: BASE_URL }
  backend[:api_key_ref] = KEY_REF unless GATEWAY_MODE
  {
    harness:     { type: "claude", model: MODEL, backend: backend },
    prompt:      "Reply with exactly this token and nothing else: #{nonce}",
    environment: { env: env, permissions: { network: "true", mounts: [] } }
  }
end

def enqueue_job(port, nonce)
  uri = URI("http://localhost:#{port}/jobs")
  req = Net::HTTP::Post.new(uri)
  req["authorization"] = "Bearer #{INGEST_TOKEN}"
  req.content_type = "application/x-www-form-urlencoded"
  req.body = Rack::Utils.build_nested_query(job_params(nonce))

  resp = nil
  await("POST /jobs on :#{port}", deadline: 10, interval: 0.2) do
    resp = Net::HTTP.start(uri.host, uri.port, read_timeout: 30) { |h| h.request(req) }
  rescue Errno::ECONNREFUSED, Errno::ECONNRESET
    nil
  end
  fail! "POST /jobs :#{port} → #{resp.code} #{resp.body}" unless resp.code == "201"
  id = JSON.parse(resp.body).fetch("id")
  log "job #{id} enqueued over HTTP :#{port} (201, nonce=#{nonce})"
  id
end

def job(id) = JOBS_REPO.by_pk(id)

NONCE_A = "LIVEPROOF-A-#{SecureRandom.hex(6)}"
NONCE_B = "LIVEPROOF-B-#{SecureRandom.hex(6)}"
NONCE_C = "LIVEPROOF-C-#{SecureRandom.hex(6)}"

# ---------------------------------------------------------------------------
# Job A: enqueued over real HTTP BEFORE falcon boots (§8.6 queued-job-survives).
# An ephemeral in-process server exposes the same Rack app (config.ru) on
# :3001 for this one request — no worker exists yet.
# ---------------------------------------------------------------------------
rack_app = Rack::Builder.parse_file(File.join(SERVER_DIR, "config.ru"))
job_a = nil
Sync do |task|
  endpoint = Async::HTTP::Endpoint.parse("http://localhost:#{PREBOOT_PORT}")
  server_task = task.async { Async::HTTP::Server.new(Protocol::Rack::Adapter.new(rack_app), endpoint).run }
  job_a = enqueue_job(PREBOOT_PORT, NONCE_A)
  server_task.stop
end
fail! "job A must be queued pre-boot (got #{job(job_a).status})" unless job(job_a).status == "queued"
log "job A=#{job_a} queued before any worker exists — pre-boot enqueue proven"

# ---------------------------------------------------------------------------
# Boot `falcon host falcon.rb` (web + import + executor + consumer).
# ---------------------------------------------------------------------------
falcon_bin = `which falcon`.strip
fail! "falcon not found on PATH" if falcon_bin.empty?

require "tmpdir"
RUN_TMP    = Dir.mktmpdir("live-proof-")
FALCON_LOG = File.join(RUN_TMP, "falcon.log")
AUX_LOG    = File.join(RUN_TMP, "aux_executor.log")

falcon_pid = Process.spawn(
  { "HANAMI_ENV" => "development" },
  falcon_bin, "host", "falcon.rb",
  chdir: SERVER_DIR, pgroup: true, [:out, :err] => FALCON_LOG
)
log "falcon host PID=#{falcon_pid} (log: #{FALCON_LOG})"

aux_pid = nil
cleanup = proc do
  [falcon_pid, aux_pid].compact.each do |pid|
    Process.kill("-TERM", Process.getpgid(pid))
  rescue Errno::ESRCH, Errno::EPERM
    # already gone
  end
end
at_exit(&cleanup)

await("web /up", deadline: BOOT_WAIT) do
  Net::HTTP.get_response(URI("http://localhost:#{WEB_PORT}/up")).code == "200"
rescue Errno::ECONNREFUSED, Errno::ECONNRESET, EOFError, Net::ReadTimeout
  nil
end
log "web UP — GET /up → 200"

READY_LINES = ["Executor worker starting", "Consumer worker starting"].freeze
await("worker ready lines", deadline: BOOT_WAIT) do
  text = File.read(FALCON_LOG)
  READY_LINES.all? { |l| text.include?(l) } || nil
end
log "executor + consumer workers UP"

# ---------------------------------------------------------------------------
# §8.5 concurrency: a second claimer via the repo's own dev bin (falcon.rb pins
# the executor service to one child, which executes claimed jobs serially), then
# job B enqueued over HTTP against the live web service while A runs.
# ---------------------------------------------------------------------------
aux_pid = Process.spawn(
  { "HANAMI_ENV" => "development" },
  RbConfig.ruby, "bin/executor_worker.rb",
  chdir: SERVER_DIR, pgroup: true, [:out, :err] => AUX_LOG
)
await("aux executor ready", deadline: BOOT_WAIT) do
  File.read(AUX_LOG).include?("Executor worker starting") || nil
end
log "aux executor PID=#{aux_pid} up (second claimer — bin/executor_worker.rb)"

job_b = enqueue_job(WEB_PORT, NONCE_B)

both = await("jobs A+B running simultaneously", deadline: JOB_WAIT, interval: 0.3) do
  a, b = job(job_a), job(job_b)
  fail! "job A terminal (#{a.status}) before simultaneity was observed" if %w[succeeded failed].include?(a.status)
  fail! "job B terminal (#{b.status}) before simultaneity was observed" if %w[succeeded failed].include?(b.status)
  a.status == "running" && b.status == "running" ? [a, b] : nil
end
log "SIMULTANEOUS at #{Time.now.iso8601(3)}: job A=#{both[0].status} (lease #{both[0].leased_until}), " \
    "job B=#{both[1].status} (lease #{both[1].leased_until})"

# ---------------------------------------------------------------------------
# §8.3 (machine-checkable half): ≥1 display event over the live SSE endpoint
# mid-run. The stream action authorizes via session/published only, so the
# driver publishes its own run row first.
# ---------------------------------------------------------------------------
run_a_id = await("job A run link", deadline: 30) { job(job_a).run_id }
RUNS_REPO.update(run_a_id, published: true, updated_at: Time.now)

sse_events = []
sse_status_at_first = nil
begin
  uri = URI("http://localhost:#{WEB_PORT}/runs/#{run_a_id}/stream")
  Net::HTTP.start(uri.host, uri.port, read_timeout: 30) do |http|
    req = Net::HTTP::Get.new(uri, { "accept" => "text/event-stream" })
    deadline = Time.now + SSE_WINDOW
    catch(:sse_done) do
      http.request(req) do |resp|
        fail! "SSE GET /runs/#{run_a_id}/stream → #{resp.code}" unless resp.code == "200"
        resp.read_body do |chunk|
          sse_events.concat(chunk.scan(/^data: .+/))
          sse_status_at_first ||= job(job_a).status if sse_events.any?
          throw :sse_done if sse_events.any? || Time.now > deadline
        end
      end
    end
  end
rescue Net::ReadTimeout, IOError, EOFError => e
  log "SSE read ended early: #{e.class}"
end
fail! "no SSE display event arrived within #{SSE_WINDOW}s" if sse_events.empty?
fail! "SSE event arrived but job A was already #{sse_status_at_first}" unless sse_status_at_first == "running"
log "SSE mid-run: #{sse_events.length} display event(s) captured while job A running; first: #{sse_events.first[0, 120]}"

# ---------------------------------------------------------------------------
# Both jobs to `succeeded`; per-job pipeline assertions (§8.2) + distinctness (§8.5).
# ---------------------------------------------------------------------------
await("jobs A+B succeeded", deadline: JOB_WAIT) do
  statuses = [job(job_a).status, job(job_b).status]
  fail! "a job failed: A=#{statuses[0]} B=#{statuses[1]}" if statuses.include?("failed")
  statuses.all?("succeeded") || nil
end
log "jobs A+B succeeded"

def assert_pipeline!(label, job_id, nonce)
  j = job(job_id)
  fail! "#{label}: attempts=#{j.attempts}, expected 1" unless j.attempts == 1
  fail! "#{label}: no run linked" unless j.run_id
  run = RUNS_REPO.by_pk(j.run_id)
  fail! "#{label}: run status=#{run.status}, expected :complete" unless run.complete?
  fail! "#{label}: run has no conversation_id" unless run.conversation_id
  msgs = MESSAGES_REPO.for_conversation(run.conversation_id).to_a
  texts = msgs.select { |m| m.role == "assistant" }
              .flat_map { |m| Array(m.content) }
              .select { |b| b["type"] == "text" }
              .map { |b| b["text"].to_s }
  fail! "#{label}: no non-empty assistant text persisted" unless texts.any? { |t| !t.strip.empty? }
  fail! "#{label}: own nonce #{nonce} missing from assistant text" unless texts.join.include?(nonce)
  log "#{label}: run #{j.run_id} complete, conversation #{run.conversation_id}, " \
      "#{msgs.length} message(s), attempts=1, nonce present"
  [run, msgs]
end

run_a, msgs_a = assert_pipeline!("job A", job_a, NONCE_A)
run_b, msgs_b = assert_pipeline!("job B", job_b, NONCE_B)

fail! "runs not distinct" if run_a.id == run_b.id
fail! "conversations not distinct" if run_a.conversation_id == run_b.conversation_id
fail! "cross-contamination: B's nonce in A's conversation" if JSON.generate(msgs_a.map(&:content)).include?(NONCE_B)
fail! "cross-contamination: A's nonce in B's conversation" if JSON.generate(msgs_b.map(&:content)).include?(NONCE_A)

Sync do
  client = Async::Redis::Client.new(redis_ep)
  [[job_a, NONCE_B], [job_b, NONCE_A]].each do |id, other_nonce|
    entries = client.xrange(Space::Server::Jobs::StreamKey.for(id), "-", "+") || []
    payload = entries.flat_map { |_, fields| fields.each_slice(2).map(&:last) }.join("\n")
    fail! "raw stream job:#{id}:raw is empty" if entries.empty?
    fail! "cross-contamination: #{other_nonce} on job:#{id}:raw" if payload.include?(other_nonce)
  end
  client.close
end
log "distinct runs/conversations/raw streams — no cross-contamination"

# Aux claimer done — stop it before the kill-executor scenario so falcon's own
# executor child is the only claimer left.
Process.kill("-TERM", Process.getpgid(aux_pid))
begin
  Timeout.timeout(STOP_WAIT) { Process.waitpid2(aux_pid) }
rescue Timeout::Error
  Process.kill("-KILL", Process.getpgid(aux_pid))
  Process.waitpid2(aux_pid)
end
aux_pid = nil
log "aux executor stopped"

# ---------------------------------------------------------------------------
# §8.6 second half: SIGKILL the executor service child mid-job; the lease
# expires, the restarted child sweeps, and the job reaches a terminal state.
# ---------------------------------------------------------------------------
def process_table
  table = Hash.new { |h, k| h[k] = [] }
  `ps -axo pid=,ppid=`.each_line do |line|
    pid, ppid = line.split.map(&:to_i)
    table[ppid] << pid
  end
  table
end

def descendants_of(root, table = process_table)
  found, queue = [], [root]
  while (pid = queue.shift)
    table[pid].each { |c| found << c; queue << c }
  end
  found
end

def command_of(pid) = `ps -o command= -p #{pid}`.strip

def find_executor_child(falcon_pid)
  desc = descendants_of(falcon_pid)
  named = desc.find { |pid| command_of(pid).include?("executor-worker") }
  return named if named

  desc.find { |pid| descendants_of(pid).any? { |c| command_of(c).match?(/container run/) } }
end

job_c = enqueue_job(WEB_PORT, NONCE_C)
await("job C running", deadline: JOB_WAIT) { job(job_c).status == "running" || nil }
sleep 3 # let the sandbox actually spawn under the executor child

exec_child = find_executor_child(falcon_pid)
fail! "could not locate the executor service child under falcon PID #{falcon_pid}" unless exec_child
exec_cmd = command_of(exec_child)
ready_count_before = File.read(FALCON_LOG).scan("Executor worker starting").length
Process.kill("KILL", exec_child)
log "SIGKILLed executor child PID=#{exec_child} (#{exec_cmd[0, 90]}) mid-job; " \
    "job C=#{job(job_c).status}, lease=#{job(job_c).leased_until}"
log "containers right after kill:\n#{`container ls`}"

await("restarted executor ready line", deadline: BOOT_WAIT) do
  File.read(FALCON_LOG).scan("Executor worker starting").length > ready_count_before || nil
end
log "supervisor restarted the executor child (ready line ##{ready_count_before + 1} observed)"

max_expired_age = 0.0
final_c = await("job C terminal after sweep", deadline: SWEEP_WAIT + JOB_WAIT) do
  c = job(job_c)
  if c.status == "running" && c.leased_until && c.leased_until < Time.now
    max_expired_age = [max_expired_age, Time.now - c.leased_until].max
  end
  %w[succeeded failed].include?(c.status) ? c : nil
end
fail! "an expired running lease persisted #{max_expired_age.round(1)}s — the sweep never collected it" if max_expired_age > 15.0
if final_c.status == "failed"
  fail! "job C failed below the attempts cap (attempts=#{final_c.attempts})" unless final_c.attempts >= 3
  log "job C branch: FAILED at attempts cap (attempts=#{final_c.attempts})"
else
  log "job C branch: RE-EXECUTED to succeeded by the restarted child (attempts=#{final_c.attempts})"
end
log "job C: max observed expired-lease age #{max_expired_age.round(1)}s (sweep collected it)"

# ---------------------------------------------------------------------------
# §8.4/§2.4 hygiene (anthropic mode only — architect-run): the resolved secret
# value appears in NO stored artifact. Match-counts only; never the value.
# ---------------------------------------------------------------------------
unless GATEWAY_MODE
  counts = {}
  Sync do
    client = Async::Redis::Client.new(redis_ep)
    { "A" => job_a, "B" => job_b, "C" => job_c }.each do |label, id|
      j = job(id)
      raw = (client.xrange(Space::Server::Jobs::StreamKey.for(id), "-", "+") || [])
            .flat_map { |_, f| f.each_slice(2).map(&:last) }.join("\n")
      display = j.run_id ? (client.xrange(Space::Server::Runs::StreamKey.for(j.run_id), "-", "+") || [])
                           .flat_map { |_, f| f.each_slice(2).map(&:last) }.join("\n") : ""
      run  = j.run_id && RUNS_REPO.by_pk(j.run_id)
      msgs = run&.conversation_id ? MESSAGES_REPO.for_conversation(run.conversation_id).to_a : []
      counts["#{label}.raw_stream"]     = raw.scan(resolved_secret).length
      counts["#{label}.display_stream"] = display.scan(resolved_secret).length
      counts["#{label}.messages_rows"]  = JSON.generate(msgs.map { |m| [m.role, m.model, m.content] }).scan(resolved_secret).length
      counts["#{label}.job_row"]        = JSON.generate(j.spec).scan(resolved_secret).length
      counts["#{label}.run_row"]        = run ? JSON.generate([run.harness, run.model]).scan(resolved_secret).length : 0
    end
    client.close
  end
  counts.each { |k, v| log "hygiene #{k}: #{v} match(es)" }
  fail! "resolved secret leaked into stored artifacts" unless counts.values.all?(&:zero?)
  log "hygiene: zero matches across raw streams, display streams, messages, job rows, run rows"
end

# ---------------------------------------------------------------------------
# Shutdown: SIGTERM the falcon pgroup → clean exit, zero orphans, no sandbox
# containers left (the kill-scenario orphan drains when its harness exits).
# ---------------------------------------------------------------------------
children_before = `pgrep -P #{falcon_pid}`.split.map(&:to_i)
Process.kill("-TERM", Process.getpgid(falcon_pid))
exit_status = nil
begin
  Timeout.timeout(STOP_WAIT) { _, exit_status = Process.waitpid2(falcon_pid) }
rescue Timeout::Error
  fail! "falcon host did not exit within #{STOP_WAIT}s of SIGTERM"
end
falcon_pid = nil
code = exit_status&.exitstatus
fail! "falcon host exited with unexpected code #{code}" unless [0, nil, 130].include?(code)

sleep 1
orphans = children_before.select { |pid| Process.kill(0, pid) rescue false }
fail! "orphaned processes after SIGTERM: #{orphans.inspect}" if orphans.any?
log "falcon exited cleanly (code=#{code.inspect}), 0 orphans"

await("sandbox containers drained", deadline: SWEEP_WAIT) { sandbox_rows.empty? || nil }
log "container ls clean — no space-job-env containers remain"

# ---------------------------------------------------------------------------
puts ""
puts "LIVE PROOF OK"
puts "  mode: #{GATEWAY_MODE ? 'gateway (dummy key)' : 'anthropic (op-resolved key, hygiene-swept)'}"
puts "  backend: #{BASE_URL} model=#{MODEL} base_image=#{BASE_IMAGE}"
puts "  §8.6 pre-boot enqueue: job #{job_a} queued before boot, executed after"
puts "  §8.5 concurrency: jobs #{job_a}+#{job_b} running simultaneously → both succeeded, attempts=1"
puts "       distinct runs #{run_a.id}/#{run_b.id}, conversations #{run_a.conversation_id}/#{run_b.conversation_id}"
puts "  §8.3 SSE: #{sse_events.length} display event(s) mid-run on run #{run_a_id}"
puts "  §8.6 killed executor: job #{job_c} → #{final_c.status} (attempts=#{final_c.attempts})"
puts "  shutdown: clean exit, 0 orphans, 0 leftover containers"
exit 0
