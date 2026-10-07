require "test_helper"
require "test_helpers/agent_run_api_test_helper"

# The task-grained HTTP surface: steps in, tasks out — work is placed in written order, nobody
# outside the kernel writes an edge, and the graph is read whole on its own route; countdowns and
# ids never cross the wire.
class AgentAPI::V1::AgentRunsTest < ActionDispatch::IntegrationTest
  include AgentRunAPITestHelper

  test "create seeds the graph in written order and answers in task vocabulary only" do
    post loops_path, headers: auth("al-1"), as: :json, params: {
      run: {
        approval_mode: "bypass",
        steps: [
          { model: { key: "plan", model: MODEL, prompt: "plan it" } },
          { ask: { key: "done", prompt: "good?" } },
        ],
      },
    }

    assert_response :created
    body = response.parsed_body.fetch("run")
    assert_equal "pending", body["status"]
    assert_nil body["revision"], "the mutation counter is the engine's, not the trace's"
    assert_equal "done", body["deliverable_task_key"], "the envelope's end is the answer, nobody names one"
    assert_equal %w[plan done], body["tasks"].map { |t| t["key"] }
    plan, done = body["tasks"]
    assert_equal "waiting", plan["status"], "queued renders as waiting"
    assert_equal "model_task", plan["kind"]
    assert_nil plan["remaining_dependencies"], "countdowns never leak"
    assert_nil plan["waiting_on"], "a task with nothing ahead of it waits on nothing"
    assert_equal ["plan"], done["waiting_on"], "what a task waits for is a task fact"
    assert_equal ["plan"], done["after"], "written order placed the ask after the model step"
    assert_nil done["depends_on"], "one spelling on a read: `after`"
    receipt = response.parsed_body.fetch("receipt")
    assert_equal %w[plan done], receipt["accepted_task_keys"], "the receipt speaks task keys"
    assert_equal %w[plan done], receipt["steps"], "the receipt mirrors the request tree by key"
    assert_equal "done", receipt["deliverable_task_key"]
  end

  # The initial runner binding is written by the create door and read back through the model — the
  # trace does not render it. Unnamed is unbound: the kernel infers no runner, however many are
  # eligible; a name binds when it is a live eligible runner-kind row and is refused by name
  # otherwise.
  test "create binds the runner the creator names, and nothing when none is named" do
    steps = [{ model: { key: "seed", model: MODEL, prompt: "s" } }]
    assert_nil created_loop(steps).default_runner_executor_id, "no runner anywhere"

    runner = connect_runner(manager: users(:owner), registration_identifier: "wide-1",
      assignment_scope: :account_wide).executor_access_token.task_executor
    assert_nil created_loop(steps).default_runner_executor_id, "one eligible runner is not inferred"

    connection = connect_agent_session(
      steward: users(:owner), agent_identifier: users(:agent).agent_identifier
    )
    @token = BoundCredential.new(token: connection.access_token, secret: connection.access_secret)
    address = TaskExecutor.address_for(users(:agent))
    address.announce(tools: [{ "name" => "read_file", "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED }])
    assert_nil created_loop(steps).default_runner_executor_id,
      "an announced agent address is never a binding, and nothing is inferred"

    post loops_path, headers: auth(SecureRandom.uuid), as: :json, params: {
      run: { approval_mode: "bypass", steps: steps, default_runner_executor_public_id: runner.public_id },
    }
    assert_response :created
    named = AgentRun.find_by!(public_id: response.parsed_body.dig("run", "public_id"))
    assert_equal runner.id, named.default_runner_executor_id, "the runner the creator named"

    assert_no_difference -> { AgentRun.count } do
      post loops_path, headers: auth(SecureRandom.uuid), as: :json, params: {
        run: { approval_mode: "bypass", steps: steps, default_runner_executor_public_id: address.public_id },
      }
    end
    assert_response :unprocessable_entity
    assert_equal "runner_not_eligible", response.parsed_body.dig("error", "code")
  end

  # The digest carries the named runner: a retry naming another is the
  # family's envelope mismatch, never a silent rebinding.
  test "a create replayed under one key with a different runner is an envelope mismatch" do
    steps = [{ model: { key: "seed", model: MODEL, prompt: "s" } }]
    first = connect_runner(manager: users(:owner), registration_identifier: "wide-1",
      assignment_scope: :account_wide).executor_access_token.task_executor
    second = connect_runner(manager: users(:owner), registration_identifier: "wide-2",
      assignment_scope: :account_wide).executor_access_token.task_executor

    post loops_path, headers: auth("al-runner"), as: :json, params: {
      run: { approval_mode: "bypass", steps: steps, default_runner_executor_public_id: first.public_id },
    }
    assert_response :created

    post loops_path, headers: auth("al-runner"), as: :json, params: {
      run: { approval_mode: "bypass", steps: steps, default_runner_executor_public_id: second.public_id },
    }
    assert_response :conflict
    assert_equal "idempotency_envelope_mismatch", response.parsed_body.dig("error", "code")
    assert_equal 1, AgentRun.count
  end

  # The old grammar's words are refused BY NAME on the shell and inside a
  # step: an edge is the kernel's, and a client that wrote one must be
  # told so rather than have the word silently dropped.
  test "the shell and the tree refuse the edge words by name" do
    seed = { model: { key: "seed", model: MODEL, prompt: "s" } }
    { "tasks" => [seed], "deliverable" => "seed", "tools" => [], "compaction_policy" => {} }
      .each do |word, value|
      post loops_path, headers: auth(SecureRandom.uuid), as: :json, params: {
        run: { approval_mode: "bypass", steps: [seed], word => value },
      }
      assert_response :unprocessable_entity, word
      assert_equal "edge_authoring_refused", response.parsed_body.dig("error", "code")
      assert_equal "run.#{word}", response.parsed_body.dig("error", "path")
    end

    post loops_path, headers: auth(SecureRandom.uuid), as: :json, params: {
      run: { approval_mode: "bypass", steps: [{ model: { key: "seed", model: MODEL, prompt: "s", depends_on: ["x"] } }] },
    }
    assert_response :unprocessable_entity
    error = response.parsed_body.fetch("error")
    assert_equal "invalid_steps", error["code"]
    assert_equal [{ "code" => "edge_authoring_refused", "path" => "steps[0].model.depends_on" }],
      error["steps"]
    assert_equal 0, AgentRun.where(workspace_id: @workspace.id).count, "no loop was born refused"
  end

  test "raw graph vocabulary is refused loudly" do
    post loops_path, headers: auth("al-2"), as: :json, params: {
      run: { approval_mode: "bypass", nodes: [{}], edges: [] },
    }

    assert_response :unprocessable_entity
    assert_equal "graph_authoring_not_available",
      response.parsed_body.dig("error", "code")
  end

  test "the append door carries the CAS and the receipt over the wire" do
    loop_id = create_loop!
    append = { steps: [{ ask: { key: "extra", prompt: "?" } }], expected_revision: 1 }

    post "#{loops_path}/#{loop_id}/tasks", headers: auth("ap-1"), as: :json,
      params: append
    assert_response :created
    token = response.parsed_body.dig("receipt", "resolution_tokens", "extra")
    assert_not_nil token

    post "#{loops_path}/#{loop_id}/tasks", headers: auth("ap-1"), as: :json,
      params: append
    assert_response :success
    assert response.parsed_body.dig("receipt", "replayed")
    assert_equal token,
      response.parsed_body.dig("receipt", "resolution_tokens", "extra"),
      "the replay answers the ORIGINAL receipt, token included"

    post "#{loops_path}/#{loop_id}/tasks", headers: auth("ap-2"), as: :json,
      params: { steps: [{ ask: { key: "late", prompt: "?" } }], expected_revision: 1 }
    assert_response :conflict
    assert_equal "stale_revision", response.parsed_body.dig("error", "code")
    assert_equal 2, response.parsed_body.dig("error", "current_revision")

    post "#{loops_path}/#{loop_id}/tasks", headers: auth("ap-3"), as: :json,
      params: { tasks: [{ key: "late", kind: "await_task" }] }
    assert_response :unprocessable_entity
    assert_equal "edge_authoring_refused", response.parsed_body.dig("error", "code")
    assert_equal "tasks", response.parsed_body.dig("error", "path")
  end


  test "delivery refuses fresh turn work as a conflict but replays its earlier append receipt" do
    agent_run = loop_record(create_loop!)
    path = "#{loops_path}/#{agent_run.public_id}/tasks"
    envelope = { steps: [{ ask: { key: "owned", prompt: "?", lifetime: "turn" } }] }
    post path, headers: auth("owned-append"), as: :json, params: envelope
    assert_response :created
    receipt = response.parsed_body.fetch("receipt")
    node = agent_run.agent_run_tasks.find_by!(node_key: "owned")
    node.update!(status: "dispatched", started_at: Time.current, await_started_at: Time.current)
    node.update!(status: "failed", completed_at: Time.current, error_key: "ask_timeout")
    agent_run.update!(status: "running", delivered_at: Time.current)

    assert_no_difference -> { agent_run.agent_run_tasks.count } do
      post path, headers: auth("late-owned"), as: :json,
        params: { steps: [{ ask: { key: "late", prompt: "?", lifetime: "turn" } }] }
    end
    assert_response :conflict
    assert_equal "turn_already_delivered", response.parsed_body.dig("error", "code")

    post path, headers: auth("owned-append"), as: :json, params: envelope
    assert_response :created
    assert_equal receipt.merge("replayed" => true), response.parsed_body.fetch("receipt")

    post "#{path}/owned/retry", headers: auth
    assert_response :conflict
    assert_equal "turn_already_delivered", response.parsed_body.dig("error", "code")
    assert_equal "failed", node.reload.status
    assert_equal 0, node.execution_generation
  end

  # The two door-level refusals a tip can raise, unpositioned: a model step against a mainline still
  # talking, and an append past a deliverable whose failure nobody has adjudicated.
  test "a model step on a live mainline is tip_live, and an ask-only envelope hangs below it" do
    loop_id = create_loop!
    agent_run = loop_record(loop_id)
    agent_run.agent_run_tasks.sole.update_columns(status: "running", started_at: Time.current)
    agent_run.update!(status: "running", started_at: Time.current)

    post "#{loops_path}/#{loop_id}/tasks", headers: auth(SecureRandom.uuid), as: :json,
      params: { steps: [{ model: { key: "more", model: MODEL, prompt: "go on" } }] }
    assert_response :conflict
    assert_equal "tip_live", response.parsed_body.dig("error", "code")

    post "#{loops_path}/#{loop_id}/tasks", headers: auth(SecureRandom.uuid), as: :json,
      params: { steps: [{ ask: { key: "check", prompt: "done?" } }] }
    assert_response :created
    assert_equal ["check"], response.parsed_body.dig("receipt", "accepted_task_keys")
    assert_equal "check", response.parsed_body.dig("receipt", "deliverable_task_key"),
      "the check hangs below the live round and becomes the answer"
  end

  test "an append past an unresolved failure is tip_unresolved" do
    loop_id = create_loop!
    agent_run = loop_record(loop_id)
    agent_run.agent_run_tasks.sole.update!(status: "failed", completed_at: Time.current,
      error_key: "provider_http_error")
    agent_run.update!(status: "needs_attention", attention_reason: "halt_failure",
      started_at: Time.current)

    post "#{loops_path}/#{loop_id}/tasks", headers: auth(SecureRandom.uuid), as: :json,
      params: { steps: [{ model: { key: "more", model: MODEL, prompt: "go on" } }] }

    assert_response :conflict
    assert_equal "tip_unresolved", response.parsed_body.dig("error", "code")
  end

  test "compile failures answer positionally" do
    post loops_path, headers: auth("al-3"), as: :json, params: {
      run: { approval_mode: "bypass", steps: [{ model: { key: "bad.key", model: MODEL, prompt: "p" } }] },
    }

    assert_response :unprocessable_entity
    error = response.parsed_body.fetch("error")
    assert_equal "invalid_steps", error["code"]
    assert_equal "steps[0].key", error.dig("steps", 0, "path")

    post loops_path, headers: auth("al-4"), as: :json, params: { run: { approval_mode: "bypass", steps: [] } }
    assert_response :unprocessable_entity
    assert_equal "steps_required", response.parsed_body.dig("error", "code")
  end

  test "a delegated compaction on a Human's loop is refused positionally at the door" do
    post loops_path, headers: auth("al-5"), as: :json, params: {
      run: { approval_mode: "bypass", steps: [{ model: { key: "r1", model: MODEL, prompt: "p",
                                       compaction: { mode: "delegate", tool_name: "my_compactor" } } }] },
    }

    assert_response :unprocessable_entity
    error = response.parsed_body.fetch("error")
    assert_equal "invalid_steps", error["code"]
    assert_equal [{ "code" => "delegate_requires_agent", "path" => "steps[0].compaction" }],
      error["steps"]
  end

  test "the append door is a WRITE: an archived workspace refuses it" do
    loop_id = create_loop!
    @workspace.update_column(:state, "archived")

    post "#{loops_path}/#{loop_id}/tasks", headers: auth("wg-1"), as: :json,
      params: { steps: [{ ask: { key: "late", prompt: "?" } }] }

    assert_response :forbidden
    assert_equal "not_authorized", response.parsed_body.dig("error", "code")
  ensure
    @workspace.update_column(:state, "active")
  end

  test "a retried create replays over the wire and an overlong key is a 400" do
    payload = { run: { approval_mode: "bypass", steps: [{ model: { key: "seed", model: MODEL, prompt: "s" } }] } }
    post loops_path, headers: auth("cr-1"), as: :json, params: payload
    assert_response :created
    original = response.parsed_body.dig("run", "public_id")

    post loops_path, headers: auth("cr-1"), as: :json, params: payload
    assert_response :success
    assert response.parsed_body["replayed"]
    assert_equal original, response.parsed_body.dig("run", "public_id")

    post loops_path, headers: auth("x" * 40), as: :json, params: payload
    assert_response :bad_request
  end

  test "a replayed create recovers the seed receipt and its answer token after later appends" do
    payload = { run: {
      approval_mode: "bypass", steps: [{ ask: { key: "gate", prompt: "Continue?" } }],
    } }
    post loops_path, headers: auth("recover-seed"), as: :json, params: payload
    assert_response :created
    loop_id = response.parsed_body.dig("run", "public_id")
    original_receipt = response.parsed_body.fetch("receipt")

    post "#{loops_path}/#{loop_id}/tasks", headers: auth("later-work"), as: :json,
      params: { steps: [{ ask: { key: "later", prompt: "Anything else?" } }] }
    assert_response :created

    assert_no_difference -> { AgentRun.count } do
      post loops_path, headers: auth("recover-seed"), as: :json, params: payload
    end
    assert_response :success
    assert_equal original_receipt, response.parsed_body["receipt"],
      "a lost create response must recover its own receipt, not the later append's"
    recovered_token = response.parsed_body.dig("receipt", "resolution_tokens", "gate")

    post "#{loops_path}/#{loop_id}/start", headers: auth
    assert_response :success
    AgentRuns::ScheduleReady.call(agent_run_id: loop_record(loop_id).id)

    post "#{loops_path}/#{loop_id}/tasks/gate/resolution", headers: auth, as: :json,
      params: { resolution_token: recovered_token, content: "Continue" }
    assert_response :success
    get "#{loops_path}/#{loop_id}/tasks/gate", headers: auth
    assert_response :success
    assert_equal "completed", response.parsed_body.dig("task", "status")
  end

  test "create replay expires with the seed receipt even when building takes time" do
    payload = { run: {
      approval_mode: "bypass", steps: [{ ask: { key: "gate", prompt: "Continue?" } }],
    } }
    started_at = Time.current.change(usec: 0)
    append = AgentRuns::Tasks::Append.method(:call)
    delayed_append = lambda do |command|
      result = append.call(command)
      travel 1.minute
      result
    end

    travel_to started_at do
      AgentRuns::Tasks::Append.stub(:call, delayed_append) do
        post loops_path, headers: auth("seed-window"), as: :json, params: payload
      end
      assert_response :created
      original = response.parsed_body.dig("run", "public_id")

      travel_to started_at + AgentRunCreateReceipt::RETENTION
      assert_no_difference -> { AgentRun.count } do
        post loops_path, headers: auth("seed-window"), as: :json, params: payload
      end
      assert_response :success
      assert_equal original, response.parsed_body.dig("run", "public_id")

      travel 1.second
      assert_difference -> { AgentRun.count } do
        post loops_path, headers: auth("seed-window"), as: :json, params: payload
      end
      assert_response :created
      assert_not_equal original, response.parsed_body.dig("run", "public_id")
    end
  end

  test "the trace never carries the resolution token — it is the creator's receipt fact" do
    loop_id = create_loop!
    post "#{loops_path}/#{loop_id}/tasks", headers: auth("tk-1"), as: :json,
      params: { steps: [{ ask: { key: "gate", prompt: "?" } }] }
    assert_response :created
    assert response.parsed_body.dig("receipt", "resolution_tokens", "gate").present?

    get "#{loops_path}/#{loop_id}", headers: auth
    gate = response.parsed_body.dig("run", "tasks").find { |t| t["key"] == "gate" }
    assert_nil gate["resolution_token"],
      "a bearer capability never renders to browse-only readers"
  end

  # THE REQUEST HALF OF THE RELAY over the wire: a member creates a ONE-TASK loop — a single `tool`
  # step under `raw`, the runner named — and STARTS it; the runner claims and commits through its
  # own doors; the loop completes on the settle, the answer is the task read. No round, no model, no
  # receipt: the trace is the one tool task, and a second start is `not_startable` (a replayed
  # create's "already started").
  test "a tool-only seed under raw is a request: created, started, committed, and the loop completes" do
    post loops_path, headers: auth(SecureRandom.uuid), as: :json, params: {
      run: { approval_mode: "bypass", prompt_mechanism: "raw",
                    default_runner_executor_public_id: suite_runner.public_id,
                    steps: [{ tool: { key: "relay", name: "read_file", route: { kind: "runner" }, input: { path: "note.txt" }, timeout_ms: 5000 } }] },
    }
    assert_response :created
    body = response.parsed_body.fetch("run")
    loop_id = body.fetch("public_id")
    assert_equal "pending", body.fetch("status"), "created, not started"
    assert_equal "relay", body.fetch("deliverable_task_key"), "the one step is the answer"
    assert_equal [%w[relay tool_task waiting]],
      body.fetch("tasks").map { |task| task.values_at("key", "kind", "status") }

    post "#{loops_path}/#{loop_id}/start", headers: auth
    assert_response :success
    assert_equal "running", response.parsed_body.dig("run", "status")
    post "#{loops_path}/#{loop_id}/start", headers: auth
    assert_response :conflict
    assert_equal "not_startable", response.parsed_body.dig("error", "code")

    agent_run = loop_record(loop_id)
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    get "#{loops_path}/#{loop_id}/tasks/relay", headers: auth
    assert_response :success
    assert_equal "dispatched", response.parsed_body.dig("task", "status")
    assert_equal suite_runner.public_id, response.parsed_body.dig("task", "addressed_to", "executor_public_id")
    assert_not response.parsed_body.fetch("task").key?("claimed_by"), "nobody has claimed it"

    claim = Executors::Claim.call(Executors::Claim::Command.new(
      agent_run: agent_run, task_key: "relay", executor: suite_runner
    ))
    assert_predicate claim, :accepted?
    committed = Executors::Commit.call(Executors::Commit::Command.new(
      agent_run: agent_run, task_key: "relay", executor: suite_runner, claim_token: claim.value.claim_token,
      content: "note: hello", structured_content: nil, result_type: nil, outcome: "completed",
      is_error: false, title: "read note.txt", metadata: { "checkpoint" => "c1" }
    ))
    assert_predicate committed, :applied?
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)

    get "#{loops_path}/#{loop_id}", headers: auth
    assert_response :success
    body = response.parsed_body.fetch("run")
    assert_equal "completed", body.fetch("status"), "quiescence completed the loop on the settle"
    assert_equal ["tool_task"], body.fetch("tasks").map { |task| task.fetch("kind") }, "no round ever ran"
    get "#{loops_path}/#{loop_id}/tasks/relay", headers: auth
    detail = response.parsed_body.fetch("task")
    assert_equal "completed", detail.fetch("status")
    assert_equal "note: hello", detail.fetch("output")
    assert_equal "read note.txt", detail.fetch("title")
    assert_equal({ "checkpoint" => "c1" }, detail.fetch("metadata"))
    assert_equal suite_runner.public_id, detail.dig("claimed_by", "executor_public_id")
  end

  test "a kind we do not carry yet refuses differently from a shape nobody takes" do
    loop_id = create_await_loop!
    token = response.parsed_body.dig("receipt", "resolution_tokens", "gate")
    agent_run = loop_record(loop_id)
    post "#{loops_path}/#{loop_id}/start", headers: auth
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)

    post "#{loops_path}/#{loop_id}/tasks/gate/resolution", headers: auth, as: :json,
      params: { resolution_token: token,
                content: [{ "type" => "image", "upload_public_id" => "x" }] }
    assert_response :unprocessable_entity
    assert_equal "unsupported_content_kind", response.parsed_body.dig("error", "code")

    post "#{loops_path}/#{loop_id}/tasks/gate/resolution", headers: auth, as: :json,
      params: { resolution_token: token, content: [{ "text" => "no type" }] }
    assert_response :unprocessable_entity
    assert_equal "invalid_content", response.parsed_body.dig("error", "code")

    post "#{loops_path}/#{loop_id}/tasks/gate/resolution", headers: auth, as: :json,
      params: { resolution_token: token, content: "fine", result_type: "input_required" }
    assert_response :unprocessable_entity
    assert_equal "invalid_result_type", response.parsed_body.dig("error", "code"),
      "MRTR is not implemented; accepting its result type would be a lie"
  end

  # The standalone create shell: one of the three mechanism words, one of the three approval words
  # and an optional rule list; NOTHING IS DEFAULTED — nil is refused by name — and a word outside
  # either vocabulary is refused as invalid.
  test "create admits the shell, freezes the three approval words, and refuses nil and the malformed by name" do
    seed = { model: { key: "seed", model: MODEL, prompt: "s" } }
    rules = [{ tool: "bash", path: "command", match: "*rm -rf /*", verdict: "deny", reason: "no" }]
    post loops_path, headers: auth("sh-1"), as: :json, params: {
      run: { steps: [seed], prompt_mechanism: "raw", approval_mode: "bypass", approval_rules: rules },
    }
    assert_response :created
    born = AgentRun.find_by!(public_id: response.parsed_body.dig("run", "public_id"))
    assert_equal "bypass", born.approval_mode
    assert_equal rules.map { |rule| rule.transform_keys(&:to_s) }, born.approval_rules, "the rule list is frozen on the row"

    %w[ask rules].each do |word|
      post loops_path, headers: auth(SecureRandom.uuid), as: :json, params: {
        run: { steps: [seed], approval_mode: word },
      }
      assert_response :created, word
      assert_equal word, AgentRun.find_by!(public_id: response.parsed_body.dig("run", "public_id")).approval_mode
    end

    post loops_path, headers: auth(SecureRandom.uuid), as: :json, params: { run: { steps: [seed] } }
    assert_response :unprocessable_entity
    assert_equal "invalid_approval_mode", response.parsed_body.dig("error", "code"), "nil is not bypass"

    post loops_path, headers: auth(SecureRandom.uuid), as: :json, params: {
      run: { steps: [seed], approval_mode: "telepathy" },
    }
    assert_response :unprocessable_entity
    assert_equal "invalid_approval_mode", response.parsed_body.dig("error", "code")

    post loops_path, headers: auth(SecureRandom.uuid), as: :json, params: {
      run: { steps: [seed], approval_mode: "rules", approval_rules: [{ tool: "bash", verdict: "never" }] },
    }
    assert_response :unprocessable_entity
    assert_equal "invalid_approval_rules", response.parsed_body.dig("error", "code")

    # THE ASSEMBLED WORDS: `default` compiles the seed at create — the creator's slots (none written
    # for this Human), the room's memory (none), the words — and seals it as the seed step's input
    # body; `assembly` needs the creator's own template, and a Human creator has none.
    post loops_path, headers: auth(SecureRandom.uuid), as: :json, params: {
      run: { steps: [seed], approval_mode: "bypass", prompt_mechanism: "default" },
    }
    assert_response :created
    compiled = AgentRun.find_by!(public_id: response.parsed_body.dig("run", "public_id"))
    assert_equal "default", compiled.prompt_mechanism
    assert_equal "default", response.parsed_body.dig("run", "prompt_mechanism")
    assert_equal [["user", "s"]],
      compiled.agent_run_tasks.sole.input_value.map { |message| [message.role, message.parts.map(&:text).join] },
      "the seed body is the compiled request, the words its input block"

    post loops_path, headers: auth(SecureRandom.uuid), as: :json, params: {
      run: { steps: [seed], approval_mode: "bypass", prompt_mechanism: "assembly" },
    }
    assert_response :unprocessable_entity
    assert_equal "prompt_template_missing", response.parsed_body.dig("error", "code")

    post loops_path, headers: auth(SecureRandom.uuid), as: :json, params: {
      run: { steps: [{ model: { key: "seed", model: MODEL, prompt: "s", instructions: "be terse" } }],
                    approval_mode: "bypass", prompt_mechanism: "default" },
    }
    assert_response :unprocessable_entity
    assert_equal "invalid_steps", response.parsed_body.dig("error", "code")
    assert_equal [{ "code" => "instructions_raw_only", "path" => "steps[0].instructions" }],
      response.parsed_body.dig("error", "steps"), "the raw seed's system field is refused by name under default"

    post loops_path, headers: auth(SecureRandom.uuid), as: :json, params: {
      run: { approval_mode: "bypass", steps: [seed], prompt_mechanism: "telepathy" },
    }
    assert_response :unprocessable_entity
    assert_equal "invalid_prompt_mechanism", response.parsed_body.dig("error", "code")
    assert_equal 4, AgentRun.where(workspace_id: @workspace.id).count, "no loop was born refused"
  end

  # A scalar where the typed root should be is a value Strong Parameters filters out, and a filtered
  # value behaves as omitted: `params.expect` refuses the missing root as the family's 400, never an
  # empty envelope that fails later as 422.
  test "a scalar agent_run root is 400 parameter_missing" do
    post loops_path, headers: auth(SecureRandom.uuid), as: :json, params: { agent_run: "steps" }

    assert_response :bad_request
    assert_equal "parameter_missing", response.parsed_body.dig("error", "code")
  end
end
