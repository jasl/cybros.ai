require "test_helper"

# THE SUMMARIZER'S POINTER FOR A PICTURE: the rendering the summarizer reads shows each attachment
# of a seed or a message turn as ONE pointer line in its position — the words, then the line — under
# both producers, from the same `ContentBody#upload_parts` read history uses, so the rendering and
# the wire agree on which pictures a turn carried. Pointers, never values: the line names the
# picture by its filename and size; no public id, no byte of the image, reaches the summarizer, and
# the instructions tell it to name a pointer and never describe what it showed.
class Conversations::CompactionAttachmentsTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper

  PNG = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  )
  READ_TOOL = {
    "type" => "function",
    "function" => { "name" => "read_file", "parameters" => { "type" => "object" } },
  }.freeze
  # The one grammar of the index line, with the summary's reason.
  POINTER = "[Attachment: diagram.png (image/png, 70 bytes) — not carried past the summary; " \
    "ask for it again if needed]".freeze
  CLAUSE = "an attachment appears as a pointer with its filename; name it, never describe what it showed".freeze

  Serialize = Conversations::Compaction::Serialize

  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @user = users(:member)
    # The loop authoring helpers' creator.
    @human = @user
    @agent = users(:agent)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @user)
  end

  def upload(filename = "diagram.png")
    @account.content_uploads.create!(
      creating_user: @user,
      file: ActiveStorage::Blob.create_and_upload!(io: StringIO.new(PNG), filename: filename, content_type: "image/png")
    )
  end

  def accept!(text: "look", attachments: nil, **overrides)
    result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(**{
      host: @conversation, acting_user: @user, kind: "message",
      role: "user", entries: text ? [{ "text" => text }] : [], attachments: attachments, visible_in_context: true,
      delivery_mode: "queue", context_mode: nil, context_options: nil, expected_context_revision: nil,
      expected_tail_turn_public_id: nil, provider_id: nil, model_ref: nil,
      reasoning_effort: nil, request_options: nil,
    }.merge(overrides)))
    assert_predicate result, :accepted?, result.outcome.to_s
    result.value
  end

  def reply!(**overrides)
    accept!(**{ kind: "direct_reply", provider_id: "dev", model_ref: "mock-text" }.merge(overrides))
  end

  def drain! = Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
  def last_variant = @conversation.conversation_turns.order(:position).last.active_variant

  def settle!(answer: "seen", usage: nil)
    apply_via(admitted_attempt, sse_success(answer, **{ usage: usage }.compact))
    Conversations::Turns::Converge.call
    clear_enqueued_jobs
  end

  def admitted_attempt
    admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
      candidate.attempt.model_invocation.conversation_id == @conversation.id
    end
    raise "not admitted" if admitted.nil?

    clear_enqueued_jobs
    admitted.attempt
  end

  def declare_agent!
    outcome = Users::DeclareConfiguration.call(user: @agent,
      tool_definitions: [READ_TOOL], approval_mode: "bypass", approval_rules: nil,
      prompt_mechanism: nil, prompt_template: nil, compaction_policy: { "mode" => "kernel" }
    )
    assert_equal :declared, outcome.outcome
  end

  def refute_values(rendered, *pictures)
    pictures.each { |picture| refute_includes rendered, picture.public_id, "no upload id reaches the summarizer" }
    refute_includes rendered, "data:image", "no data URL"
    refute_includes rendered, "iVBOR", "not one byte of the picture"
    refute_includes rendered, '"type":"upload"', "never the part's JSON"
  end

  test "a message turn's picture and a reply's seed picture render as pointers after the words, under the timeline" do
    first = upload
    second = upload("second.png")
    accept!(text: "look at this", attachments: [first.public_id])
    reply!(text: "what is it?", attachments: [second.public_id])
    assert_equal 2, drain!
    settle!

    entries = Serialize.timeline_entries(@conversation.reload)

    assert_equal "User:\nlook at this\n#{POINTER}", entries.first,
      "the message turn's words, then its picture as a pointer in its position"
    assert_equal "User:\nwhat is it?\n[Attachment: second.png (image/png, 70 bytes) — not carried past the summary; " \
      "ask for it again if needed]\n\nAssistant:\nMock: seen", entries.last,
      "the reply turn's seed carries its own picture the same way, before the answer"
    assert_equal 2, entries.length
    refute_values(entries.join("\n\n"), first, second)
  end

  test "a picture with no words renders as the pointer alone" do
    alone = upload("alone.png")
    accept!(text: nil, attachments: [alone.public_id])
    assert_equal 1, drain!

    entries = Serialize.timeline_entries(@conversation.reload)

    assert_equal ["User:\n[Attachment: alone.png (image/png, 70 bytes) — not carried past the summary; " \
      "ask for it again if needed]"], entries
    refute_values(entries.sole, alone)
  end

test "a loop-backed reply's round one opens with the seed and its pointer, the same bytes under both producers" do
  @conversation = Conversation.create!(workspace: @workspace, creating_user: @user, answering_user: @agent)
  declare_agent!
  picture = upload
  reply!(text: "read the diagram", attachments: [picture.public_id])
  assert_equal 1, drain!
  agent_loop = last_variant.agent_loop
  schedule_loop!(agent_loop)
  assert_equal "running", loop_node(agent_loop, "r1").status
  # Round one reads a file, so a continuation composes over its history.
  run_loop_round!(agent_loop, sse_success("reading", tool_calls: [
    { id: "call_a", name: "read_file", arguments: %({"path":"docs/index.txt"}) },
  ]))
  AgentLoops::Parks::Settle.call(
    node: agent_loop.agent_loop_nodes.find_by!(tool_call_id: "call_a"), trusted: true,
    content: "the index", is_error: false, outcome: "completed"
  )
  continuation = agent_loop.agent_loop_nodes.where(continuation_source: "round").order(:id).last

  from_loop = Serialize.loop_entries(continuation).sole

  assert from_loop.start_with?("## Round r1\n\nUser:\nread the diagram\n#{POINTER}\n\nAssistant:\nMock: reading"),
    "the seed's words then its pointer open round one: #{from_loop.inspect}"
  refute_values(from_loop, picture)

  schedule_loop!(agent_loop)
  run_loop_round!(agent_loop, sse_success("the final word"))
  Conversations::Turns::Converge.call
  entries = Serialize.timeline_entries(@conversation.reload)
  assert_equal 2, entries.length, "one entry per round"
  assert_equal from_loop, entries.first, "one renderer, two producers, the same bytes"
  refute_values(entries.join("\n\n"), picture)
end

  test "a standalone loop step's authored prompt renders its picture as a pointer" do
    picture = upload("step.png")
    agent_loop = seed(model("s1", "prompt" => "what is this?", "attachments" => [picture.public_id]))
    node = agent_loop.agent_loop_nodes.find_by!(node_key: "s1")

    rendered = Serialize.authored_prompt(node)

    assert_equal "what is this?\n[Attachment: step.png (image/png, 70 bytes) — not carried past the summary; " \
      "ask for it again if needed]", rendered
    refute_values(rendered, picture)
  end

  test "a raw seed renders nothing, pictures included" do
    picture = upload("raw.png")
    reply!(text: nil, context_mode: "raw", entries: [{
      "role" => "user",
      "parts" => [{ "type" => "text", "text" => "raw words" }, { "type" => "upload", "upload_public_id" => picture.public_id }],
    }])
    assert_equal 1, drain!
    assert_equal [picture.id], last_variant.content_bodies.find_by!(role: "prompt").content_uploads.map(&:id),
      "raw binds what its parts placed"
    settle!

    entries = Serialize.timeline_entries(@conversation.reload)

    assert_equal ["Assistant:\nMock: seen"], entries, "raw is never enriched: no words, no pointer"
  end

  test "the summarizer is told to name a pointer and never describe what it showed" do
    # The text wraps for the model's reading; the clause is one sentence.
    instructions = Conversations::Compaction::Summarizer::INSTRUCTIONS.gsub(/\s+/, " ")

    assert_includes instructions, CLAUSE
    assert_operator instructions.index("WHAT TO RE-READ: list"), :<, instructions.index(CLAUSE),
      "the clause sits under WHAT TO RE-READ, beside the tool-result rule"
  end

  test "the between-turn summarizer is handed the pointer, never the id, and the picture leaves the wire after the cut" do
    picture = upload
    reply!(text: "describe the diagram", attachments: [picture.public_id])
    assert_equal 1, drain!
    settle!(answer: "a diagram", usage: { "input_tokens" => 9_000, "output_tokens" => 5 })

    reply!(text: "and now?")
    assert_equal 0, drain!, "the head waits behind the summary"
    summary_turn = @conversation.conversation_turns.find_by!(kind: "compaction_summary")
    handed = summary_turn.active_variant.agent_loop.agent_loop_nodes.sole
      .content_bodies.find_by!(role: "input").effective_text

    assert_includes handed, "User:\ndescribe the diagram\n#{POINTER}\n\nAssistant:\nMock: a diagram"
    refute_values(handed, picture)
    assert_empty summary_turn.active_variant.agent_loop.agent_loop_nodes.sole.content_bodies
      .find_by!(role: "input").content_uploads, "the summarizer's request binds no picture"
  end
end
