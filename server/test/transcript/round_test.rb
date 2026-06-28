# frozen_string_literal: true

require_relative "support"

class RoundTest < Minitest::Test
  include Space::Server::Transcript

  def setup
    @id = 0
  end

  def msg(role, blocks)
    Msg.new(@id += 1, role, blocks)
  end

  def text(role, body)
    msg(role, [{ "type" => "text", "text" => body }])
  end

  def tool_use
    msg("assistant", [{ "type" => "tool_use", "id" => "t#{@id}", "name" => "Bash", "input" => {} }])
  end

  def tool_result
    msg("user", [{ "type" => "tool_result", "tool_use_id" => "x", "content" => "ok" }])
  end

  # Interleaved-thinking noise: a signature over an empty string, no thought.
  def empty_thinking
    msg("assistant", [{ "type" => "thinking", "thinking" => "", "signature" => "over-nothing" }])
  end

  # A real thought we can't read (Codex encrypted chain-of-thought).
  def redacted_thinking
    msg("assistant", [{ "type" => "redacted_thinking", "data" => "ciphertext" }])
  end

  def rounds_for(messages)
    Turn.group(messages).first.rounds
  end

  test "a narrative after actions opens the next round" do
    prompt = text("user", "go")
    lead1 = text("assistant", "first, I'll look around")
    call1 = tool_use
    lead2 = text("assistant", "now I'll fix it")
    call2 = tool_use

    rounds = rounds_for([prompt, lead1, call1, lead2, call2])

    assert_equal 2, rounds.size
    assert_equal [lead1, call1], rounds.first.messages
    assert_equal [lead2, call2], rounds.last.messages
    assert_equal lead1.id, rounds.first.anchor_id
    assert_equal lead2.id, rounds.last.anchor_id
  end

  test "tool results ride along without splitting" do
    prompt = text("user", "go")
    call1 = tool_use
    result = tool_result
    call2 = tool_use

    rounds = rounds_for([prompt, call1, result, call2])

    assert_equal 1, rounds.size
    assert_equal [call1, result, call2], rounds.first.messages
  end

  test "a tool result before the next narrative stays in the round that called it" do
    prompt = text("user", "go")
    lead1 = text("assistant", "looking")
    call1 = tool_use
    result = tool_result
    lead2 = text("assistant", "fixing")
    call2 = tool_use

    rounds = rounds_for([prompt, lead1, call1, result, lead2, call2])

    assert_equal 2, rounds.size
    assert_equal [lead1, call1, result], rounds.first.messages
    assert_equal [lead2, call2], rounds.last.messages
  end

  test "stdout halves and empty thinking never split" do
    prompt = text("user", "go")
    call1 = tool_use
    stdout = text("user", "<local-command-stdout>ran</local-command-stdout>")
    empty = empty_thinking
    call2 = tool_use

    rounds = rounds_for([prompt, call1, stdout, empty, call2])

    assert_equal 1, rounds.size
    assert_equal [call1, stdout, empty, call2], rounds.first.messages
  end

  test "a redacted thought after actions opens and anchors the next round" do
    prompt = text("user", "go")
    think1 = redacted_thinking
    call1 = tool_use
    think2 = redacted_thinking
    call2 = tool_use

    rounds = rounds_for([prompt, think1, call1, think2, call2])

    assert_equal 2, rounds.size
    assert_equal [think1, call1], rounds.first.messages
    assert_equal [think2, call2], rounds.last.messages
    assert_equal think1.id, rounds.first.anchor_id
    assert_equal think2.id, rounds.last.anchor_id
  end

  test "redacted thoughts before the first action share a round" do
    prompt = text("user", "go")
    think1 = redacted_thinking
    think2 = redacted_thinking
    call = tool_use

    rounds = rounds_for([prompt, think1, think2, call])

    assert_equal 1, rounds.size
    assert_equal [think1, think2, call], rounds.first.messages
  end

  test "the codex cadence yields one round per redacted thought" do
    prompt = text("user", "go")
    think1 = redacted_thinking
    call1 = tool_use
    result1 = tool_result
    think2 = redacted_thinking
    call2 = tool_use
    result2 = tool_result
    think3 = redacted_thinking
    answer = text("assistant", "done")

    rounds = rounds_for([prompt, think1, call1, result1, think2, call2, result2, think3, answer])

    assert_equal 3, rounds.size
    assert_equal [think1, call1, result1], rounds[0].messages
    assert_equal [think2, call2, result2], rounds[1].messages
    assert_equal [think3, answer], rounds[2].messages
    assert_equal think3.id, rounds[2].anchor_id
  end

  test "the compaction summary is machinery and never anchors a round" do
    summary = text("user", "#{Turn::SUMMARY_PREAMBLE}. Earlier we did things.")
    command = text("user", "<command-name>/compact</command-name>")
    stdout = text("user", "<local-command-stdout>compacted</local-command-stdout>")

    turn = Turn.group([summary, command, stdout]).first
    rounds = turn.rounds

    # The command is the prompt; the summary and stdout are machinery riding in
    # one round, anchored by fallback on the first member.
    assert_equal 1, rounds.size
    assert_equal [summary, stdout], rounds.first.messages
    assert_equal summary.id, rounds.first.anchor_id
  end

  test "anchor is the first structural member, not leading machinery" do
    prompt = text("user", "go")
    result = tool_result
    lead = text("assistant", "ok")
    call = tool_use

    rounds = rounds_for([prompt, result, lead, call])

    assert_equal 1, rounds.size
    assert_equal lead.id, rounds.first.anchor_id
  end

  test "a thinking preamble splits at the next round's thinking, not its narrative" do
    prompt = text("user", "go")
    think1 = msg("assistant", [{ "type" => "thinking", "thinking" => "hmm" }])
    lead1 = text("assistant", "plan A")
    call1 = tool_use
    think2 = msg("assistant", [{ "type" => "thinking", "thinking" => "hmm more" }])
    lead2 = text("assistant", "plan B")
    call2 = tool_use

    rounds = rounds_for([prompt, think1, lead1, call1, think2, lead2, call2])

    assert_equal 2, rounds.size
    assert_equal [think1, lead1, call1], rounds.first.messages
    assert_equal think2.id, rounds.last.anchor_id
  end

  test "a prompt-only turn has no rounds" do
    prompt = text("user", "just asking")

    assert_empty rounds_for([prompt])
  end

  test "a preamble turn partitions all its members" do
    result = tool_result
    prompt = text("user", "hello")

    turns = Turn.group([result, prompt])
    rounds = turns.first.rounds

    assert_equal 1, rounds.size
    assert_equal [result], rounds.first.messages
    assert_equal result.id, rounds.first.anchor_id
  end
end
