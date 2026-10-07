require "test_helper"
require_relative "../support/contract_clients"

class ApiRunContractPackTest < Minitest::Test
  include CybrosAgentTest::ContractClients

  # The single-task read on a round (runs.md): the pack's fixture
  # parses through the real client with its `request_bytes` intact.
  def test_the_task_detail_fixture_parses_through_the_real_client
    fixture = contract("runs.json").fetch("valid_task_detail_fixture")
    read = api_client(fixture).workspace("019f0000-0000-7000-8000-000000000101")
      .runs.run("019f0000-0000-7000-8000-000000000601").task("r1")

    assert_equal fixture.dig("task", "key"), read.task.key
    assert_equal fixture.dig("task", "request_bytes"), read.request_bytes
    assert_kind_of Integer, read.request_bytes
    assert_equal fixture.dig("task", "output"), read.output
    # The settled round's `instructions` read back: the pack's
    # fixture carries what a `raw` step was authored with.
    assert_equal "Be brief.", fixture.dig("task", "instructions"), "the pack's round was authored under raw"
    assert_equal fixture.dig("task", "instructions"), read.instructions
  end

  def test_a_delegation_result_is_a_turn_owned_task_with_its_original_report
    fixture = contract("runs.json").fetch("valid_delegation_task_detail_fixture")
    read = api_client(fixture).workspace("fixture-workspace").run("fixture-run")
      .task(fixture.dig("task", "key"))

    assert_equal "delegation_task", read.task.kind
    assert_equal "turn", read.task.lifetime
    assert_predicate read.task, :terminal?
    assert_equal "The child completed its report.", read.output
    assert_nil read.task.addressed_to
    assert_nil read.task.claimed_by
  end

  # A SETTLED TOOL CALL's read: the pack's fixture carries the
  # three channels and the UI's two fields, and each parses through the
  # real client onto its own member.
  def test_the_tool_task_detail_fixture_parses_through_the_real_client
    fixture = contract("runs.json").fetch("valid_tool_task_detail_fixture")
    read = api_client(fixture).workspace("019f0000-0000-7000-8000-000000000101")
      .runs.run("019f0000-0000-7000-8000-000000000601").task("r1t0")

    assert_equal "tool_task", read.task.kind
    assert_equal fixture.dig("task", "output"), read.output
    assert_equal "class Foo", read.output_preview, "the preview the settled call's feed item carries"
    assert_equal fixture.dig("task", "content"), read.content
    assert_equal fixture.dig("task", "structured_content"), read.structured_content
    assert_equal fixture.dig("task", "tool_input"), read.tool_input
    assert_equal "read x.rb", fixture.dig("task", "title"), "the pack's executor committed a header"
    assert_equal fixture.dig("task", "title"), read.title
    assert_equal fixture.dig("task", "metadata"), read.metadata
    assert_kind_of Hash, read.metadata
  end

  def test_tool_details_name_the_actual_declaring_round_and_run_approval_is_readable
    fixture = contract("runs.json").fetch("valid_tool_task_detail_fixture")
    declared = fixture.merge("task" => fixture.fetch("task").merge("declaring_task_key" => "r2"))
    read = api_client(declared).workspace("workspace").run("run").task("r1t0")
    assert_equal "r2", read.declaring_task_key
    assert_nil api_client(fixture).workspace("workspace").run("run").task("r1t0").declaring_task_key

    run_fixture = contract("runs.json").fetch("valid_request_run_fixture")
    run = api_client(run_fixture).workspace("workspace").run("run").fetch
    assert_equal run_fixture.dig("run", "approval_mode"), run.approval_mode
  end

  def test_a_hosted_run_exposes_the_turns_frozen_answerer
    fixture = contract("runs.json").fetch("valid_run_backed_fixture")
    run = api_client(fixture).workspace("workspace").run("run").fetch
    turn = fixture.fetch("run").fetch("turn")

    assert_predicate run.turn, :run_backed?
    assert_equal turn.fetch("answering_user_public_id"), run.turn.answering_user_public_id
  end

  # THE REQUEST HALF OF THE RELAY: a one-task run's terminal
  # task never claimed — what `wait_for_tool_result` answers behind an offline
  # runner — and the completed run whole: the seed is the deliverable, the
  # trace is that one tool task, no round ever ran.
  def test_the_request_run_fixtures_parse_through_the_real_client
    timed_out = contract("runs.json").fetch("valid_timed_out_task_detail_fixture")
    read = api_client(timed_out).workspace("019f0000-0000-7000-8000-000000000101")
      .runs.run("019f0000-0000-7000-8000-000000000601")
      .task(CybrosAgent::Api::RunContext::TOOL_CALL_TASK_KEY)
    assert_equal "relay", read.task.key
    assert_predicate read.task, :terminal?
    assert_predicate read.task, :failed?, "timed_out is adjudicable like a failure"
    assert_equal "tool_timeout", read.task.error.fetch("key")
    assert_nil read.task.claimed_by, "never claimed: the sweep settled it"
    assert_equal "runner", read.task.addressed_to.role
    assert_nil read.output

    run_fixture = contract("runs.json").fetch("valid_request_run_fixture")
    run = api_client(run_fixture).workspace("019f0000-0000-7000-8000-000000000101")
      .runs.fetch(run_fixture.dig("run", "public_id"))
    assert_predicate run, :terminal?
    assert_equal "relay", run.deliverable_task_key
    assert_equal ["tool_task"], run.tasks.map(&:kind), "one task, no round"
    assert_predicate run.deliverable, :tool_call?
    assert_equal "author", run.deliverable.approval.fetch("origin"), "granted by its origin"
    assert_equal run_fixture.dig("run", "default_runner", "executor_public_id"), run.default_runner.executor_public_id
  end

  # THE TWO SETTLED LOADS: a kernel-row load nobody
  # claimed, its `output` the row's body under the rung's title; an
  # announced load claimed by its runner, the body plus rho-runner's
  # base-directory line — one result grammar, parsed by the one reader.
  def test_the_skill_task_detail_fixtures_parse_through_the_real_client
    workspace = api_client(contract("runs.json").fetch("valid_skill_task_detail_fixture"))
      .workspace("019f0000-0000-7000-8000-000000000101")
    kernel_row = workspace.runs.run("019f0000-0000-7000-8000-000000000601").task("r2t0")
    assert_equal "skill", kernel_row.task.tool_name
    assert_predicate kernel_row.task, :terminal?
    assert_nil kernel_row.task.claimed_by, "the kernel ran it in-process"
    assert_equal({ "name" => "commit-style" }, kernel_row.tool_input)
    assert_equal "read workspace/skills/commit-style", kernel_row.title
    assert kernel_row.output.start_with?("# Commits")
    assert_equal [kernel_row.output], kernel_row.content.map { |block| block.fetch("text") }

    announced = api_client(contract("runs.json").fetch("valid_announced_skill_task_detail_fixture"))
      .workspace("019f0000-0000-7000-8000-000000000101")
      .runs.run("019f0000-0000-7000-8000-000000000601").task("r2t1")
    assert_equal "skill", announced.task.tool_name
    assert_equal "Skill", contract("runs.json").dig("valid_announced_skill_task_detail_fixture", "task", "tool_alias"),
      "the read carries the alias the model spelled; the typed task ignores the field"
    assert_equal "019f0000-0000-7000-8000-000000000301", announced.task.claimed_by.executor_public_id
    assert_equal({ "name" => "deploy-notes" }, announced.tool_input)
    assert_includes announced.output, "Files for this skill are under "
    assert_equal "skill_unknown", contract("memory_documents.json").fetch("skill_load_unknown_refusal"),
      "the one error word both sources answer, a tool result and never an HTTP code"
  end

  # A caller branches on the code alone — the runner's quiet refusals are
  # exactly such a caller — so the six executor refusals are FAMILY codes
  # whose status the pack fixes at 409.
  # THE PROGRESS FRAME, SETTLED: the raw `{frame}` an executor
  # posts is the pack's request fixture, and what goes out on the feed —
  # rendered by the kernel's own shape functions — parses through the
  # shipped opener into a `ProgressFrame`; an unknown type is carried. The
  # feed's vocabulary is listed ONCE, under conversations: the
  # door's two words lead it, the kernel's three follow, and the door's
  # own section names no list of its own.
  def test_the_progress_frame_fixtures_parse_through_the_real_openers
    inbox = contract("executor_inbox.json")
    progress = inbox.fetch("progress")
    assert_equal %w[task process], progress.fetch("key_kinds")
    refute progress.key?("frame_types"), "one list, under conversations"
    assert_equal %w[executor_progress process_output round_started step_started step_claimed],
      contract("conversations.json").fetch("progress_frame_types")
    assert_equal %w[frame], contract("conversations.json").fetch("progress_frame_envelope")
    assert_equal 202, progress.fetch("accepted_status")
    assert_kind_of Integer, progress.fetch("min_interval_ms")
    assert_equal %w[frame], progress.fetch("request_envelope")
    assert_equal %w[frame], progress.fetch("feed_envelope")
    %w[not_claimant not_bound frame_too_large invalid_frame].each do |code|
      assert_includes inbox.fetch("error_statuses").keys, code
    end

    request = inbox.fetch("progress_task_frame_request_fixture")
    assert_equal progress.fetch("task_key"), request.fetch("frame").keys.first(3)
    transport = CybrosAgentTest::FakeTransport.new([[progress.fetch("accepted_status"), {}, ""]])
    CybrosAgent::ExecutorClient.new(base_url: "http://example.test", credential: "fixture-executor-token",
      transport: transport).report_progress(request.fetch("frame"))
    assert_equal request, transport.requests.fetch(0).fetch(:body), "the raw request fixture is what leaves"

    task_frame = inbox.fetch("valid_progress_frame_fixture")
    frame = frames_through(
      api_client({}).workspace("019f0000-0000-7000-8000-000000000101")
        .runs.run(task_frame.dig("frame", "run_public_id")), [task_frame]
    ).fetch(0)
    assert_instance_of CybrosAgent::Api::ProgressFrame, frame
    assert_predicate frame, :executor_progress?
    assert_equal task_frame.dig("frame", "task_key"), frame.task_key
    assert_equal task_frame.dig("frame", "tool_name"), frame.tool_name
    assert_equal task_frame.dig("frame", "at"), frame.at
    assert_equal task_frame.dig("frame", "text_tail"), frame.text_tail
    assert_equal task_frame.fetch("frame").slice(*progress.fetch("task_payload")), frame.payload

    process_frame = inbox.fetch("valid_process_output_frame_fixture")
    conversation = api_client({}).workspace("019f0000-0000-7000-8000-000000000101")
      .conversation(process_frame.dig("frame", "conversation_public_id"))
    out = frames_through(conversation, [process_frame]).fetch(0)
    assert_predicate out, :process_output?
    assert_equal process_frame.dig("frame", "process_id"), out.process_id
    assert_equal process_frame.dig("frame", "lines"), out.lines
    assert_equal process_frame.fetch("frame").slice(*progress.fetch("process_payload")), out.payload

    unknown = frames_through(conversation, [inbox.fetch("unknown_progress_frame_type_fixture")]).fetch(0)
    assert_equal inbox.fetch("unknown_value_fixture"), unknown.type
  end

  # THE KERNEL'S OWN FRAMES: settled in the pack before their
  # producer lands, so the mapper that REQUIRED an executor — and would
  # have raised MalformedResponse on the first `round_started` — is caught
  # here, on fixtures. Only `step_claimed` names an executor.
  def test_the_kernel_progress_frame_fixtures_parse_through_the_real_opener_without_an_executor
    conversations = contract("conversations.json")
    fixtures = %w[round_started step_started step_claimed].map do |word|
      conversations.fetch("valid_#{word}_frame_fixture")
    end
    context = api_client({}).workspace("019f0000-0000-7000-8000-000000000101")
      .runs.run(fixtures.first.dig("frame", "run_public_id"))

    started, dispatched, claimed = frames_through(context, fixtures)
    assert_equal %w[round_started step_started step_claimed], [started, dispatched, claimed].map(&:type)
    assert_equal [true, false, false], [started, dispatched, claimed].map(&:round_started?)
    assert_equal [false, true, false], [started, dispatched, claimed].map(&:step_started?)
    assert_equal [false, false, true], [started, dispatched, claimed].map(&:step_claimed?)
    assert [started, dispatched, claimed].none?(&:executor_progress?)
    assert_nil started.executor_public_id, "a model attempt dialled names no executor"
    assert_equal "r3", started.task_key
    assert_equal({ "mainline" => true, "attempt" => 1, "model" => "dev/mock-text", "request_bytes" => 41_208 },
      started.payload)
    assert_nil dispatched.executor_public_id
    assert_equal %w[r4t0 read_file], [dispatched.task_key, dispatched.tool_name]
    assert_equal({ "status" => "dispatched" }, dispatched.payload)
    assert_equal fixtures.last.dig("frame", "executor_public_id"), claimed.executor_public_id
    assert_equal({}, claimed.payload, "the claimant is a stamp, not payload")
    [started, dispatched, claimed].each { |frame| assert_equal "2026-09-14T10:00:00.250Z", frame.at }
  end

  # THE THREAD's page: the pack's fixture through the real client
  # into typed rows, and back to the same bytes.
  def test_the_thread_page_fixture_parses_through_the_real_client
    fixture = contract("runs.json")
    page = fixture.fetch("valid_thread_page_fixture")
    transcript = api_client(page).workspace("019f0000-0000-7000-8000-000000000101")
      .runs.run("019f0000-0000-7000-8000-000000000201").transcript

    assert_equal fixture.fetch("transcript_envelope"), page.keys
    assert_equal fixture.fetch("thread_row_projection_required"),
      fixture.fetch("thread_row_projection") & fixture.fetch("thread_row_projection_required")
    transcript.each do |row|
      assert_instance_of CybrosAgent::Api::ThreadRow, row
      assert_equal fixture.fetch("thread_calls_projection"), row.calls.to_h.keys.map(&:to_s)
      row.calls.items.each { |call| assert_instance_of CybrosAgent::Api::ThreadCall, call }
    end
    assert_equal page.fetch("rounds"), transcript.map { |row| JSON.parse(JSON.generate(row.to_h)) }
    assert_equal ["r2t1"], transcript.to_a.fetch(1).branches
  end

  # HOW FAR ALONG is the `phases` read: the pack's fixture
  # parses through the real client under the renamed word.
  def test_the_phases_fixture_parses_through_the_real_client
    fixture = contract("runs.json")
    phases = api_client(fixture.fetch("valid_phases_fixture"))
      .workspace("019f0000-0000-7000-8000-000000000101")
      .runs.run("019f0000-0000-7000-8000-000000000601").phases

    assert_instance_of CybrosAgent::Api::RunPhases, phases
    assert_equal fixture.fetch("phases_envelope").sort, phases.to_h.keys.map(&:to_s).sort
    assert_equal fixture.fetch("valid_phases_fixture").fetch("phases").map { |phase| phase.fetch("label") },
      phases.phases.map(&:label)
    assert_includes fixture.fetch("phase_statuses"), phases.phases.first.status

    # THE BACKGROUND ROWS read back member for member: the running tip with
    # no stamp and the mailed one with its `result_delivered_at`, so a reader that
    # drops a member the presenter sends fails here rather than in a
    # consumer that never shows it.
    background = fixture.dig("valid_phases_fixture", "background")
    assert_equal fixture.fetch("background_projection").sort,
      CybrosAgent::Api::BackgroundTask.members.map(&:to_s).sort
    assert(background.any? { |row| row.key?("result_delivered_at") }, "the pack carries a mailed tip")
    assert(background.any? { |row| !row.key?("result_delivered_at") }, "and one still to settle")
    assert_equal background, phases.background.map { |task| task.to_h.transform_keys(&:to_s) }
    mailed = background.find { |row| row.key?("result_delivered_at") }
    assert_equal mailed.fetch("result_delivered_at"), phases.background.find { |task| task.key == mailed.fetch("key") }.result_delivered_at
  end

  # The picture is read through the same context the route serves, and a
  # node status this gem predates is carried, not refused.
  def test_the_graph_fixture_parses_and_an_unknown_node_status_is_carried
    fixture = contract("runs.json")
    valid = fixture.fetch("valid_graph_fixture")
    graph = api_client(valid).workspace("fixture-workspace").run("fixture-run").graph

    assert_equal %w[nodes edges mermaid], fixture.fetch("graph_envelope")
    assert_equal valid.fetch("nodes").map { |node| node.fetch("key") }, graph.nodes.map(&:key)
    assert_equal valid.fetch("nodes").map { |node| node.fetch("lifetime") }, graph.nodes.map(&:lifetime)
    assert_equal valid.fetch("nodes").map { |node| node.fetch("wake") }, graph.nodes.map(&:wake)
    assert_equal valid.fetch("nodes"), graph.nodes.map { |node| JSON.parse(JSON.generate(node.to_h)) },
      "material order and expansion ownership round-trip without adding absent members"
    assert_equal valid.fetch("edges"), graph.edges.map { |edge| JSON.parse(JSON.generate(edge.to_h)) },
      "nonstructural dependencies retain their explicit false flag"
    assert_equal valid.fetch("mermaid"), graph.mermaid
    assert_equal fixture.fetch("node_projection_required"), CybrosAgent::Api::GraphNode.members
      .map(&:to_s).first(fixture.fetch("node_projection_required").length)
    assert_includes fixture.fetch("node_statuses"), graph.nodes.first.status
    # The mainline is the kernel's mark, read on a round and absent elsewhere.
    assert_includes fixture.fetch("node_projection"), "mainline"
    assert_equal valid.fetch("nodes").map { |node| node["mainline"] }, graph.nodes.map(&:mainline)
    assert_predicate graph.nodes.first, :mainline?
    refute_predicate graph.nodes.find { |node| node.kind == "tool_task" }, :mainline?
    # The pack's call rests `needs_approval`: a real rest state
    # of a tool call, parsed as pre-start — nothing spent on it yet.
    held = graph.nodes.find { |node| node.status == "needs_approval" }
    refute_nil held, "the graph fixture carries a held call"
    assert_includes fixture.fetch("node_statuses"), held.status
    assert_includes CybrosAgent::Api::TASK_PRE_START_STATUSES, held.status
    assert_equal %w[origin decided_by decided_at], fixture.fetch("approval_projection")
    assert_includes fixture.fetch("task_verbs"), "approve"
    assert_includes fixture.fetch("task_verbs"), "deny"
    assert_includes fixture.fetch("attention_reasons"), "approval_required"

    unknown = valid.merge("nodes" => [fixture.fetch("unknown_node_status_fixture")], "edges" => [])
    carried = api_client(unknown).workspace("fixture-workspace").run("fixture-run").graph
    assert_equal "future_status", carried.nodes.first.status
  end

  # THE TWO SEALED-REQUEST READS: the variant's and the round's
  # fixtures are the sealed bytes as the presenter answers them — exactly
  # `entries` and `request_options`, verbatim — parsed through the real
  # turns and tasks contexts into the one Data.
  def test_the_two_sealed_request_fixtures_parse_through_the_real_contexts
    variant_fixture = contract("conversations.json").fetch("valid_request_fixture")
    sealed = api_client(variant_fixture).workspace("fixture-workspace").conversation("fixture-chat")
      .turns.request("fixture-turn", "fixture-variant")
    assert_instance_of CybrosAgent::Api::SealedRequest, sealed
    assert_equal variant_fixture.dig("request", "entries"), sealed.entries
    assert_equal variant_fixture.dig("request", "request_options"), sealed.request_options
    assert_equal %w[entries request_options], CybrosAgent::Api::SealedRequest.members.map(&:to_s)

    task_fixture = contract("runs.json").fetch("valid_task_request_fixture")
    round = api_client(task_fixture).workspace("fixture-workspace")
      .run_task(run_public_id: "fixture-run", task_key: "r1").request
    assert_equal task_fixture.dig("request", "entries"), round.entries
    assert_equal task_fixture.dig("request", "request_options"), round.request_options
    assert_includes contract("runs.json").fetch("prompt_mechanisms"), "default"
  end

  # THE TWO PLANES' RENDERED PROJECTIONS: the typed conversation carries exactly the Full
  # projection the presenter rendered (`runner` among it), the run's progress buckets are
  # the pack's, and the stamped, blocked and attached shapes parse with their optional
  # members on the real readers.
  def test_the_conversation_and_run_projections_match_the_rendered_pack
    conversations = contract("conversations.json")
    assert_equal (conversations.fetch("basic_projection") + conversations.fetch("full_projection_adds")).sort,
      CybrosAgent::Api::Conversation.members.map(&:to_s).sort
    assert_includes conversations.fetch("full_projection_adds"), "default_runner"
    conversation = api_client(conversations.fetch("valid_fixture"))
      .workspace("019f0000-0000-7000-8000-000000000101").conversations.fetch("019f0000-0000-7000-8000-000000000070")
    assert_nil conversation.default_runner, "unbound: the key is rendered null"

    stamped = conversations.dig("valid_stamped_input_fixture", "input")
    %w[sender_conversation_public_id blocked_reason].each do |key|
      assert_includes conversations.fetch("input_projection"), key
      assert stamped.key?(key), "the stamped, blocked row carries #{key}"
    end
    assert_includes conversations.fetch("input_projection"), "instructions"
    # THE SCHEDULED ROW: `deliver_at` by presence,
    # an ISO string the kernel holds.
    assert_includes conversations.fetch("input_projection"), "deliver_at"
    scheduled = conversations.dig("scheduled_input_fixture", "input")
    assert_kind_of String, scheduled.fetch("deliver_at")
    refute conversations.dig("valid_input_fixture", "input").key?("deliver_at"), "absent on an untimed row"
    # The inputs door's five service-authored refusals, at the family's 422.
    %w[deliver_at_ambiguous deliver_at_not_steerable deliver_at_in_past deliver_at_too_far attachments_not_steerable]
      .each { |code| assert_equal 422, conversations.fetch("error_statuses").fetch(code) }
    assert_includes conversations.fetch("turn_projection"), "sender_conversation_public_id"
    assert_includes conversations.fetch("variant_projection"), "attachments"
    attached = conversations.dig("valid_attached_variant_fixture", "variant")
    assert_equal 1, attached.fetch("attachments").length
    refute attached.key?("runner_effects"), "a direct reply carries no run key"
    # THE SEED'S WORDS: a reply
    # turn's variant names what opened it, by presence.
    assert_includes conversations.fetch("variant_projection"), "prompt_text"
    replied = conversations.dig("valid_turns_fixture", "turns", 0)
    assert_equal "direct_reply", replied.fetch("kind")
    assert_kind_of String, replied.dig("active_variant", "prompt_text")
    stamped = conversations.fetch("valid_stamped_turn_fixture")
    assert_equal "message", stamped.fetch("kind")
    refute stamped.fetch("active_variant", {}).key?("prompt_text"), "a message turn carries none"

    runs = contract("runs.json")
    run_fixture = runs.fetch("valid_request_run_fixture")
    run = api_client(run_fixture).workspace("019f0000-0000-7000-8000-000000000101")
      .runs.fetch(run_fixture.dig("run", "public_id"))
    assert_equal runs.fetch("task_progress_projection").sort,
      CybrosAgent::Api::RunProgress.members.map(&:to_s).sort, "one bucket per public status, plus the total"
    assert_equal 1, run.task_progress.completed
    assert_equal 1, run.task_progress.total
    assert_equal runs.fetch("phase_spend_projection").sort, runs.dig("valid_phases_fixture", "spend").keys.sort
  end
end
