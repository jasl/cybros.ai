require "test_helper"

# THE SHAPE OF A BIG LOOP. Node count grows with model behavior — one tool row per call, one
# continuation per round — so the paths that run on EVERY settlement are the ones that decide
# whether a long agent session stays usable. These assertions are about SHAPE (how the work scales),
# not wall clock, which is what makes them stable in CI.
class AgentLoops::ScaleTest < ActiveSupport::TestCase
  # Two graphs an order of magnitude apart. The assertions compare them
  # rather than guessing a threshold: what must hold is that the work
  # does not GROW with the graph, and a magic number would only pin
  # today's constant overhead.
  SMALL = 100
  LARGE = 1_000

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @small = build_wide_loop(SMALL)
    @large = build_wide_loop(LARGE)
  end

  # The property every hot path owes: ten times the graph, the same
  # number of round trips.
  def assert_flat(what, &block)
    small = queries_for { block.call(@small) }
    large = queries_for { block.call(@large) }

    assert_equal SMALL, @small.agent_loop_nodes.count
    assert_equal LARGE, @large.agent_loop_nodes.count
    assert_equal small, large,
      "#{what}: #{small} queries at #{SMALL} nodes but #{large} at #{LARGE} — " \
      "the work grows with the graph, which over a long turn is quadratic"
  end

  # A spine of model rounds, each with a fan hanging off it — the shape
  # the round driver actually produces, built directly because going
  # through the doors 1000 times is the thing under test, not the setup.
  def build_wide_loop(width)
    loop_row = AgentLoop.create!(
      account: @account, workspace: @workspace, creating_user: @human,
      status: "running", started_at: Time.current, approval_mode: "bypass"
    )
    now = Time.current
    rounds = width / 10
    rows = []
    rounds.times do |r|
      # The continuation SPLICES the round before it and its whole fan,
      # exactly as the driver authors it — without that the fan looks
      # like work nobody ever read, which it never is in a real graph.
      spliced = r.zero? ? [] : ["r#{r - 1}"] + Array.new(9) { |t| "r#{r - 1}t#{t}" }
      rows << node_attrs(loop_row, "r#{r}", "AgentLoopNodes::ModelTask", now,
        continuation_source: r.zero? ? nil : "round", input_from: spliced)
      9.times { |t| rows << node_attrs(loop_row, "r#{r}t#{t}", "AgentLoopNodes::ToolTask", now) }
    end
    AgentLoopNode.insert_all!(rows)
    nodes = loop_row.agent_loop_nodes.index_by(&:node_key)
    edges = []
    rounds.times do |r|
      9.times do |t|
        edges << { account_id: @account.id, agent_loop_id: loop_row.id,
                   from_node_id: nodes["r#{r}"].id, to_node_id: nodes["r#{r}t#{t}"].id,
                   created_at: now, updated_at: now }
        # ...and the fan feeds the next round. The driver always draws
        # this edge; omitting it left every tool task looking orphaned.
        next if r + 1 >= rounds

        edges << { account_id: @account.id, agent_loop_id: loop_row.id,
                   from_node_id: nodes["r#{r}t#{t}"].id, to_node_id: nodes["r#{r + 1}"].id,
                   created_at: now, updated_at: now }
      end
    end
    AgentLoopEdge.insert_all!(edges)
    loop_row
  end

  def node_attrs(loop_row, key, type, now, continuation_source: nil, input_from: [])
    {
      account_id: @account.id, agent_loop_id: loop_row.id, node_key: key,
      type: type, status: "completed", on_failure: "absorb", authored_by: "model",
      transcript_visibility: type.include?("Tool") ? "collapsed" : "visible",
      remaining_dependencies: 0, execution_generation: 0, retry_budget: 0,
      completed_at: now, created_at: now, updated_at: now,
      continuation_source: continuation_source,
      provider_id: type.include?("Model") ? "dev" : nil,
      model_ref: type.include?("Model") ? "mock-text" : nil,
      tool_name: type.include?("Tool") ? "read_file" : nil,
      tool_input: {},
      timeout_ms: type.include?("Tool") ? 600_000 : nil,
      request_options: {},
      input_from_node_keys: input_from,
    }
  end

  def queries_for
    count = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
      count += 1 unless payload[:name].to_s.in?(%w[SCHEMA TRANSACTION CACHE])
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  test "the trace projection is flat: ten times the graph, the same round trips" do
    assert_flat("the trace") { |loop_row| AgentAPI::AgentLoopPresenter.full(loop_row) }
  end

  test "quiescence is flat — it runs at EVERY terminal write" do
    assert_flat("quiescence") { |loop_row| AgentLoops::EvaluateQuiescence.call(loop_row) }
  end

  test "the scheduler's ready set is flat — it runs at every schedule wake" do
    assert_flat("the scheduler") do |loop_row|
      AgentLoops::ScheduleReady.call(agent_loop_id: loop_row.id)
    end
  end

  test "the release walk is flat — it touches a node's neighbourhood, not the graph" do
    assert_flat("the release walk") do |loop_row|
      AgentLoops::Release.settled(loop_row.agent_loop_nodes.find_by!(node_key: "r0"))
    end
  end

  test "naming a fresh round is flat, however many rounds already exist" do
    assert_flat("the round driver's key scan") do |loop_row|
      node = loop_row.agent_loop_nodes.find_by!(node_key: "r0")
      calls = [{ "id" => "c0", "name" => "read_file", "arguments" => "{}", "ordinal" => 0 }]
      AgentLoops::ExpandRound.new(loop_row, node, calls).send(:next_round_number)
    end
  end

  test "a transcript PAGE is flat — one page costs the same at any loop size" do
    assert_flat("the transcript page") do |loop_row|
      AgentLoops::Transcript.call(agent_loop: loop_row)
    end
  end

  test "the transcript page is BOUNDED in what it returns, not just in what it costs" do
    page = AgentLoops::Transcript.call(agent_loop: @large)

    assert_operator page.rounds.length, :<=, AgentLoops::Transcript::DEFAULT_LIMIT
    assert page.has_older,
      "a 100-round loop is a WINDOW of rounds, never a document - a page " \
        "renders its twenty rows with a bounded fan each, never the loop"
    page.rounds.each do |round|
      assert_operator round.fetch(:calls).fetch(:items).length, :<=,
        AgentLoops::Transcript::CALLS_SHOWN
    end
  end

  test "a settled task's SNAPSHOT costs one row, not one page" do
    round = @large.agent_loop_nodes
      .where(type: "AgentLoopNodes::ModelTask").order(:id).first

    queries = queries_for { AgentLoops::Transcript.round_snapshot(round) }
    assert_operator queries, :<=, 6,
      "the snapshot runs at the status funnel, inside the transaction " \
        "holding the loop lock - reaching the paginated reader's batches " \
        "there ran the newest-20 page query per settled task (#{queries} seen)"
  end

  test "a snapshot outside the newest page still carries its usage" do
    oldest = @large.agent_loop_nodes
      .where(type: "AgentLoopNodes::ModelTask").order(:id).first
    newest = @large.agent_loop_nodes
      .where(type: "AgentLoopNodes::ModelTask").order(id: :desc).first
    assert_not_equal oldest.id, newest.id

    snapshot = AgentLoops::Transcript.round_snapshot(oldest)
    assert_equal oldest.node_key, snapshot.fetch(:task_key),
      "the snapshot IS the row the window would serve, wherever the round " \
        "sits - keying its cost lookup off the newest page silently " \
        "dropped usage for everything older"
  end

  test "the blocked-task announcement is bounded in what it loads AND what it sends" do
    [@small, @large].each do |loop_row|
      AgentLoopNode.where(agent_loop_id: loop_row.id, type: "AgentLoopNodes::ToolTask")
        .update_all(status: "failed", on_failure: "halt", failure_resolution: nil)
      loop_row.update_columns(attention_reason: "halt_failure")
    end

    payloads = {}
    assert_flat("the blocked-task announcement") do |loop_row|
      payloads[loop_row.id] = AgentLoops::Transition
        .send(:loop_items, loop_row.reload, announced: true)
    end

    item = payloads.fetch(@large.id).find { |entry| entry[:type] == "attention_required" }
    shown = item[:payload].fetch("blocked_task_keys")
    assert_equal AgentLoops::Transition.singleton_class.const_get(:BLOCKED_KEYS_SHOWN),
      shown.length
    assert_operator item[:payload].fetch("blocked_task_overflow"), :>, 0,
      "the rest are COUNTED, never listed - this append runs inside the " \
        "transaction that was writing the graph, and an oversized item " \
        "would roll that transaction back"
  end
end
