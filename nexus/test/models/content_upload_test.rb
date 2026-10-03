require "test_helper"
require_relative "../test_helpers/agent_membership_test_helper"

# THE CREATOR IS ANCHOR-SHAPED, and THE ONE RULE the bytes read serves. An upload is staged by
# exactly one of a member or an executor — a validation over two FKs, no CHECK; the executor creator
# is readonly and set at `create!` alone. `readable_by?` is the upload's own rule: its creator, or a
# principal who can read a row that NAMES it — each body owner judged through the funnel its REST
# door uses, never the ACL alone and never a class probe.
class ContentUploadTest < ActiveSupport::TestCase
  include AgentMembershipTestHelper
  include LoopAuthoringTestHelper

  PNG = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  )

  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @human = users(:member)
    DevModelLane.ensure_enabled!(@account)
  end

  test "an upload is staged by exactly one of a member or an executor" do
    assert_predicate upload(creating_user: users(:member)), :valid?
    assert_predicate upload(creating_executor: suite_runner), :valid?

    both = upload(creating_user: users(:member), creating_executor: suite_runner)
    assert_not both.valid?
    assert_includes both.errors.details.fetch(:base).map { _1[:error] }, :exactly_one_creator

    neither = upload
    assert_not neither.valid?
    assert_includes neither.errors.details.fetch(:base).map { _1[:error] }, :exactly_one_creator
  end

  # `attr_readonly` RAISES on a later write (round history): the executor
  # creator is one write at `create!`, and nothing may re-anchor a row.
  test "both creators are readonly once staged" do
    captured = upload(creating_executor: suite_runner).tap(&:save!)
    assert_raises(ActiveRecord::ReadonlyAttributeError) { captured.update!(creating_user: users(:member)) }

    staged = upload(creating_user: users(:member)).tap(&:save!)
    assert_raises(ActiveRecord::ReadonlyAttributeError) { staged.update!(creating_executor: suite_runner) }
  end

  test "a staged row nobody names is readable by its creator alone; an executor's capture by nobody" do
    staged = upload(creating_user: users(:member)).tap(&:save!)
    assert staged.readable_by?(users(:member))
    assert_not staged.readable_by?(users(:owner))

    captured = upload(creating_executor: suite_runner).tap(&:save!)
    assert_not captured.readable_by?(users(:owner)), "an executor has no member read; the capture waits for a result"
    assert_not captured.readable_by?(users(:member))
  end

  # A conversation attachment: readable by a reader of the conversation
  # through the member plane's funnel — the workspace, the tombstone, the
  # ACL — and concealed from a principal the ACL narrows to `none`.
  test "a conversation attachment follows the conversation's funnel, and none conceals it" do
    poster = users(:owner)
    conversation = Conversation.create!(workspace: @workspace, creating_user: poster, access_default: "none")
    conversation.conversation_access_entries.create!(user: users(:curator), level: "read")
    picture = upload(creating_user: poster).tap(&:save!)
    post_attachment!(conversation, poster, picture)

    assert picture.readable_by?(users(:curator)), "a `read` entry reads the row that names it"
    assert_not picture.readable_by?(users(:member)), "`none` conceals: the row is absent, so is its attachment"
    assert picture.readable_by?(poster)

    conversation.update!(tombstoned_at: Time.current)
    assert_not picture.readable_by?(users(:curator)), "a tombstoned host names nothing to anyone"
  end

  # THE FUNNEL, NOT THE ACL: a `full` entry on a conversation in a private
  # workspace the principal cannot browse still answers absence — the
  # workspace rule is judged first, as the conversation door judges it.
  test "a workspace outside the reader's access conceals its conversation's attachment whatever the ACL says" do
    curator = users(:curator)
    private_room = workspaces(:personal)
    conversation = Conversation.create!(workspace: private_room, creating_user: curator, access_default: "full")
    conversation.conversation_access_entries.create!(user: users(:owner), level: "full")
    picture = upload(creating_user: curator).tap(&:save!)
    post_attachment!(conversation, curator, picture)

    assert picture.readable_by?(curator)
    assert_not picture.readable_by?(users(:owner)), "a `full` entry cannot open a workspace the funnel refuses"
    assert_not picture.readable_by?(users(:member))
  end

  # A tool result's CAPTURE: named by the committed body, bound to it, and
  # readable by whoever reads the loop — the task read's own funnel.
  test "a result's capture is readable by the loop's reader once a commit names it" do
    curator = users(:curator)
    capture = upload(creating_executor: suite_runner).tap(&:save!)
    agent_loop = seed(tool("alpha", "read_file", "input" => { "path" => "x" }),
      workspace: workspaces(:personal), creating_user: curator)
    AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: curator))
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    claimed = Executors::Claim.call(Executors::Claim::Command.new(
      agent_loop: agent_loop, task_key: "alpha", executor: suite_runner
    ))
    assert_predicate claimed, :accepted?
    assert_not capture.readable_by?(curator), "before the commit nothing names it"

    committed = Executors::Commit.call(Executors::Commit::Command.new(
      agent_loop: agent_loop, task_key: "alpha", executor: suite_runner, claim_token: claimed.value.claim_token,
      content: [{ "type" => "text", "text" => "saved" },
                { "type" => "resource_link", "uri" => "nexus://uploads/#{capture.public_id}", "name" => "shot.png" }],
      structured_content: nil, result_type: nil, outcome: "completed", is_error: false, title: nil, metadata: nil
    ))
    assert_predicate committed, :applied?

    body = agent_loop.agent_loop_nodes.find_by!(node_key: "alpha").content_bodies.find_by!(role: "output")
    assert_equal [capture.id], body.content_uploads.map(&:id), "the body BINDS the capture"
    assert capture.reload.readable_by?(curator), "the loop's reader reads the capture its result names"
    assert_not capture.readable_by?(users(:member)), "a stranger to the private workspace does not"
    assert_not ContentUpload.unbound.exists?(id: capture.id), "bound: the reaper cannot take it under a reader"
  end

  private

    def upload(**creator)
      @account.content_uploads.new(
        **creator,
        file: ActiveStorage::Blob.create_and_upload!(io: StringIO.new(PNG), filename: "diagram.png",
          content_type: "image/png")
      )
    end

    def post_attachment!(conversation, poster, picture)
      result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(
        host: conversation, acting_user: poster, kind: "message", role: "user",
        entries: [{ "text" => "look" }], attachments: [picture.public_id],
        visible_in_context: true, delivery_mode: "queue",
        context_mode: nil, context_options: nil, expected_context_revision: nil,
        expected_tail_turn_public_id: nil, provider_id: nil, model_ref: nil,
        reasoning_effort: nil, request_options: nil
      ))
      assert_predicate result, :accepted?, result.inspect
      result
    end
end
