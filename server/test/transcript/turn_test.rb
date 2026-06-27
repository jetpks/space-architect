# frozen_string_literal: true

require_relative "support"

class TurnTest < Minitest::Test
  include Architect::Transcript

  def setup
    @id = 0
  end

  def msg(role, blocks)
    Msg.new(@id += 1, role, blocks)
  end

  def text(role, body)
    msg(role, [{ "type" => "text", "text" => body }])
  end

  def tool_result
    msg("user", [{ "type" => "tool_result", "tool_use_id" => "x", "content" => "ok" }])
  end

  test "each prompt opens a new turn; the agent's replies accrete onto it" do
    prompt = text("user", "do the thing")
    reply = text("assistant", "done")
    next_prompt = text("user", "now this")

    turns = Turn.group([prompt, reply, next_prompt])

    assert_equal 2, turns.size
    assert_equal [prompt, reply], turns.first.messages
    assert_equal [next_prompt], turns.last.messages
    assert_equal prompt.id, turns.first.anchor_id
    assert_equal prompt.id, turns.first.prompt.id
  end

  test "tool_result-only user messages are machinery, not prompts" do
    prompt = text("user", "run it")
    call = text("assistant", "running")
    result = tool_result

    turns = Turn.group([prompt, call, result])

    assert_equal 1, turns.size
    assert_equal [prompt, call, result], turns.first.messages
  end

  test "slash command opens a turn; its stdout half rides along" do
    command = text("user", "<command-name>/compact</command-name>")
    stdout = text("user", "<local-command-stdout>compacted</local-command-stdout>")

    turns = Turn.group([command, stdout])

    assert_equal 1, turns.size
    assert_equal command.id, turns.first.prompt.id
    assert_equal [command, stdout], turns.first.messages
  end

  test "the summary injected before /compact rides in the command's turn" do
    prompt = text("user", "earlier work")
    reply = text("assistant", "done")
    summary = text("user", "This session is being continued from a previous conversation that ran out of context. ...")
    command = text("user", "<command-name>/compact</command-name>")
    stdout = text("user", "<local-command-stdout>compacted</local-command-stdout>")

    turns = Turn.group([prompt, reply, summary, command, stdout])

    # The summary does NOT open its own turn; it opens the /compact turn, which the
    # command and its stdout join.
    assert_equal 2, turns.size
    assert_equal [prompt, reply], turns.first.messages
    assert_equal [summary, command, stdout], turns.last.messages
    # The /compact command is the prompt and the turn's identity — not the summary.
    assert_equal command.id, turns.last.prompt.id
    assert_equal command.id, turns.last.anchor_id
  end

  test "a real human message before /compact is not mistaken for a summary" do
    human = text("user", "actually, wrap it up")
    command = text("user", "<command-name>/compact</command-name>")

    turns = Turn.group([human, command])

    # No summary preamble => the human message is its own prompt turn.
    assert_equal 2, turns.size
    assert_equal human.id, turns.first.prompt.id
    assert_equal command.id, turns.last.prompt.id
  end

  test "an interrupt marker closes the turn it interrupted, not a new one" do
    prompt = text("user", "do the thing")
    reply = text("assistant", "working")
    interrupt = text("user", "[Request interrupted by user]")
    next_prompt = text("user", "ok, try this instead")

    turns = Turn.group([prompt, reply, interrupt, next_prompt])

    # The interrupt is machinery: it rides on the turn it stopped (as its terminal),
    # and the next real message opens the next turn.
    assert_equal 2, turns.size
    assert_equal [prompt, reply, interrupt], turns.first.messages
    assert_equal prompt.id, turns.first.prompt.id
    assert_equal [next_prompt], turns.last.messages
    assert_equal next_prompt.id, turns.last.prompt.id
  end

  test "the for-tool-use interrupt variant is also machinery" do
    prompt = text("user", "go")
    interrupt = text("user", "[Request interrupted by user for tool use]")

    turns = Turn.group([prompt, interrupt])

    assert_equal 1, turns.size
    assert_equal [prompt, interrupt], turns.first.messages
  end

  test "codex's turn_aborted envelope is the same interrupt machinery" do
    prompt = text("user", "go")
    reply = text("assistant", "working")
    interrupt = text("user", "<turn_aborted>\nThe user interrupted the previous turn on purpose.\n</turn_aborted>")
    next_prompt = text("user", "try again")

    turns = Turn.group([prompt, reply, interrupt, next_prompt])

    assert_equal 2, turns.size
    assert_equal [prompt, reply, interrupt], turns.first.messages
    assert_equal [next_prompt], turns.last.messages
  end

  test "messages before the first prompt form a prompt-less preamble turn" do
    preamble = tool_result
    prompt = text("user", "hello")

    turns = Turn.group([preamble, prompt])

    assert_equal 2, turns.size
    assert_nil turns.first.prompt
    assert_equal preamble.id, turns.first.anchor_id
    assert_equal prompt.id, turns.last.prompt.id
  end

  test "empty input groups to no turns" do
    assert_empty Turn.group([])
  end
end
