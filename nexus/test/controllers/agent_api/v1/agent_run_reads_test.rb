require "test_helper"
require "test_helpers/agent_run_api_test_helper"

class AgentAPI::V1::AgentRunReadsTest < ActionDispatch::IntegrationTest
  include AgentRunAPITestHelper

  # THE QUESTION AN AWAIT IS ASKING, readable. A model composing `ask`
  # authors a prompt and `Tasks::Append` seals it as the node's input
  # body — and nothing served it, so the one task kind that exists to be
  # answered by a person could not be read by one. It parked to its
  # deadline instead.
  test "an await serves the question it was authored with" do
    post loops_path, headers: auth(SecureRandom.uuid), as: :json, params: {
      run: { approval_mode: "bypass", steps: [
        { ask: { key: "gate", prompt: "Which auth path is live, oauth or saml?" } },
      ] },
    }
    assert_response :created
    loop_id = response.parsed_body.dig("run", "public_id")

    get "#{loops_path}/#{loop_id}/tasks/gate", headers: auth

    assert_response :success
    assert_equal "Which auth path is live, oauth or saml?",
      response.parsed_body.dig("task", "prompt")
    # The token is a bearer capability and travels only in the creator's
    # receipt — reading the question must not hand it out.
    assert_not_includes response.body, "resolution_token"
  end

  # THE AUTHORED SIDE OF ANY TASK THAT HAS ONE. This once served `prompt`
  # for an await only, on the reasoning that every other kind's input was
  # "the composed request, which the transcript serves" — and the
  # transcript serves no such thing: its round row carries `text_preview`,
  # the model's own ANSWER. So the words a person wrote were stored and
  # unreadable, which is the same write-path-without-a-read-path defect
  # the await's own prompt was added to fix.
  test "any task serves the prompt it was authored with, and a spliced one has none" do
    post loops_path, headers: auth(SecureRandom.uuid), as: :json, params: {
      run: { approval_mode: "bypass", steps: [
        { model: { key: "seed", model: MODEL, prompt: "the round's own question" } },
        { ask: { key: "gate", prompt: "what should I do?" } },
      ] },
    }
    loop_id = response.parsed_body.dig("run", "public_id")

    get "#{loops_path}/#{loop_id}/tasks/seed", headers: auth
    assert_response :success
    assert_equal "the round's own question", response.parsed_body.dig("task", "prompt"),
      "a console must be able to show a person their own words back"

    get "#{loops_path}/#{loop_id}/tasks/gate", headers: auth
    assert_equal "what should I do?", response.parsed_body.dig("task", "prompt")
  end

  test "a model task exposes its frozen declarations before scheduling including aliases and no tools" do
    declared = [
      { "type" => "function", "function" => { "name" => "read_file",
        "parameters" => { "type" => "object", "properties" => { "path" => { "type" => "string" } } } } },
      { "name" => "Clarify", "canonical" => "nexus.human.ask",
        "params" => { "question" => { "maps_to" => "prompt" } }, "omit" => ["multi"] },
    ]
    agent_run = created_loop([
      { model: { key: "seed", model: MODEL, prompt: "Read and clarify.", tools: declared } },
      { model: { key: "empty", model: MODEL, prompt: "Answer from context." } },
      { ask: { key: "gate", prompt: "Continue?" } },
    ])

    get "#{loops_path}/#{agent_run.public_id}/tasks/seed", headers: auth
    assert_response :success
    detail = response.parsed_body.fetch("task")
    assert_equal agent_run.agent_run_tasks.find_by!(node_key: "seed").tool_definitions,
      detail.fetch("tool_definitions")
    clarification = detail.fetch("tool_definitions").find { |entry| entry.dig("function", "name") == "Clarify" }
    assert_equal "nexus.human.ask", clarification.fetch("canonical")
    assert_equal({ "question" => { "maps_to" => "prompt" } }, clarification.fetch("params"))
    assert_equal ["multi"], clarification.fetch("omit")
    assert_not detail.key?("request_bytes"), "the declarations do not depend on a provider request"

    get "#{loops_path}/#{agent_run.public_id}/tasks/empty", headers: auth
    assert_response :success
    assert_equal [], response.parsed_body.fetch("task").fetch("tool_definitions")

    get "#{loops_path}/#{agent_run.public_id}/tasks/gate", headers: auth
    assert_response :success
    assert_not response.parsed_body.fetch("task").key?("tool_definitions")

    get "#{loops_path}/#{agent_run.public_id}", headers: auth
    assert_response :success
    assert response.parsed_body.dig("run", "tasks").none? { |row| row.key?("tool_definitions") },
      "the trace remains a task list"
  end

  # THE WRITE PATH AND THE READ PATH, over HTTP, in one test — because
  # shipping one without the other is how "a structured result reads back
  # as its serialized text and nothing else" becomes permanent.
  test "the result grammar round-trips: blocks in, blocks and structure out" do
    loop_id = create_await_loop!
    token = response.parsed_body.dig("receipt", "resolution_tokens", "gate")
    agent_run = loop_record(loop_id)
    post "#{loops_path}/#{loop_id}/start", headers: auth
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)

    post "#{loops_path}/#{loop_id}/tasks/gate/resolution", headers: auth, as: :json,
      params: {
        resolution_token: token, result_type: "complete",
        content: [{ "type" => "text", "text" => "22.5 degrees" }],
        structured_content: { "temperature" => 22.5 },
      }
    assert_response :success

    get "#{loops_path}/#{loop_id}/tasks/gate", headers: auth
    assert_response :success
    detail = response.parsed_body.fetch("task")
    assert_equal "22.5 degrees", detail.fetch("output"),
      "the text projection is unchanged — every existing reader keeps working"
    assert_equal [{ "type" => "text", "text" => "22.5 degrees" }], detail.fetch("content")
    assert_equal({ "temperature" => 22.5 }, detail.fetch("structured_content"))
  end

  # THE TWO UI FIELDS, over HTTP: what the executor plane's commit carried as `title` and `metadata`
  # reads back on the member plane's single-task read — and on nothing else. A structured result
  # with no text serves `output: ""`, never the entry JSON.
  test "a task read serves the title and metadata the executor committed" do
    post loops_path, headers: auth(SecureRandom.uuid), as: :json, params: {
      run: { approval_mode: "bypass", default_runner_executor_public_id: suite_runner.public_id,
                    steps: [{ tool: { key: "call", name: "read_file", route: { kind: "runner" }, input: { path: "x.rb" } } }] },
    }
    assert_response :created
    loop_id = response.parsed_body.dig("run", "public_id")
    agent_run = loop_record(loop_id)
    post "#{loops_path}/#{loop_id}/start", headers: auth
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    claim = Executors::Claim.call(Executors::Claim::Command.new(
      agent_run: agent_run, task_key: "call", executor: suite_runner
    ))
    assert_predicate claim, :accepted?
    committed = Executors::Commit.call(Executors::Commit::Command.new(
      agent_run: agent_run, task_key: "call", executor: suite_runner, claim_token: claim.value.claim_token,
      content: nil, structured_content: { "lines" => 1 }, result_type: nil, outcome: "completed",
      is_error: false, title: "read x.rb", metadata: { "checkpoint" => "c1" }
    ))
    assert_predicate committed, :applied?

    get "#{loops_path}/#{loop_id}/tasks/call", headers: auth
    assert_response :success
    detail = response.parsed_body.fetch("task")
    assert_equal "read x.rb", detail.fetch("title")
    assert_equal({ "checkpoint" => "c1" }, detail.fetch("metadata"))
    assert_equal "", detail.fetch("output"), "structure alone hands the model nothing"
    assert_equal({ "lines" => 1 }, detail.fetch("structured_content"))
    assert_not detail.key?("content")

    get "#{loops_path}/#{loop_id}", headers: auth
    row = response.parsed_body.dig("run", "tasks").find { |task| task.fetch("key") == "call" }
    assert_not row.key?("title"), "the trace stays a task list"
    assert_not row.key?("metadata")
  end

  test "the full projection carries the attention hold" do
    loop_id = create_loop!
    loop_record(loop_id).update!(status: "needs_attention",
      attention_reason: "deliverable_unresolved")

    get "#{loops_path}/#{loop_id}", headers: auth
    assert_response :success
    attention = response.parsed_body.dig("run", "attention")
    assert_equal "deliverable_unresolved", attention["reason"]
    assert_nil attention["expires_at"],
      "the ask has no clock - nothing to render"
  end

  # The announce split stamps a reason on a RUNNING loop too — a model's
  # question, or a halt failure resting behind an open window — so gating
  # the projection on the status meant a REST read of a loop waiting on a
  # person showed nothing at all.
  test "attention renders whenever a reason stands, not only when the status holds" do
    loop_id = create_loop!
    loop_record(loop_id).update!(status: "running", attention_reason: "awaiting_human")

    get "#{loops_path}/#{loop_id}", headers: auth
    assert_response :success
    assert_equal "awaiting_human", response.parsed_body.dig("run", "attention", "reason")
  end

  # A listing loads no tasks, so it has nothing else from which to answer
  # "which of my loops needs me".
  test "the list row carries the attention rollup, and the filter finds it" do
    quiet = create_loop!
    asking = create_loop!
    loop_record(asking).update!(status: "running", attention_reason: "halt_failure")

    get loops_path, headers: auth
    rows = response.parsed_body.fetch("runs").to_h { |row| [row.fetch("public_id"), row] }
    assert_equal "halt_failure", rows.fetch(asking).dig("attention", "reason")
    assert_nil rows.fetch(quiet)["attention"], "a loop needing nobody says nothing"

    get loops_path, headers: auth, params: { attention: "any" }
    assert_equal [asking], response.parsed_body.fetch("runs").map { |row| row.fetch("public_id") }
  end

  test "the list filters by status and refuses a word it does not know" do
    running = create_loop!
    loop_record(running).update!(status: "running")
    done = create_loop!
    loop_record(done).update!(status: "completed")

    get loops_path, headers: auth, params: { status: "running,completed" }
    assert_equal 2, response.parsed_body.fetch("runs").length

    get loops_path, headers: auth, params: { status: "completed" }
    assert_equal [done], response.parsed_body.fetch("runs").map { |row| row.fetch("public_id") }

    get loops_path, headers: auth, params: { status: "finished" }
    assert_response :bad_request
    assert_equal "parameter_invalid", response.parsed_body.dig("error", "code")
  end

  # "My most recent first" is the only ordering question a person asks, and
  # the cursor has to carry the direction: a page taken one way and
  # continued the other walks back over what the caller already has.
  test "a list can be read newest-first, and a cursor cannot change direction" do
    first = create_loop!
    second = create_loop!
    ordered = [first, second].sort

    get loops_path, headers: auth, params: { order: "desc", limit: 1 }
    assert_response :success
    assert_equal [ordered.last], response.parsed_body.fetch("runs").map { |row| row.fetch("public_id") }
    cursor = response.parsed_body.dig("pagination", "next_after")
    refute_nil cursor

    get loops_path, headers: auth, params: { order: "desc", after: cursor }
    assert_equal [ordered.first], response.parsed_body.fetch("runs").map { |row| row.fetch("public_id") }

    get loops_path, headers: auth, params: { after: cursor }
    assert_response :bad_request
    assert_equal "parameter_invalid", response.parsed_body.dig("error", "code")

    get loops_path, headers: auth, params: { order: "sideways" }
    assert_response :bad_request
  end

  # The trace says what a task IS; a reader with no arguments cannot render
  # a call at all, and this same read already returns its OUTPUT.
  test "a tool call read carries what it was asked to run" do
    loop_id = create_loop!
    agent_run = loop_record(loop_id)
    node = agent_run.agent_run_tasks.create!(
      node_key: "call", type: "AgentRunTasks::ToolTask",
      authored_by: "author",
      tool_name: "read", tool_input: { "path" => "/srv/app/config.rb" }
    )

    get "#{loops_path}/#{loop_id}/tasks/#{node.node_key}", headers: auth
    assert_response :success
    assert_equal({ "path" => "/srv/app/config.rb" },
      response.parsed_body.dig("task", "tool_input"))

    get "#{loops_path}/#{loop_id}", headers: auth
    task = response.parsed_body.dig("run", "tasks").find { |row| row.fetch("key") == "call" }
    assert_nil task["tool_input"], "the trace stays a task list, not an execution plan"
  end

  # Who a started call was addressed to and who holds it: the role and the address on the trace, the
  # claimant's public-id snapshot — never the effect profile or a countdown.
  test "a tool call read names its addressee and its claimant" do
    loop_id = create_loop!
    agent_run = loop_record(loop_id)
    pooled = agent_run.agent_run_tasks.create!(
      node_key: "pooled", type: "AgentRunTasks::ToolTask", tool_name: "net_fetch", tool_input: {},
      authored_by: "author"
    )
    pooled.update_columns(addressed_role: "tool_provider",
      claimed_by_executor_public_id: "01900000-0000-7000-8000-00000000abcd")
    bound = agent_run.agent_run_tasks.create!(
      node_key: "bound", type: "AgentRunTasks::ToolTask", tool_name: "read", tool_input: {},
      authored_by: "author"
    )
    bound.update_columns(addressed_role: "runner", addressed_executor_id: suite_runner.id)

    get "#{loops_path}/#{loop_id}", headers: auth
    tasks = response.parsed_body.dig("run", "tasks").index_by { |row| row.fetch("key") }
    assert_equal({ "role" => "tool_provider" }, tasks.fetch("pooled").fetch("addressed_to"))
    assert_equal({ "executor_public_id" => "01900000-0000-7000-8000-00000000abcd" },
      tasks.fetch("pooled").fetch("claimed_by"))
    assert_equal({ "role" => "runner", "executor_public_id" => suite_runner.public_id, "presence" => "not_yet_seen" },
      tasks.fetch("bound").fetch("addressed_to"), "the addressee's presence rides the trace (r-modes M4)")
    assert_not tasks.fetch("bound").key?("claimed_by")
    assert_not tasks.fetch("seed").key?("addressed_to"), "a model task is addressed to nobody"
    assert_not tasks.fetch("pooled").key?("effect_profile")

    get "#{loops_path}/#{loop_id}/tasks/pooled", headers: auth
    assert_equal({ "role" => "tool_provider" }, response.parsed_body.dig("task", "addressed_to"))
  end

  # THE ROUTE HAD NO TEST, and a live journey found a 500 on it. The
  # service is covered; the controller — cursor decoding, the limit, the
  # envelope and the prefix a console expands a branch by — was not.
  test "the transcript route serves the thread, and a branch under a call by prefix" do
    loop_id = create_loop!
    agent_run = loop_record(loop_id)

    get "#{loops_path}/#{loop_id}/transcript", headers: auth, params: { limit: 5 }

    assert_response :success
    body = response.parsed_body
    assert_equal %w[rounds pagination], body.keys, "one density: no view echoes back"
    row = body.fetch("rounds").sole
    assert_equal "seed", row.fetch("task_key")
    assert row.fetch("mainline")
    assert_equal({ "count" => 0, "items" => [] }, row.fetch("calls"))
    assert_equal [], row.fetch("branches")
    refute body.dig("pagination", "has_older")
    assert_nil agent_run.reload.completed_at, "the read changes nothing"

    get "#{loops_path}/#{loop_id}/transcript", headers: auth, params: { prefix: "seed" }
    assert_response :not_found
    assert_equal "not_found", response.parsed_body.dig("error", "code"),
      "a branch hangs under a CALL; a round or a key the loop never had is a miss — " \
      "one code for one miss, the family's (base_controller)"
  end

  test "the transcript route refuses a cursor that is not one" do
    loop_id = create_loop!

    get "#{loops_path}/#{loop_id}/transcript", headers: auth, params: { before: "not-a-cursor" }

    assert_response :bad_request
    assert_equal "parameter_invalid", response.parsed_body.dig("error", "code")
  end

  test "the replay window is strictly-after, ascending, bounded, and watermarked" do
    loop_id = create_loop!
    agent_run = loop_record(loop_id)
    3.times do |n|
      ConversationEvent::Append.call(
        host: agent_run,
        items: [{ type: "turn_status", payload: { "run_status" => "running", "n" => n } }]
      )
    end

    get "#{loops_path}/#{loop_id}/events", headers: auth
    assert_response :success
    body = response.parsed_body
    assert_equal 4, body.fetch("events").length, "the seed task's birth plus three"
    assert_equal (1..4).to_a, body.fetch("events").map { |e| e["sequence"] }
    assert_equal 4, body.dig("pagination", "watermark")
    assert_equal "run", body.dig("events", 0, "resource", "type")
    assert_equal 1, ConversationEventItem::ReplayCursor.decode(body.dig("events", 0, "cursor")),
      "one plane, one replay prefix"

    cursor = body.dig("events", 1, "cursor")
    get "#{loops_path}/#{loop_id}/events?after=#{cursor}&limit=1", headers: auth
    assert_response :success
    page = response.parsed_body
    assert_equal [3], page.fetch("events").map { |e| e["sequence"] }, "strictly after"
    assert_equal 4, page.dig("pagination", "watermark"),
      "the watermark is the committed max, not the page's end"

    get "#{loops_path}/#{loop_id}/events?after=not-a-cursor", headers: auth
    assert_response :bad_request
  end

  # A loop-backed loop's narration is its conversation's: serving the conversation's whole stream
  # under a loop id would hand a follower other turns' items, so the loop's feed refuses by name.
  # THE DEBUG DOOR on a task: the round's sealed request — exactly the entries and the
  # request_options, tools included; a task with none is `request_not_sealed`. The loop's full read
  # carries the effective mechanism word: null on a standalone loop.
  test "GET tasks/{key}/request answers the round's sealed request, and a round not yet sealed is 404" do
    DevModelLane.ensure_enabled!(@account)
    tools = [{ "type" => "function", "function" => { "name" => "read_file", "parameters" => { "type" => "object" } } }]
    post loops_path, headers: auth("rq-1"), as: :json, params: {
      run: { approval_mode: "bypass", steps: [
        { model: { key: "seed", model: MODEL, prompt: "read it", tools: tools, instructions: "Be terse." } },
        { model: { key: "later", model: MODEL, prompt: "then this" } },
      ] },
    }
    assert_response :created
    loop_id = response.parsed_body.dig("run", "public_id")
    assert response.parsed_body.fetch("run").key?("prompt_mechanism")
    assert_nil response.parsed_body.dig("run", "prompt_mechanism"), "a standalone loop names no mechanism"
    agent_run = loop_record(loop_id)
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: @human))
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    seed = agent_run.agent_run_tasks.find_by!(node_key: "seed")
    assert_equal "running", seed.status, seed.error_key.inspect

    get "#{loops_path}/#{loop_id}/tasks/seed/request", headers: auth
    assert_response :success
    body = response.parsed_body
    assert_equal %w[entries request_options], body.fetch("request").keys
    assert_equal ModelRequests::InputSource.accepted_entry_payloads(seed.selected_model_invocation).as_json,
      body.dig("request", "entries")
    assert_equal seed.selected_model_invocation.request_options, body.dig("request", "request_options")
    assert_equal "Be terse.", body.dig("request", "request_options", "instructions")
    assert_equal ["read_file"], body.dig("request", "request_options", "tools").map { |t| t.dig("function", "name") }

    get "#{loops_path}/#{loop_id}/tasks/later/request", headers: auth
    assert_response :not_found
    assert_equal "request_not_sealed", response.parsed_body.dig("error", "code")

    get "#{loops_path}/#{loop_id}", headers: auth
    assert_response :success
    assert_nil response.parsed_body.dig("run", "prompt_mechanism")
  end

  test "the feed of a loop-backed loop refuses conversation_hosted" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    seam = create_run_backed_turn(conversation: conversation, acting_user: @human)

    get "#{loops_path}/#{seam.agent_run.public_id}/events", headers: auth

    assert_response :conflict
    assert_equal "conversation_hosted", response.parsed_body.dig("error", "code")
  end

  # The graph is never WRITTEN from outside (the refusal above), and it is readable whole: the
  # picture a person debugs with, an e2e journey cites, and a UI draws.
  test "the graph route serves nodes, edges and a mermaid picture of the whole run" do
    post loops_path, headers: auth("gr-1"), as: :json, params: {
      run: {
        approval_mode: "bypass",
        steps: [
          { parallel: [{ model: { key: "plan", model: MODEL, prompt: "plan it" } },
                       { model: { key: "side", model: MODEL, prompt: "side it" } }],
            until: "any" },
          { ask: { key: "gate", prompt: "?" } },
        ],
      },
    }
    assert_response :created
    loop_id = response.parsed_body.dig("run", "public_id")
    barrier = "s1-parallel-1"
    assert_equal %w[plan side s1-parallel-1 gate], response.parsed_body.dig("receipt", "accepted_task_keys"),
      "a racing barrier's minted key is in the receipt"
    assert_equal [{ "parallel" => %w[plan side], "key" => barrier }, "gate"],
      response.parsed_body.dig("receipt", "steps")

    get "#{loops_path}/#{loop_id}/graph", headers: auth
    assert_response :success
    body = response.parsed_body
    assert_equal %w[nodes edges mermaid], body.keys
    assert_equal ["plan", "side", barrier, "gate"], body.fetch("nodes").map { |node| node.fetch("key") }
    assert_equal({ "key" => barrier, "kind" => "join_task", "lifetime" => "conversation", "wake" => "auto", "status" => "waiting",
                   "visibility" => "hidden", "deliverable" => false, "input_from" => [], "result_from" => [],
                   "join" => { "until" => "any", "losers" => "cancel" } },
      body.fetch("nodes")[2], "a race draws as the barrier the kernel placed, in the WRITE words")
    assert_equal [["plan", barrier], ["side", barrier], [barrier, "gate"]],
      body.fetch("edges").map { |edge| [edge.fetch("from"), edge.fetch("to")] }
    assert_match(/\Aflowchart TD\n/, body.fetch("mermaid"))
    assert_includes body.fetch("mermaid"), "n0 --> n2"
    assert_includes body.fetch("mermaid"), "(any, cancel)"

    get "#{loops_path}/#{loop_id}", headers: auth
    gate = response.parsed_body.dig("run", "tasks").find { |task| task["key"] == "gate" }
    assert_equal [barrier], gate.fetch("after"), "the trace names what a task was authored after"
    assert_nil gate["depends_on"], "one spelling: the authored word is `after` on a read"
  end

  # THE PHASES PROJECTION: the plan is the receipts' step mirrors in write order, every kernel round
  # counts inside the phase it extends, and nothing new is stored to answer it. The route is
  # `phases`: `progress` is the executor plane's ephemeral feed, and the path string is pinned here
  # so no reader keeps the old word.
  test "the phases route renders the authored phases, the current one, and the spend" do
    post loops_path, headers: auth("pg-1"), as: :json, params: {
      run: { approval_mode: "bypass", steps: [
        { parallel: [{ tool: { key: "tests", name: "bash", input: { command: "t" } } },
                     { tool: { key: "lint", name: "bash", input: { command: "l" } } }] },
        { model: { key: "summary", model: MODEL, prompt: "sum it" } },
        { ask: { key: "review", prompt: "right?" } },
      ] },
    }
    assert_response :created
    loop_id = response.parsed_body.dig("run", "public_id")
    agent_run = loop_record(loop_id)
    agent_run.agent_run_tasks.where(node_key: %w[tests lint])
      .update_all(status: "completed", completed_at: Time.current)
    agent_run.agent_run_tasks.find_by!(node_key: "summary")
      .update_columns(status: "running", started_at: Time.current)

    get "#{loops_path}/#{loop_id}/phases", headers: auth
    assert_response :success
    body = response.parsed_body
    assert_equal %w[phases current background spend], body.keys
    assert_equal [
      { "label" => "tests · lint", "keys" => %w[tests lint], "done" => 2, "total" => 2, "status" => "completed" },
      { "label" => "summary", "keys" => ["summary"], "done" => 0, "total" => 1, "status" => "running" },
      { "label" => "review", "keys" => ["review"], "done" => 0, "total" => 1, "status" => "waiting" },
    ], body.fetch("phases")
    assert_equal 1, body.fetch("current")
    assert_equal [], body.fetch("background")
    assert_equal({ "input_tokens" => 0, "output_tokens" => 0, "cache_read_tokens" => 0, "cache_hit_rate" => nil,
                   "cost_amount" => nil, "cost_unit" => nil, "by_model" => {} }, body.fetch("spend"),
      "no receipt yet: nothing to split")

    get "#{loops_path}/#{SecureRandom.uuid}/phases", headers: auth
    assert_response :not_found
  end

  test "the graph route is scoped exactly as the trace: a stranger's loop is not found" do
    elsewhere = AgentRuns::Create.call(AgentRuns::Create::Command.new(
      workspace: workspaces(:personal), creating_user: users(:curator),
      steps: [{ "ask" => { "key" => "seed", "prompt" => "?" } }],
      billing_subject: nil, idempotency_key: nil, approval_mode: "bypass"
    )).agent_run

    get "/agent_api/v1/workspaces/#{workspaces(:personal).public_id}/runs/#{elsewhere.public_id}/graph",
      headers: auth
    assert_response :not_found
    get "/agent_api/v1/workspaces/#{workspaces(:personal).public_id}/runs/#{elsewhere.public_id}",
      headers: auth
    assert_response :not_found

    get "#{loops_path}/#{SecureRandom.uuid}/graph", headers: auth
    assert_response :not_found
  end
end
