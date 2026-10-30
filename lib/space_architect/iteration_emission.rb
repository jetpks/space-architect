# frozen_string_literal: true

require "net/http"
require "openssl"
require "json"
require "yaml"
require "pathname"

module Space::Architect
  # I16 — the structured-record emission layer: config resolution (session-sink
  # mirror: unconfigured = fully inert, configured = capture on, mute knob
  # available), the best-effort Net::HTTP client, the payload builders that
  # derive from the canonical sources the loop commands already hold, and the
  # ```rulings block parser. ArchitectProject's five hook call sites guard
  # through `emitter&.post` inside a rescue-all belt; nothing here may ever
  # raise into a loop command or change its exit code, stdout, or commits.
  module IterationEmission
    # Frozen tuning (mirrors the spec; session-sink pins its own constants the
    # same way): per attempt 2s open / 5s read, at most 2 attempts, retry on
    # network errors or 5xx ONLY — 4xx is never retried.
    OPEN_TIMEOUT = 2
    READ_TIMEOUT = 5
    MAX_ATTEMPTS = 2

    # The four server mouths (I15, frozen): POST <host>/iterations/ingest/<mouth>.
    MOUTHS = %w[freeze lane verdict integration].freeze

    # Iteration/lane status vocabularies (frozen): nothing else is emitted.
    ITERATION_STATUSES = %w[frozen integrated].freeze
    LANE_STATUSES      = %w[complete integrated].freeze

    # The space-slug rule (architect_project.rb :1642), with the emission-layer
    # fallback: space.data["id"] when the title is absent or slugifies empty.
    def self.slug_for(space)
      slug = space.title.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
      slug.empty? ? space.data["id"].to_s : slug
    rescue StandardError
      space.data["id"].to_s
    end

    # ---- config resolution (the Routing.global_path pattern) ---------------

    # Global file ~/.config/space-architect/emission.yaml, path overridable via
    # SPACE_ARCHITECT_EMISSION_GLOBAL_CONFIG — exactly Routing.global_path's
    # shape (env pin first, else the ~/.config path; parity outranks XDG).
    def self.global_path(env: ENV)
      override = env["SPACE_ARCHITECT_EMISSION_GLOBAL_CONFIG"]
      return Pathname.new(override) unless override.nil?

      Pathname.new("~/.config/space-architect/emission.yaml").expand_path
    end

    # Resolve the configured Emitter for a space, or nil when unconfigured:
    # no file, missing host/token, or disabled. ENV beats the file per field,
    # both ways: SPACE_ARCHITECT_EMISSION_HOST / _TOKEN override their file
    # values; _DISABLED ("1"/"true" mutes; any other present value unmutes)
    # overrides the file's disabled knob in both directions. A malformed or
    # unreadable file is INERT PLUS one stderr line naming the path and the
    # problem; an absent file is inert and silent (a no-config machine is a
    # normal state — zero output, zero network).
    def self.emitter_for(space, env: ENV, err: $stderr)
      config = read_config(global_path(env: env), err: err)
      disabled_env = env["SPACE_ARCHITECT_EMISSION_DISABLED"]
      host   = env["SPACE_ARCHITECT_EMISSION_HOST"]   || config&.[](:host)
      token  = env["SPACE_ARCHITECT_EMISSION_TOKEN"]  || config&.[](:token)
      disabled =
        if disabled_env.nil?
          config&.[](:disabled) == true
        else
          %w[1 true].include?(disabled_env.strip.downcase)
        end

      return nil if disabled || host.to_s.strip.empty? || token.to_s.strip.empty?

      Emitter.new(host: host.to_s.strip, token: token.to_s, slug: slug_for(space))
    end

    def self.read_config(path, err:)
      return nil unless File.file?(path.to_s)

      doc = YAML.safe_load(File.read(path.to_s), aliases: true)
      unless doc.is_a?(Hash)
        err.puts "emission config (#{path}): expected a YAML mapping, got #{doc.inspect} — file config ignored"
        return nil
      end
      {
        host: doc["host"], token: doc["token"], disabled: doc["disabled"] == true
      }
    rescue Psych::Exception => e
      err.puts "emission config (#{path}): malformed YAML — #{e.message} — file config ignored"
      nil
    rescue StandardError => e
      err.puts "emission config (#{path}): unreadable — #{e.class}: #{e.message} — file config ignored"
      nil
    end

    # ---- the client ---------------------------------------------------------

    # One best-effort POST per call to <host>/iterations/ingest/<mouth>.
    # NEVER raises into the caller: at most MAX_ATTEMPTS attempts (retry on
    # network errors or 5xx only), then exactly one stderr line — the mouth
    # path plus the failure class/status with a bounded response excerpt.
    # Never the token, never the payload. On 2xx returns
    # {status:, body:} (body JSON-parsed when possible).
    class Emitter
      attr_reader :host, :token, :slug

      def initialize(host:, token:, slug:)
        @host   = host.sub(%r{/+\z}, "") # trailing slashes stripped once
        @token  = token
        @slug   = slug
      end

      def post(mouth, payload)
        path = "/iterations/ingest/#{mouth}"
        body = JSON.generate(payload)
        response = nil
        last_error = nil
        MAX_ATTEMPTS.times do
          begin
            response, last_error = post_once(path, body)
          rescue *NETWORK_ERRORS => e
            last_error = e # network failure: fall through to the retry
          end
          break if response && response.code.to_i.between?(200, 499)
          # 5xx and network failures fall through to the retry; 4xx breaks —
          # never retried.
        end

        return result_for(response) if response&.code.to_i.between?(200, 299)

        report_failure(path, response, last_error)
        nil
      end

      private

      def post_once(path, body)
        uri = URI.parse("#{@host}#{path}")
        uri.scheme ||= "http"
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = OPEN_TIMEOUT
        http.read_timeout = READ_TIMEOUT
        request = Net::HTTP::Post.new(uri.request_uri)
        request["Content-Type"] = "application/json"
        request["Authorization"] = "Bearer #{@token}"
        request["X-Space-Slug"] = @slug
        request.body = body
        response = http.request(request)
        [response, nil]
      end

      NETWORK_ERRORS = [
        Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, Errno::ENETUNREACH,
        Errno::EPIPE, Errno::EACCES, Errno::EADDRNOTAVAIL, Errno::ETIMEDOUT,
        SocketError, IOError, EOFError, SystemCallError,
        Net::OpenTimeout, Net::ReadTimeout, Net::HTTPBadResponse,
        OpenSSL::SSL::SSLError, Timeout::Error
      ].freeze

      def result_for(response)
        { status: response.code.to_i, body: safe_parse(response.body) }
      end

      def safe_parse(raw)
        JSON.parse(raw.to_s)
      rescue JSON::ParserError, ArgumentError
        raw.to_s
      end

      # One stderr line: mouth path + failure class/status + bounded response
      # excerpt when one arrived. The token lives only in the Authorization
      # header; the payload is never echoed; a response body is server-written
      # text and never echoes either.
      def report_failure(path, response, last_error)
        detail =
          if response
            "status #{response.code} — #{response.body.to_s[0, 200]}"
          else
            "#{last_error&.class || 'network failure'}"
          end
        $stderr.puts "#{path}: emission failed after #{MAX_ATTEMPTS} attempt(s): #{detail}"
      end
    end

    # ---- payload builders (contract keys only; nil/empty scalars omitted) --
    #
    # The server's frozen contracts (repos/all-fax-no-printer
    # app/contracts/ingest_iteration_*.rb) 422 unknown keys and empty `expect`
    # maps — builders emit ONLY contract keys and omit `expect` ENTIRELY when
    # the gate declares none (never {}).

    def self.compact_scalars(hash)
      hash.reject { |_k, v| v.nil? || (v.respond_to?(:empty?) && v.empty?) }
    end

    # One gate as the freeze mouth stores it: id/ac/cmd/cwd/timeout/expect,
    # nil fields omitted, expect dropped entirely when absent or empty.
    def self.map_gate(g)
      g = g.transform_keys(&:to_s)
      compact_scalars(
        "id" => g["id"], "ac" => g["ac"], "cmd" => g["cmd"], "cwd" => g["cwd"],
        "timeout" => g["timeout"], "expect" => (g["expect"].is_a?(Hash) && !g["expect"].empty? ? g["expect"] : nil)
      )
    end

    def self.build_freeze(ordinal:, name:, freeze_sha:, branch:, gates:)
      compact_scalars(
        "iteration" => compact_scalars(
          "ordinal" => ordinal, "name" => name, "freeze_sha" => freeze_sha,
          "branch" => branch, "status" => "frozen"
        ),
        "gates" => Array(gates).map { |g| map_gate(g) }
      )
    end

    # Lane-mouth scalars as stored in the space.yaml lane record, re-sliced
    # from it — never a hand-maintained copy. status/gate_results ride when
    # given (nil/empty omitted; an absent key leaves stored rows untouched).
    def self.build_lane(ordinal:, name:, lane_record:, status: nil, gate_results: nil)
      r = lane_record.transform_keys(&:to_s)
      lane = compact_scalars(
        "name" => r["name"], "repo" => r["repo"], "base_sha" => r["base_sha"],
        "model" => r["model"], "harness" => r["harness"], "effort" => r["effort"],
        "touch_set" => (Array(r["touch_set"]) unless Array(r["touch_set"]).empty?),
        "bounds_override_reason" => r["bounds_override_reason"],
        "status" => status,
        "gate_results" => gate_results
      )
      { "iteration" => compact_scalars("ordinal" => ordinal, "name" => name), "lane" => lane }
    end

    def self.map_gate_result(g, transcript)
      result = compact_scalars(
        "gate_id" => g[:gate_id], "status" => g[:status].to_s,
        "reason" => g[:reason].to_s, "transcript" => transcript
      )
      result.delete("reason") if g[:reason].to_s.empty?
      result
    end

    # A gate transcript sidecar entry: the structured mirror of one executed
    # gate (all keys always present — it is the faithful machine mirror).
    def self.map_sidecar_gate(g)
      {
        "gate_id" => g[:id].to_s, "status" => g[:status].to_s, "reason" => g[:reason].to_s,
        "stdout" => g[:stdout].to_s, "stderr" => g[:stderr].to_s,
        "exit_code" => g[:exit_code], "cmd" => g[:cmd].to_s, "dir" => g[:dir].to_s
      }
    end

    def self.build_verdict(ordinal:, name:, decision:, rulings:)
      verdict = compact_scalars(
        "decision" => decision,
        "ac_rulings" => (rulings[:ac_rulings] if rulings[:ac_rulings]&.any?),
        "phase0_resolutions" => (rulings[:phase0_resolutions] if rulings[:phase0_resolutions]&.any?)
      )
      { "iteration" => compact_scalars("ordinal" => ordinal, "name" => name), "verdict" => verdict }
    end

    def self.build_integration(ordinal:, name:, branch:, lanes:)
      {
        "iteration" => compact_scalars("ordinal" => ordinal, "name" => name, "status" => "integrated"),
        "integration" => {
          "branch" => branch,
          "lanes" => lanes.map { |l| compact_scalars("name" => l[:name], "merge_sha" => l[:merge_sha], "integration_branch" => l[:integration_branch]) }
        }
      }
    end

    # ---- the ```rulings block (S3) ------------------------------------------
    #
    # A fenced YAML block inside the ## Verdict body — the ```gates/```lanes
    # discipline applied to verdict detail. Valid entries ride the emission
    # verbatim; ANY invalid entry is dropped with one loud stderr line naming
    # it; a malformed block (bad YAML, wrong shape) is dropped with one line;
    # no block at all is silent decision-only. Extraction never raises.

    def self.parse_rulings(body, err: $stderr)
      match = body.to_s.match(/^```rulings\n(.*?)^```/m)
      return {} unless match

      doc = YAML.safe_load(match[1], aliases: true)
      unless doc.is_a?(Hash)
        err.puts "rulings block: expected a YAML mapping, got #{doc.inspect} — dropped (decision-only emission)"
        return {}
      end

      {
        ac_rulings: valid_rulings(Array(doc["ac_rulings"]), err: err),
        phase0_resolutions: valid_resolutions(Array(doc["phase0_resolutions"]), err: err)
      }
    rescue Psych::Exception, StandardError => e
      err.puts "rulings block: malformed YAML — #{e.message} — dropped (decision-only emission)"
      {}
    end

    # ruling is FREE text (the PASS/FAIL/MODIFY/NOT-APPLICABLE convention is
    # documented, not enforced); only shape is validated here.
    def self.valid_rulings(entries, err:)
      entries.filter_map do |entry|
        unless entry.is_a?(Hash) && entry["ac"].is_a?(String) && !entry["ac"].strip.empty? &&
               entry["ruling"].is_a?(String) && !entry["ruling"].strip.empty? &&
               (entry.key?("note") ? entry["note"].is_a?(String) || entry["note"].nil? : true)
          err.puts "rulings block: dropped invalid ac_rulings entry #{entry.inspect[0, 120]}"
          next
        end
        compact_scalars("ac" => entry["ac"], "ruling" => entry["ruling"], "note" => entry["note"])
      end
    end

    def self.valid_resolutions(entries, err:)
      entries.filter_map do |entry|
        unless entry.is_a?(Hash) && entry["topic"].is_a?(String) && !entry["topic"].strip.empty? &&
               (entry.key?("lane") ? entry["lane"].is_a?(String) || entry["lane"].nil? : true) &&
               (entry.key?("resolution") ? entry["resolution"].is_a?(String) || entry["resolution"].nil? : true)
          err.puts "rulings block: dropped invalid phase0_resolutions entry #{entry.inspect[0, 120]}"
          next
        end
        compact_scalars("topic" => entry["topic"], "lane" => entry["lane"], "resolution" => entry["resolution"])
      end
    end
  end
end
