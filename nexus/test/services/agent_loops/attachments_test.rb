require "test_helper"

# THE LOOP'S MODEL STEP: `attachments` beside a model step's `prompt` compose the same parts entry
# the input doors write — bound, pinned, the prompt as the words — resolved against the door's
# creator; a kernel author cannot name one; round one seals the placed set and a later round
# re-reads it through the sealed prefix.
class AgentLoops::AttachmentsTest < ActiveJob::TestCase
  include InvocationHarness

  Append = AgentLoops::Tasks::Append
  Step = AgentLoops::Tasks::Step

  PNG = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  )

  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @human = users(:member)
    DevModelLane.ensure_enabled!(@account)
  end

  def upload(filename = "step.png", creating_user: @human)
    @account.content_uploads.create!(
      creating_user: creating_user,
      file: ActiveStorage::Blob.create_and_upload!(io: StringIO.new(PNG), filename: filename, content_type: "image/png")
    )
  end

  def node(agent_loop, key) = agent_loop.agent_loop_nodes.find_by!(node_key: key)
  def payloads(body) = body.content_body_entries.map { |entry| entry.content_fragment.payload }
  def request_of(node) = ContentBody.find_by!(model_invocation_id: node.reload.selected_model_invocation_id, role: "request")

  def start!(agent_loop)
    result = AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: @human))
    assert_predicate result, :accepted?, result.outcome.to_s
    clear_enqueued_jobs
    agent_loop.reload
  end

  def schedule!(agent_loop)
    clear_enqueued_jobs
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    agent_loop.reload
  end

  # Stamped, not transitioned: the append door reads the spine's settlement.
  def settle!(agent_loop, key)
    node(agent_loop, key).update_columns(status: "completed", completed_at: Time.current)
  end

  def run_step!(agent_loop, behaviour = sse_success("the answer"))
    admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
      candidate.attempt.model_invocation.agent_loop_id == agent_loop.id
    end
    raise "step not admitted" if admitted.nil?

    apply_via(admitted.attempt, behaviour)
    AgentLoops::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    agent_loop.reload
  end

  test "a model step with attachments writes the parts input body, bound, with the prompt as its words" do
    picture = upload
    agent_loop = seed(model("s1", "prompt" => "what is this?", "attachments" => [picture.public_id]))

    body = node(agent_loop, "s1").content_bodies.find_by!(role: "input")
    assert_predicate body, :sealed?
    assert_equal [{ "role" => "user", "parts" => [
      { "type" => "text", "text" => "what is this?" },
      { "type" => "upload", "upload_public_id" => picture.public_id },
    ] }], payloads(body)
    assert_equal [picture.id], body.content_uploads.map(&:id)
    assert_equal "what is this?", body.readable_text, "the summarizer's authored_prompt reads the words"
    assert_equal [picture.id], body.upload_parts.map(&:id)
  end

  test "the append door resolves against the acting member, and refuses another creator's picture" do
    agent_loop = seed(model("s1"))
    settle!(agent_loop, "s1")
    theirs = upload("theirs.png", creating_user: users(:curator))

    refused = grow(agent_loop, model("s2", "attachments" => [theirs.public_id]), creator: @human)
    assert_equal :unknown_input_upload, refused.outcome

    mine = upload("mine.png")
    grown = grow!(agent_loop, model("s2", "attachments" => [mine.public_id]), creator: @human)
    assert_predicate grown, :applied?
    assert_equal [mine.id], node(agent_loop, "s2").content_bodies.find_by!(role: "input").content_uploads.map(&:id)

    settle!(agent_loop, "s2")
    creatorless = grow(agent_loop, model("s3", "attachments" => [mine.public_id]))
    assert_equal :attachments_not_authorable, creatorless.outcome, "no creator, no resolution"
  end

  test "a kernel author naming attachments is refused positionally; a malformed id refuses; a PDF binds" do
    agent_loop = seed(model("s1"))
    settle!(agent_loop, "s1")
    picture = upload
    kernel = Append.call(Append::Command.kernel(
      agent_loop: agent_loop, origin: "kernel", tip: AgentLoops::Tasks::Tip.seed("branch"),
      steps: [Step::Model.new(key: "k1", model: { "model" => "dev/mock-text" }, prompt: "p",
        attachments: [picture.public_id])]
    ))
    assert_equal :invalid_steps, kernel.outcome
    assert_equal [{ "code" => "attachments_not_authorable", "path" => "steps[0].attachments" }], kernel.errors

    malformed = grow(agent_loop, model("s2", "attachments" => ["not-a-uuid"]), creator: @human)
    assert_equal :invalid_steps, malformed.outcome
    assert_equal [{ "code" => "invalid_attachments", "path" => "steps[0].attachments" }], malformed.errors
    assert_equal :invalid_steps, grow(agent_loop, model("s2", "attachments" => []), creator: @human).outcome

    pdf = @account.content_uploads.create!(
      creating_user: @human,
      file: ActiveStorage::Blob.create_and_upload!(io: StringIO.new("%PDF-"), filename: "p.pdf",
        content_type: "application/pdf", identify: false)
    )
    assert_predicate grow(agent_loop, model("s2", "attachments" => [pdf.public_id]), creator: @human), :applied?
    assert_equal [pdf.id], node(agent_loop, "s2").input_body.content_uploads.pluck(:id)
  end

  test "round one seals the placed row and round two re-reads it through the sealed prefix" do
    picture = upload
    agent_loop = seed(model("s1", "prompt" => "look", "attachments" => [picture.public_id]))

    start!(agent_loop)
    schedule!(agent_loop)
    s1 = node(agent_loop, "s1")
    assert_equal "running", s1.status
    first = request_of(s1)
    assert_equal [picture.id], first.content_uploads.map(&:id), "the seal binds what it sends"
    assert_equal %w[text upload], Array(payloads(first).last["parts"]).map { |part| part["type"] }

    run_step!(agent_loop)
    grow!(agent_loop, model("s2", "prompt" => "and then?"), creator: @human)
    schedule!(agent_loop)
    second = request_of(node(agent_loop, "s2"))
    assert_equal [picture.id], second.content_uploads.map(&:id), "the prefix's picture is placed again"
    uploads_placed = payloads(second).flat_map { |p| Array(p["parts"]) }.count { |part| part["type"] == "upload" }
    assert_equal 1, uploads_placed
  end

  test "on a text-only row the round seals the line and binds nothing" do
    picture = upload("diagram.png")
    agent_loop = seed(model("s1", "model" => { "model" => "dev/mock-text-only" }, "prompt" => "look",
      "attachments" => [picture.public_id]))

    start!(agent_loop)
    schedule!(agent_loop)
    request = request_of(node(agent_loop, "s1"))
    assert_empty request.content_uploads
    parts = payloads(request).last["parts"]
    assert_equal %w[text text], parts.map { |part| part["type"] }
    assert_equal "[Attachment: diagram.png (image/png, 70 bytes) — image content omitted: this model does not support image input]", parts.last["text"]
  end
end
