require "support/daemon_run_helpers"
require "support/receipt_api"

class DaemonCreationRetryTest < Minitest::Test
  include RhoTest::DaemonRunHelpers

  def test_conflicting_retry_after_input_acceptance_preserves_the_entire_bound_policy
    api = RhoTest::ReceiptApi.new(lose_input_response: true, tools: NexusDoubles::KERNEL_CATALOG)
    daemon = connected(api)
    assert_equal "502", open(daemon, opening).first
    bind_policy(api)
    before = policy_entry(api)

    changes = [
      { "until" => { "command" => "make test", "attempts" => 20 } },
      { "until" => { "command" => "make other", "attempts" => 2 } },
      { "working_directory" => File.join(@root, "other") },
      { "environment" => { "root" => @root, "directories" => [File.join(@root, "other")] } },
      { "model" => "other/model" },
      { "code_mode" => false },
      { "subagent" => false },
      { "prompt" => "different work" },
    ]
    FileUtils.mkdir_p(File.join(@root, "other"))
    changes.each do |change|
      status, answer = open(daemon, opening.merge(change))
      assert_equal "409", status, "#{change.inspect}: #{answer.inspect}"
      assert_equal "idempotency_envelope_mismatch", answer.dig("error", "code")
      assert_equal before, policy_entry(api), "the full value, version and binding survive #{change.inspect}"
    end
    assert_equal 1, api.inputs.length
    assert_equal 1, api.conversation_creates.length
  end

  def test_replay_preserves_bound_notes_consumed_title_changed_preferences_and_environment
    api = RhoTest::ReceiptApi.new(lose_input_response: true)
    daemon = connected(api)
    body = opening.except("title")
    assert_equal "502", open(daemon, body).first
    bind_policy(api)
    hosted = daemon.context.member_plane { |client, *| client.workspace("ws-1").conversation("c-1") }
    policy = Rho::HostPolicy.new(store: -> { hosted.store_entries }, owner_public_id: RUNNER_IDENTITY.user_public_id, host_public_id: "c-1")
    assert policy.consume_title("cin-1")
    policy.change(model: "other/model", code_mode: false, subagent: false)
    environment = api.store_entries_of("c-1").find { |entry| entry.fetch("namespace") == "rho.environment" }
    api.patch_store_entry("c-1", namespace: environment.fetch("namespace"), key: environment.fetch("key"),
      value: environment.fetch("value").merge("root" => File.join(@root, "later")))
    before = JSON.parse(JSON.generate(api.store_entries_of("c-1")))

    status, answer = open(daemon, body.merge("live" => false, "stream" => false))

    assert_equal "201", status, answer.inspect
    assert_equal before, api.store_entries_of("c-1")
    assert_equal "cin-1", answer.dig("input", "public_id")
    row = daemon.host_followers.send(:store).find("c-1")
    assert_equal ["other/model", false, false], [row.model, row.code_mode, row.subagent]
    assert_equal policy.read.notes, row.notes
    assert_equal "al-1", row.notes.dig("rho.until", "run_public_id")
    assert_equal File.join(@root, "later"), answer.dig("environment", "root")
    assert_equal 1, api.inputs.length
  end

  def test_conflicts_before_run_binding_leave_the_original_recovery_proof_valid_without_cache
    api = RhoTest::ReceiptApi.new(lose_input_response: true, events: [])
    daemon = connected(api)
    assert_equal "502", open(daemon, opening).first
    before = policy_entry(api)
    assert_nil before.dig("value", "notes", "rho.until", "run_public_id")
    original_materialization(api)
    other = File.join(@root, "other").tap { |path| FileUtils.mkdir_p(path) }
    [
      { "until" => { "command" => "make test", "attempts" => 20 } },
      { "until" => { "command" => "make other", "attempts" => 2 } },
      { "working_directory" => other },
      { "environment" => { "root" => @root, "directories" => [other] } },
    ].each do |change|
      status, answer = open(daemon, opening.merge(change))
      assert_equal "409", status, answer.inspect
      assert_equal before, policy_entry(api)
    end

    cache = daemon.home.host_cache_path(RUNNER_IDENTITY.user_public_id)
    daemon.stop
    FileUtils.rm_f(cache)
    restarted = connected(api)
    gate = restarted.context.member_plane do |client, *|
      Rho::Until::Recovery.new(owner_public_id: RUNNER_IDENTITY.user_public_id, timeout_seconds: 30).call(
        workspace: client.workspace("ws-1"), run_public_id: "al-1", conversation_public_id: "c-1", advance: false)
    end

    refute_nil gate, "the original accepted check still proves the unbound policy after cache loss"
    assert_equal [2, "make test", @root, "al-1"], gate.to_h.values_at("attempts", "command", "directory", "run_public_id")
    expected = before.fetch("value")
    expected.fetch("notes").fetch("rho.until")["run_public_id"] = "al-1"
    assert_equal expected, policy_entry(api).fetch("value")
    assert_empty api.appends
  end

  def test_a_lost_conversation_response_already_binds_the_complete_intent
    api = RhoTest::ReceiptApi.new(lose_create_response: true)
    daemon = connected(api)
    assert_equal "502", open(daemon, opening).first
    assert_empty api.store_entries_of("c-1")
    assert_empty api.inputs

    status, answer = open(daemon, opening.merge("until" => { "command" => "make test", "attempts" => 20 }))
    assert_equal "409", status, answer.inspect
    assert_empty api.store_entries_of("c-1")
    assert_empty api.inputs

    status, answer = open(daemon, opening)
    assert_equal "201", status, answer.inspect
    assert_equal "c-1", answer.dig("conversation", "public_id")
    assert_equal 2, policy_entry(api).dig("value", "notes", "rho.until", "attempts")
    assert_equal 1, api.inputs.length
    assert_equal 1, api.conversation_creates.length
  end

  def test_interruption_after_policy_write_keeps_the_original_intent_without_an_input_receipt
    fail_once = true
    api = RhoTest::ReceiptApi.new(before_input: -> {
      if fail_once
        fail_once = false
        raise CybrosAgent::TransportError, "interrupted before input acceptance"
      end
    })
    daemon = connected(api)
    assert_equal "502", open(daemon, opening).first
    before = policy_entry(api)
    assert_empty api.inputs
    status, answer = open(daemon, opening.merge("prompt" => "changed before acceptance"))
    assert_equal "409", status, answer.inspect
    assert_equal before, policy_entry(api)
    assert_empty api.inputs
    status, answer = open(daemon, opening)
    assert_equal "201", status, answer.inspect
    assert_equal before, policy_entry(api)
    assert_equal 1, api.inputs.length
  end

  def test_promptless_creation_binds_preferences_and_cannot_become_a_prompted_creation
    api = RhoTest::ReceiptApi.new
    daemon = connected(api)
    body = opening.except("prompt", "until")
    assert_equal "201", open(daemon, body).first
    before = policy_entry(api)
    [{ "model" => "other/model" }, { "code_mode" => false }, { "prompt" => "first input" }].each do |change|
      status, answer = open(daemon, body.merge(change))
      assert_equal "409", status, answer.inspect
      assert_equal before, policy_entry(api)
    end
    assert_equal "201", open(daemon, body).first
    assert_empty api.inputs
    assert_equal before, policy_entry(api)
  end

  def test_object_key_order_is_irrelevant_but_environment_directory_order_is_part_of_the_intent
    api = RhoTest::ReceiptApi.new
    daemon = connected(api)
    directories = %w[first second].map { |name| File.join(@root, name).tap { |path| FileUtils.mkdir_p(path) } }
    body = opening.except("prompt", "until").merge("environment" => { "root" => @root, "directories" => directories })
    assert_equal "201", open(daemon, body).first
    before = policy_entry(api)
    reordered = body.to_a.reverse.to_h.merge("environment" => { "directories" => directories, "root" => @root })
    assert_equal "201", open(daemon, reordered).first
    status, answer = open(daemon, body.merge("environment" => { "root" => @root, "directories" => directories.reverse }))
    assert_equal "409", status, answer.inspect
    assert_equal before, policy_entry(api)
    assert_empty api.inputs
    assert_equal 1, api.conversation_creates.length
  end

  def test_overlapping_same_key_creations_share_policy_and_input_receipts
    entered = Queue.new
    release = Queue.new
    first = true
    api = RhoTest::ReceiptApi.new(before_input: -> {
      if first
        first = false
        entered << true
        release.pop
      end
    })
    daemon = connected(api)
    pending = Thread.new { open(daemon, opening) }
    Timeout.timeout(5) { entered.pop }
    before = policy_entry(api)
    status, answer = open(daemon, opening.merge("until" => { "command" => "make test", "attempts" => 20 }))
    assert_equal "409", status, answer.inspect
    assert_equal before, policy_entry(api)
    # The exact overlapping request completes the interrupted creation.
    status, answer = open(daemon, opening)
    assert_equal "201", status, answer.inspect
    release << true
    assert_equal "201", Timeout.timeout(5) { pending.value }.first
    assert_equal before, policy_entry(api)
    assert_equal 1, api.inputs.length
  ensure
    release << true if release
    pending&.join(5)
  end

  private

    def connected(api)
      now = Time.now
      daemon = member_ready(boot(config: catalog_config("kernel_tools" => []), realtime_factory: ->(*) { nil }, clock: -> { now },
        sleeper: ->(_) { now += Rho::Daemon::HostFollowers::MATERIALIZATION_WAIT }), api, identity: RUNNER_IDENTITY)
      # Exercise admission without background followers advancing this fake clock.
      daemon.context.define_singleton_method(:spawn) { |&_task| nil }
      daemon
    end

    def opening
      { "idempotency_key" => "creation-1", "title" => "Task", "prompt" => "fix it", "model" => "dev/mock-text",
        "environment" => { "root" => @root, "directories" => [] },
        "until" => { "command" => "make test", "attempts" => 2 } }
    end

    def policy_entry(api)
      entry = api.store_entries_of("c-1").find { |row| row.fetch("namespace") == Rho::HostPolicy::NAMESPACE }
      JSON.parse(JSON.generate(entry))
    end

    def bind_policy(api)
      value = policy_entry(api).fetch("value")
      notes = value.fetch("notes").merge("other" => { "keep" => [1, 2] })
      notes["rho.until"] = notes.fetch("rho.until").merge("run_public_id" => "al-1")
      api.patch_store_entry("c-1", namespace: Rho::HostPolicy::NAMESPACE, key: Rho::HostPolicy::KEY,
        value: value.merge("notes" => notes))
    end

    def original_materialization(api)
      # Build the proof from the accepted wire input, independently of the
      # policy document that a conflicting creation used to overwrite.
      tool = api.inputs.fetch(0).fetch("input").fetch("steps").filter_map { |step| step["tool"] }.fetch(0)
      check = { "key" => "check-1", "kind" => "tool_task", "lifetime" => "conversation", "wake" => "auto",
        "status" => "pending", "tool_name" => tool.fetch("name"), "tool_input" => tool.fetch("input"),
        "target" => { "executor_public_id" => tool.fetch("route").fetch("runner_executor_public_id") },
        "executor_context" => tool.fetch("executor_context") }
      hold = { "key" => "hold-1", "kind" => "await_task", "lifetime" => "conversation", "wake" => "auto", "status" => "pending" }
      turn = { "public_id" => "t-1", "position" => 0, "kind" => "direct_reply", "role" => "assistant",
        "status" => "running", "visibility" => "visible", "inherited" => false,
        "answering_user_public_id" => RUNNER_IDENTITY.user_public_id, "created_at" => "2026-09-30T00:00:00Z", "input_public_id" => "cin-1" }
      run = NexusDoubles::RUNNING_TRACE.merge("public_id" => "al-1", "tasks" => [check, hold],
        "turn" => { "public_id" => "t-1", "conversation_public_id" => "c-1", "status" => "running" })
      proof = {
        "/runs/al-1" => { "run" => run },
        "/runs/al-1/tasks/check-1" => { "task" => check },
        "/conversations/c-1/turns/t-1" => { "turn" => turn },
        "/conversations/c-1/inputs/cin-1/materialization" => { "materialization" => {
          "input_public_id" => "cin-1", "turn_public_id" => "t-1", "variant_public_id" => "v-1", "run_public_id" => "al-1" } },
      }
      original = api.method(:call)
      api.define_singleton_method(:call) do |path, **fields|
        body = proof[path.delete_prefix("/agent_api/v1/workspaces/ws-1")]
        if fields.fetch(:method, :get) == :get && body
          CybrosAgent::Response.new(status: 200, headers: {}, body: body)
        else
          original.call(path, **fields)
        end
      end
    end
end
