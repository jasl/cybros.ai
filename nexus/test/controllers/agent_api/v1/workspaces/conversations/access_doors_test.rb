require "test_helper"

# THE DOOR TABLE: every member-plane door over a conversation — and over the loop its turn hosts —
# read through ONE funnel and judged by ONE predicate. `none` is absence on every door, read or
# write, for a second Human and for an agent alike: 404, never a 403 on a hidden row. `read` is
# read: the lists carry it and every read answers 200; every write — the fourteen service conjuncts,
# the compaction request, the store fence, the memory door, the handoff and the loop's five doors —
# answers 403 `not_authorized`.
class AgentAPI::V1::Workspaces::Conversations::AccessDoorsTest < ActionDispatch::IntegrationTest
  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @creator = users(:member)
    DevModelLane.ensure_enabled!(@account)
    @creator_secret = create_access_token_fixture(user: @creator, name: "Creator").secret
    @curator_secret = create_access_token_fixture(user: users(:curator), name: "Curator").secret
    # An Agent's member credential is OAuth-only: the real ceremony.
    @agent_secret = connect_agent_session(
      steward: users(:owner), agent_identifier: users(:agent).agent_identifier
    ).access_secret

    @conversation = Conversation.create!(workspace: @workspace, creating_user: @creator, access_default: "none")
    @seam = create_loop_backed_turn(conversation: @conversation, acting_user: @creator)
    @input = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(
      host: @conversation, acting_user: @creator, kind: "message", role: "user",
      entries: [{ "text" => "queued" }], visible_in_context: true, delivery_mode: "queue",
      context_mode: nil, context_options: nil, expected_context_revision: nil,
      expected_tail_turn_public_id: nil, provider_id: nil, model_ref: nil,
      reasoning_effort: nil, request_options: nil
    )).value
  end

  def bearer(secret, key: nil)
    headers = { "Authorization" => "Bearer #{secret}" }
    headers["Idempotency-Key"] = key if key
    headers
  end

  def principals = { "a second Human" => @curator_secret, "an agent" => @agent_secret }

  def ws = "/agent_api/v1/workspaces/#{@workspace.public_id}"
  def conversations = "#{ws}/conversations"
  def c = "#{conversations}/#{@conversation.public_id}"
  def turn = "#{c}/turns/#{@seam.turn.public_id}"
  def variant = "#{turn}/variants/#{@seam.variant.public_id}"
  def loops = "#{ws}/agent_loops"
  def l = "#{loops}/#{@seam.agent_loop.public_id}"

  # Every read door over the row and over its loop.
  def read_doors
    [
      [:get, c], [:get, "#{c}/turns"], [:get, "#{c}/events"], [:get, "#{c}/inputs"],
      [:get, "#{c}/store_entries"], [:get, "#{c}/memory"], [:get, "#{c}/children"],
      [:get, "#{turn}/variants"],
      [:get, l], [:get, "#{l}/graph"], [:get, "#{l}/phases"], [:get, "#{l}/transcript"],
    ]
  end

  # Every write door, with a body that passes the boundary so the verdict is
  # the door's own — the fourteen conjuncts, the store fence, the memory
  # door, the handoff, and the loop's five doors.
  def write_doors
    [
      [:post, "#{c}/inputs", { input: { text: "hi" } }, "in-1"],
      [:patch, "#{c}/inputs/#{@input.public_id}", { input: { text: "edited" } }],
      [:delete, "#{c}/inputs/#{@input.public_id}"],
      [:post, "#{c}/inputs/reorder", { inputs: [@input.public_id] }],
      [:patch, c, { conversation: { title: "renamed" } }],
      [:delete, c],
      [:post, "#{c}/archive"],
      [:post, "#{c}/unarchive"],
      [:post, "#{c}/forks", { fork: { turn_public_id: @seam.turn.public_id } }, "fk-1"],
      [:post, "#{c}/cancellation"],
      [:post, "#{c}/compaction"],
      [:post, "#{turn}/edit", { edit: { text: "again" } }],
      [:post, "#{turn}/regeneration"],
      [:patch, turn, { turn: { concealed: true } }],
      [:delete, turn],
      [:patch, variant, { variant: { concealed: true } }],
      [:post, "#{variant}/activation"],
      [:post, "#{c}/memory", { memory: { path: "conversation/plan.md", content: "x" } }],
      [:post, "#{c}/memory/delete", { memory: { path: "conversation/plan.md" } }],
      [:post, "#{c}/store_entries", { store_entry: { namespace: "ui", key: "k", value: { "a" => 1 } } }, "st-1"],
      [:put, "#{c}/runner", { runner: { executor_public_id: SecureRandom.uuid_v7 } }],
      [:delete, l],
      [:post, "#{l}/tasks", { steps: [{ "ask" => { "key" => "q", "prompt" => "?" } }] }],
      [:post, "#{l}/tasks/x/resolution", { outcome: "completed" }],
      [:post, "#{l}/tasks/x/approve"],
      [:post, "#{l}/tasks/x/deny", { reason: "no" }],
      [:post, "#{l}/tasks/x/retry"],
      [:post, "#{l}/tasks/x/abandon"],
      [:post, "#{l}/tasks/x/compact"],
      [:post, "#{l}/start"], [:post, "#{l}/pause"], [:post, "#{l}/resume"], [:post, "#{l}/stop"],
      [:post, "#{l}/inputs", { input: { text: "hi" } }, "li-1"],
    ]
  end

  # Doors a `none` principal must find absent, whose `read` answer is not a
  # plain 200: the two sealed-request debug doors (`request_not_sealed`
  # here, since no round has sealed) and the loop's handoff (409
  # `conversation_hosted` on a loop-backed loop).
  def none_only_doors
    [
      [:get, "#{variant}/request"], [:get, "#{l}/tasks/x/request"],
      [:put, "#{l}/runner", { runner: { executor_public_id: SecureRandom.uuid_v7 } }],
    ]
  end

  def knock(verb, path, body, key, secret)
    public_send(verb, path, headers: bearer(secret, key: key && "#{key}-#{secret[0, 6]}"),
      as: :json, params: body)
  end

  test "none is absence on every door: 404 for a second Human and for an agent, read or write" do
    principals.each do |who, secret|
      get conversations, headers: bearer(secret)
      assert_response :success
      assert_empty response.parsed_body.fetch("conversations"), "#{who}: the working list conceals it"
      get loops, headers: bearer(secret)
      assert_response :success
      assert_empty response.parsed_body.fetch("agent_loops"), "#{who}: the loop list conceals its loop"

      (read_doors + write_doors + none_only_doors).each do |verb, path, body, key|
        knock(verb, path, body, key, secret)
        assert_response :not_found, "#{who}: #{verb.upcase} #{path}"
        assert_equal "not_found", response.parsed_body.dig("error", "code"), "#{who}: #{verb.upcase} #{path}"
      end
    end

    assert_not @conversation.reload.tombstoned?
    assert_equal 1, @conversation.conversation_inputs.count, "nothing landed through a hidden door"
  end

  test "read is read: the lists carry it and every read is 200; every write is 403 not_authorized" do
    @conversation.update!(access_default: "read")

    principals.each do |who, secret|
      get conversations, headers: bearer(secret)
      assert_response :success
      assert_equal [@conversation.public_id],
        response.parsed_body.fetch("conversations").map { |row| row["public_id"] }, who
      get loops, headers: bearer(secret)
      assert_equal [@seam.agent_loop.public_id],
        response.parsed_body.fetch("agent_loops").map { |row| row["public_id"] }, who

      read_doors.each do |verb, path|
        knock(verb, path, nil, nil, secret)
        assert_response :success, "#{who}: #{verb.upcase} #{path} — #{response.body}"
      end
      get "#{variant}/request", headers: bearer(secret)
      assert_equal "request_not_sealed", response.parsed_body.dig("error", "code"),
        "#{who}: the debug door is reached, and answers for itself"

      write_doors.each do |verb, path, body, key|
        knock(verb, path, body, key, secret)
        assert_response :forbidden, "#{who}: #{verb.upcase} #{path} — #{response.body}"
        assert_equal "not_authorized", response.parsed_body.dig("error", "code"), "#{who}: #{verb.upcase} #{path}"
      end
    end

    assert_equal "queued", @input.reload.content_body.effective_text, "no edit landed"
    assert_equal 1, @conversation.conversation_inputs.count
    assert_equal 0, @conversation.store_entries.count
    assert_equal 0, MemoryDocument.where(conversation_id: @conversation.id).count
    assert_not @conversation.reload.tombstoned?
    assert_not @seam.agent_loop.reload.tombstoned?
  end

  # An entry outranks the default both ways, and the creator is full by
  # derivation whatever the default says — through the doors, not the model.
  test "an entry outranks the default on the wire, and the creator is never concealed" do
    @conversation.conversation_access_entries.create!(user: users(:curator), level: "full")
    post "#{c}/inputs", headers: bearer(@curator_secret, key: "cur-1"), as: :json, params: { input: { text: "mine" } }
    assert_response :accepted

    @conversation.reload.update!(access_default: "full")
    @conversation.conversation_access_entries.create!(user: users(:agent), level: "none")
    get c, headers: bearer(@agent_secret)
    assert_response :not_found

    @conversation.update!(access_default: "none")
    get c, headers: bearer(@creator_secret)
    assert_response :success
    assert_equal "none", response.parsed_body.dig("conversation", "access", "default")
  end

  # The listing's funnel adds no query per row: more rows with more
  # principals' entries cost the same queries as one.
  test "the working list funnels without a query per row" do
    @conversation.update!(access_default: "read")
    get conversations, headers: bearer(@curator_secret)
    one = sql_count { get conversations, headers: bearer(@curator_secret) }
    assert_equal 1, response.parsed_body.fetch("conversations").length

    Conversation.create!(workspace: @workspace, creating_user: users(:owner), access_default: "none")
      .conversation_access_entries.create!(user: users(:curator), level: "read")
    Conversation.create!(workspace: @workspace, creating_user: users(:curator))
    Conversation.create!(workspace: @workspace, creating_user: users(:owner), access_default: "none")
    more = sql_count { get conversations, headers: bearer(@curator_secret) }
    assert_equal 3, response.parsed_body.fetch("conversations").length
    assert_equal one, more, "three visible rows, the same queries"
  end

  private

    # The SQL a block runs, schema and transaction chatter excluded.
    def sql_count
      count = 0
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name])
      end
      yield
      count
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
end
