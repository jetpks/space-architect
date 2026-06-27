# frozen_string_literal: true

require_relative "support"

class EntityTest < Minitest::Test
  include Architect::Transcript

  def setup
    @id = 0
    @messages = []
  end

  def msg(role, blocks)
    m = Msg.new(@id += 1, role, blocks)
    @messages << m
    m
  end

  def text(role, body)
    msg(role, [{ "type" => "text", "text" => body }])
  end

  def tool_use(id)
    msg("assistant", [{ "type" => "tool_use", "id" => id, "name" => "Bash", "input" => {} }])
  end

  def turns
    Turn.group(@messages)
  end

  def locate(kind, anchor, tool_use_id: nil)
    Entity.locate(turns: turns, kind: kind, anchor_message_id: anchor, tool_use_id: tool_use_id)
  end

  test "parse and address_for round-trip every kind" do
    assert_equal({ target_kind: "conversation", anchor_message_id: nil, tool_use_id: nil },
                 Entity.parse("conversation"))
    %w[turn prompt round tool message].each do |kind|
      address = Entity.address_for(kind, 42)
      assert_equal({ target_kind: kind, anchor_message_id: 42, tool_use_id: nil },
                   Entity.parse(address))
    end
    assert_equal({ target_kind: "tool", anchor_message_id: 42, tool_use_id: "toolu_abc" },
                 Entity.parse("tool-42-toolu_abc"))
  end

  test "garbage addresses parse to nil" do
    [nil, "", "round-", "tool-x", "bogus-1", "turn-12-extra", "message-12-foo", "TURN-1"].each do |bad|
      assert_nil Entity.parse(bad), "expected #{bad.inspect} to be rejected"
    end
  end

  test "locates every kind on its true anchor" do
    prompt = text("user", "go")
    lead = text("assistant", "looking")
    call = tool_use("toolu_1")

    assert_equal "conversation", locate("conversation", nil).kind
    assert_equal prompt.id, locate("turn", prompt.id).message.id
    assert_equal prompt.id, locate("prompt", prompt.id).message.id
    assert_equal lead.id, locate("round", lead.id).message.id
    assert_equal call.id, locate("message", call.id).message.id

    tool = locate("tool", call.id)
    assert_equal "toolu_1", tool.tool_use_id, "tool_use_id resolves from the single block"
    assert_equal prompt.id, tool.turn.anchor_id, "entity knows its owning turn"
  end

  test "rejects incoherent targets" do
    prompt = text("user", "go")
    lead = text("assistant", "looking")
    call = tool_use("toolu_1")

    assert_nil locate("conversation", prompt.id), "conversation kind takes no anchor"
    assert_nil locate("turn", lead.id), "mid-turn message is not a turn anchor"
    assert_nil locate("prompt", lead.id), "assistant narrative is not a prompt"
    assert_nil locate("round", call.id), "mid-round message is not a round anchor"
    assert_nil locate("tool", lead.id), "no tool_use block here"
    assert_nil locate("tool", call.id, tool_use_id: "toolu_wrong"), "tool_use_id names no block"
    assert_nil locate("message", prompt.id + 1000), "anchor outside the conversation"
    assert_nil locate("bogus", prompt.id)
  end

  test "anchors from another conversation do not resolve" do
    text("user", "go")
    # A foreign message not in @messages — its id will not appear in any turn
    foreign = Msg.new(@id + 1000, "user", [{ "type" => "text", "text" => "hi" }])

    assert_nil locate("message", foreign.id)
  end

  test "the /compact turn is addressed by the command, and a preamble by its first member" do
    summary = text("user", "#{Turn::SUMMARY_PREAMBLE}. Earlier context.")
    command = text("user", "<command-name>/compact</command-name>")

    assert_equal command.id, locate("turn", command.id).message.id
    assert_nil locate("turn", summary.id), "the summary opens the turn but is not its anchor"

    # Build a fresh 1-element turn structure for a standalone preamble test.
    # (result is NOT in @messages, so it doesn't ride into the /compact turn above.)
    result = Msg.new(@id + 100, "user", [{ "type" => "tool_result", "tool_use_id" => "x", "content" => "ok" }])
    fresh = Turn.group([result])
    entity = Entity.locate(turns: fresh, kind: "turn", anchor_message_id: result.id)
    assert_equal result.id, entity.message.id
  end

  test "an explicit tool_use_id must match when several blocks share a message" do
    text("user", "go")
    multi = msg("assistant", [
      { "type" => "tool_use", "id" => "toolu_a", "name" => "Read", "input" => {} },
      { "type" => "tool_use", "id" => "toolu_b", "name" => "Read", "input" => {} }
    ])

    assert_nil locate("tool", multi.id), "ambiguous without an explicit id"
    assert_equal "toolu_b", locate("tool", multi.id, tool_use_id: "toolu_b").tool_use_id
  end
end
