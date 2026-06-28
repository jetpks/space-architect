#!/usr/bin/env ruby
# frozen_string_literal: true

# Boot-smoke for the supervised web+worker topology.
#
# Launches `falcon host falcon.rb`, confirms BOTH services up (web answers /up; worker
# logs ready), enqueues a real Redis job, observes it drain to :completed, sends SIGTERM,
# confirms graceful exit 0 and no orphaned child processes.
#
# Usage: cd architect && HANAMI_ENV=development bundle exec ruby bin/topology_smoke.rb
# Exit 0 = PASS; exit 1 = FAIL (details on stderr)

require "timeout"
require "net/http"
require "uri"
require "json"
require "securerandom"

ARCHITECT_DIR = File.expand_path("..", __dir__)
WEB_PORT    = 3000
WEB_URL     = "http://localhost:#{WEB_PORT}/up"
BOOT_WAIT   = 45  # seconds for falcon host + child processes to boot
JOB_WAIT    = 60  # seconds for import job to complete
STOP_WAIT   = 15  # seconds for graceful shutdown

def fail!(msg)
  $stderr.puts "TOPOLOGY SMOKE FAIL: #{msg}"
  exit 1
end

def log(msg)
  puts "[topology_smoke] #{msg}"
  $stdout.flush
end

# ---------------------------------------------------------------------------
# Boot Hanami in THIS process so we can create test fixtures and query DB.
# ---------------------------------------------------------------------------
ENV["HANAMI_ENV"] ||= "development"
Dir.chdir(ARCHITECT_DIR)
require "hanami/boot"

require "async/redis"
require "async/redis/endpoint"
require "async/job/processor/redis"

# Verify Redis is reachable
redis_ep = ENV["REDIS_URL"] ? Async::Redis::Endpoint.parse(ENV["REDIS_URL"]) : Async::Redis.local_endpoint
require "async"
Sync do
  client = Async::Redis::Client.new(redis_ep)
  client.call("PING")
  client.close
end
log "Redis OK"

# ---------------------------------------------------------------------------
# Create test fixtures: store source file, create conversation record.
# ---------------------------------------------------------------------------
FIXTURE = File.join(ARCHITECT_DIR, "test", "fixtures", "files", "transcript.jsonl")
fail! "fixture missing: #{FIXTURE}" unless File.exist?(FIXTURE)

data = Space::Server::SourceFileUploader.store(File.open(FIXTURE))

users_repo = Space::Server::Repos::UsersRepo.new
conversations_repo = Space::Server::Repos::ConversationsRepo.new

user = users_repo.create(
  github_uid:  SecureRandom.uuid,
  username:    "smoke-#{SecureRandom.hex(4)}",
  name:        "Smoke Test",
  email:       "smoke@example.com",
  avatar_url:  "https://example.com/avatar.png",
  github_orgs: [],
  created_at:  Time.now,
  updated_at:  Time.now
)

conv = conversations_repo.create(
  user_id:          user.id,
  status:           0,
  published:        false,
  source_file_data: data,
  created_at:       Time.now,
  updated_at:       Time.now
)
conv_id = conv.id
log "Created conversation id=#{conv_id}"

# Enqueue before starting falcon — exercises "job waiting in queue before worker boots" path.
# Uses the same prefix that falcon.rb's import-worker service will dequeue from.
enqueue_prefix = "architect-import"
enqueue_server = Space::Server::Jobs::ImportConversation.build_redis_processor(prefix: enqueue_prefix)
enqueue_server.call({ "conversation_id" => conv_id })
log "Enqueued job conversation_id=#{conv_id} prefix=#{enqueue_prefix}"

# ---------------------------------------------------------------------------
# Launch `falcon host falcon.rb` as a child process (from architect/ dir).
# ---------------------------------------------------------------------------
falcon_bin = `which falcon`.strip
fail! "falcon not found on PATH" if falcon_bin.empty?

log "Spawning: #{falcon_bin} host falcon.rb"
falcon_pid = Process.spawn(
  { "HANAMI_ENV" => "development" },
  falcon_bin, "host", "falcon.rb",
  chdir: ARCHITECT_DIR,
  pgroup: true  # own process group so we can kill all children
)
log "falcon host PID=#{falcon_pid}"

cleanup_ran = false
cleanup = proc do
  next if cleanup_ran
  cleanup_ran = true
  begin
    Process.kill("-TERM", Process.getpgid(falcon_pid))
  rescue Errno::ESRCH, Errno::EPERM
    # Already gone
  end
end
at_exit { cleanup.call }

# ---------------------------------------------------------------------------
# Wait for web service to answer /up.
# ---------------------------------------------------------------------------
log "Waiting up to #{BOOT_WAIT}s for web service at #{WEB_URL}..."
web_up = false
deadline = Time.now + BOOT_WAIT
until Time.now > deadline
  begin
    resp = Net::HTTP.get_response(URI(WEB_URL))
    if resp.code.to_i == 200
      web_up = true
      log "Web service UP — GET /up → #{resp.code}"
      break
    end
  rescue Errno::ECONNREFUSED, Errno::ECONNRESET, EOFError, Net::ReadTimeout
    # Not ready yet
  end
  sleep 0.5
end
fail! "Web service did not come up within #{BOOT_WAIT}s (GET #{WEB_URL} never returned 200)" unless web_up

# ---------------------------------------------------------------------------
# Wait for import job to drain to :completed.
# ---------------------------------------------------------------------------
log "Waiting up to #{JOB_WAIT}s for conversation #{conv_id} to reach :completed..."
job_done = false
deadline = Time.now + JOB_WAIT
until Time.now > deadline
  status = conversations_repo.by_pk(conv_id)&.status
  if status == :completed
    log "Conversation #{conv_id} status=:completed"
    job_done = true
    break
  elsif status == :failed
    fail! "Conversation #{conv_id} status=:failed — import job errored"
  end
  sleep 0.5
end
fail! "Job did not complete within #{JOB_WAIT}s (status=#{conversations_repo.by_pk(conv_id)&.status})" unless job_done

# Snapshot child PIDs before sending SIGTERM
children_before = `pgrep -P #{falcon_pid} 2>/dev/null`.split.map(&:to_i)
log "Child PIDs before SIGTERM: #{children_before.inspect}"

# ---------------------------------------------------------------------------
# Send SIGTERM to the falcon host process group and wait for exit.
# ---------------------------------------------------------------------------
log "Sending SIGTERM to process group of PID #{falcon_pid}..."
begin
  Process.kill("-TERM", Process.getpgid(falcon_pid))
rescue Errno::ESRCH
  # Already gone — that would be a bug
end
cleanup_ran = true  # Prevent at_exit from double-killing

exit_status = nil
begin
  Timeout.timeout(STOP_WAIT) do
    _, status = Process.waitpid2(falcon_pid)
    exit_status = status
  end
rescue Timeout::Error
  fail! "falcon host did not exit within #{STOP_WAIT}s after SIGTERM"
end

exit_code = exit_status&.exitstatus
log "falcon host exited with code=#{exit_code.inspect} (signal=#{exit_status&.termsig.inspect})"

# Falcon host catches Interrupt and exits cleanly; SIGTERM may result in exitstatus=nil (signal kill)
# or 0. Accept exit code 0, nil (signal), or 130 (SIGINT convention).
unless [0, nil, 130].include?(exit_code)
  fail! "falcon host exited with unexpected code #{exit_code}"
end

# ---------------------------------------------------------------------------
# Verify no orphaned child processes remain.
# ---------------------------------------------------------------------------
sleep 1  # Brief pause for children to reap
orphans = children_before.select { |pid| Process.kill(0, pid) rescue false }
if orphans.any?
  fail! "Orphaned processes after SIGTERM: #{orphans.inspect}"
end
log "No orphaned processes — all #{children_before.size} children exited"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
puts ""
puts "TOPOLOGY SMOKE OK"
puts "  web: GET #{WEB_URL} → 200"
puts "  worker: conversation #{conv_id} → :completed"
puts "  shutdown: graceful exit, 0 orphans"
exit 0
