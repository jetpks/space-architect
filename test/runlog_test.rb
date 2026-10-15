# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/space_architect/runlog"
require "stringio"

# Fixture goldens are generated from the byte-compat oracle (~/bin/runlog):
#   NO_COLOR=1 ruby /Users/eric/bin/runlog test/fixtures/runlog/basic.jsonl > test/fixtures/runlog/basic.expected
#   NO_COLOR=1 ruby /Users/eric/bin/runlog test/fixtures/runlog/noise-and-redacted.jsonl > test/fixtures/runlog/noise-and-redacted.expected
class RunlogTest < Space::ArchitectTest
  # thinking+text streaming, a tool call + multi-line result, a toolUse stop
  # with NO done line mid-exchange, and the final done line with usage/cost/
  # elapsed summed across the whole exchange.
  def test_runlog_renders_streaming_tool_and_done_lines_from_the_oracle_golden
    assert_stream_matches_fixture("basic")
  end

  # A redacted-thinking block ((N tokens, not streamed)), a non-JSON noise
  # line, and the plain done line without a cost term.
  def test_runlog_renders_redacted_thinking_and_drops_noise_from_the_oracle_golden
    assert_stream_matches_fixture("noise-and-redacted")
  end

  # Interrupt mid-stream → quiet return with the output already written.
  def test_runlog_stream_returns_quietly_on_interrupt
    input = Object.new
    input.define_singleton_method(:each_line) do |&block|
      [
        "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"text_start\"}}\n",
        "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"text_delta\",\"delta\":\"partial\"}}\n"
      ].each(&block)
      raise Interrupt
    end

    out = StringIO.new
    Space::Architect::Runlog.stream(input: input, io: out, env: { "NO_COLOR" => "1" })

    assert_equal "● assistant\npartial", out.string
  end

  private

  def assert_stream_matches_fixture(name)
    out = StringIO.new
    File.open(File.join(__dir__, "fixtures", "runlog", "#{name}.jsonl")) do |input|
      Space::Architect::Runlog.stream(input: input, io: out, env: { "NO_COLOR" => "1" })
    end

    assert_equal File.read(File.join(__dir__, "fixtures", "runlog", "#{name}.expected")), out.string
  end
end
