require "test_helper"
require "cgi/escape"
require "fileutils"
require "json"
require "securerandom"
require "time"
require "tmpdir"
require "support/actor_provisioning"
require "support/executor_process"
require "support/peer_program"
require "support/runner_grant"
require "support/secret_hygiene"
require "support/steward_session"

# A saved job executes through the deployed scheduler, child conversation and
# ordinary runner. The main conversation is held on a public ask rendezvous;
# its busy state must not prevent the child from reading a real project file.
# The result then returns through ordinary child mail, with durable provenance.
class SchedulesTest < Minitest::Test
  MODEL = "dev/mock-text".freeze
  POLL = 1
  TIMEOUT = 120

  def setup
    @base_url = E2E.base_url
    steward = E2E::ActorProvisioning.world(@base_url).rho_steward
    actor = E2E::StewardSession.actor(base_url: @base_url, human: steward)
    @home = Dir.mktmpdir("scheduled-jobs-e2e")
    @project = File.realpath(Dir.mktmpdir("scheduled-jobs-project"))
    @job_doors = {}
    @peer = E2E::PeerProgram.pair(base_url: @base_url, actor: actor, name: "schedules")
    device = CybrosAgent::DeviceFlow::Client.new(base_url: @base_url, sleeper: ->(_seconds) { sleep 0.2 })
    E2E::DeviceAuthorizationBudget.consume
    authorization = device.request_runner_authorization(
      registration_identifier: "e2e-schedules-runner-#{SecureRandom.hex(4)}", runner_display_name: "Scheduled work environment")
    E2E::RunnerGrant.visit_connection(actor: actor, authorization: authorization)
    E2E::RunnerGrant.connect_in_browser(actor: actor, authorization: authorization)
    credentials = device.await_credentials(authorization)
    @runner = E2E::ExecutorProcess.new(base_url: @base_url, home: @home,
      credential: credentials.executor_access_token, world: @project, environment: @project).start
    E2E.enable_dev_lane!
    E2E.hosts.start
    @peer.client.profile.declare_configuration(tool_definitions: [],
      kernel_tools: %w[nexus.human.ask nexus.conversation.send nexus.schedules.read nexus.schedules.manage],
      runner_executor_public_ids: [@runner.executor_public_id], runner_tool_names: ["read"],
      default_model: MODEL, approval_mode: "bypass", approval_rules: nil, prompt_mechanism: "default",
      compaction_policy: { "mode" => "off" },
      prompt_documents: { "system_prompt" => { "content" => "Conversation kind: {{conversation_kind}}.", "role" => "developer" } })
    @workspace = @peer.client.workspace(@peer.client.workspaces.create(
      name: "Scheduled work", idempotency_key: SecureRandom.uuid).workspace.public_id)
  end

  def teardown
    unless passed?
      [@runner&.log_path].compact.each do |path|
        warn E2E::SecretHygiene.redact(File.read(path, encoding: Encoding::UTF_8)) if File.file?(path)
      end
    end
    @job_doors&.each do |id, door|
      door.cancel(id)
    rescue CybrosAgent::Error => error
      warn "Could not cancel scheduled job #{id}: #{error.message}"
    end
    @held_loop&.stop(force: true) if @held_loop && @held_loop.fetch.status == "running"
  ensure
    @runner&.stop
    [@home, @project].compact.each { |path| FileUtils.remove_entry(path) if File.directory?(path) }
  end

  def test_a_model_created_once_schedule_keeps_its_snapshot_across_submitter_exit_and_kernel_downtime
    marker = "offline-schedule-#{SecureRandom.hex(10)}"
    File.write(File.join(@project, "offline-schedule.txt"), marker)
    arguments = { "action" => "create", "prompt" => script("read", { "path" => "offline-schedule.txt" }, "report the scheduled result"),
      "rule" => { "kind" => "once", "run_at" => (Time.now + 3_600).utc.iso8601 } }
    chat, source = open_conversation(script("manage_schedule", arguments, "job saved"))
    await("the model-created schedule") do
      row = source.fetch
      row if row.status == "completed"
    end
    jobs = chat.schedules
    schedule = jobs.list.items.fetch(0)
    @job_doors[schedule.public_id] = jobs
    assert_equal source.run_public_id, schedule.source_run_public_id
    paused = jobs.pause(schedule.public_id)
    assert_equal "paused", paused.status
    assert_nil paused.next_run_at
    assert_empty jobs.executions(schedule.public_id).items
    # A later application configuration does not retarget work that the
    # clock already owns. Keep dispatch paused until that change is committed.
    @peer.client.profile.declare_configuration(tool_definitions: [], kernel_tools: [], runner_tool_names: [],
      default_model: MODEL, approval_mode: "bypass", approval_rules: nil, prompt_mechanism: "default",
      compaction_policy: { "mode" => "off" })
    E2E.hosts.stop
    due_rule = { "kind" => "once", "run_at" => (Time.now + 10).utc.iso8601 }
    revised = jobs.update(schedule.public_id, expected_lock_version: paused.lock_version, rule: due_rule)
    assert_equal "paused", revised.status
    assert_nil revised.next_run_at
    assert_empty jobs.executions(schedule.public_id).items
    resumed = jobs.resume(schedule.public_id)
    assert_equal "active", resumed.status
    assert_equal Time.iso8601(due_rule.fetch("run_at")), Time.iso8601(resumed.next_run_at)
    await("the saved occurrence to become due while kernel workers are stopped") do
      Time.now >= Time.iso8601(due_rule.fetch("run_at"))
    end
    assert_empty jobs.executions(schedule.public_id).items,
      "reading an overdue schedule does not dispatch it"
    assert_equal "active", jobs.fetch(schedule.public_id).status
    E2E.hosts.start
    execution, turn = await("the scheduled child's final reply without an application") do
      row = jobs.executions(schedule.public_id).items.first
      flunk "scheduled child failed: #{row.to_h.inspect}" if row && %w[failed canceled].include?(row.status)
      if row&.status == "completed"
        # The Run completes before its Turn projection; observe that exact reply
        # within the same deadline before reading its final content.
        reply = @workspace.conversation(row.child_conversation_public_id).turns.fetch(row.turn_public_id)
        [row, reply] if reply.status == "completed"
      end
    end
    assert_equal Time.iso8601(due_rule.fetch("run_at")), Time.iso8601(execution.scheduled_for)
    assert_equal execution.input_public_id, turn.input_public_id
    assert_equal "completed", turn.status
    assert_includes turn.text, marker
    reconnect = CybrosAgent::Client.new(base_url: @base_url, credential: @peer.credential)
    recovered_child = reconnect.workspace(@workspace.public_id).conversation(execution.child_conversation_public_id)
    tracking = recovered_child.input_execution(execution.input_public_id)
    recovered = tracking.recover
    refute_nil recovered
    assert_equal [execution.turn_public_id, execution.run_public_id],
      [recovered.execution.turn, recovered.execution.run_public_id]
    assert_equal "completed", recovered.status
    assert_includes recovered.content, marker
    read = @workspace.run(execution.run_public_id).fetch.tasks.find { |task| task.tool_name == "read" }
    assert_equal @runner.executor_public_id, read.claimed_by.executor_public_id
    assert_equal [execution.input_public_id], jobs.executions(schedule.public_id).items.map(&:input_public_id)
  ensure
    E2E.hosts.start
  end

  def test_two_independent_worker_finals_share_a_parent_reply_and_keep_exact_result_identity
    # Preserve the real results without spending the parent's history budget on
    # repeated fixed instructions from three independent model runs.
    chat, held_loop = open_conversation(script("ask", { "prompt" => "Hold for both worker results" }, "main finished",
      echo_content: true))
    @held_loop = held_loop
    # Both workers must capture the same collection to share a reply.
    # Their independent Conversation defaults have different identities.
    chat.set_memory_context(memory_context: { "bindings" => [
      { "name" => "workspace", "access" => "read_write", "source" => { "scope" => "workspace" } },
    ] })
    question = await("the main conversation's hold before both schedules") do
      held_loop.fetch.tasks.find { |task| task.await? && task.status == "awaiting_input" }
    end
    markers = 2.times.map { |index| "worker-#{index}-#{SecureRandom.hex(12)}" }
    jobs = chat.schedules
    run_at = (Time.now + 5).utc.iso8601
    created = markers.each_with_index.map do |marker, index|
      path = "independent-#{index}.txt"
      File.write(File.join(@project, path), marker)
      create_job(jobs, prompt: script("read", { "path" => path }, "report this worker's file", echo_content: true),
        rule: { "kind" => "once", "run_at" => run_at }, idempotency_key: SecureRandom.uuid)
    end
    executions = await("both independent scheduled workers to finish") do
      rows = created.map { |job| jobs.executions(job.public_id).items.first }
      failed = rows.compact.find { |row| %w[failed canceled].include?(row.status) }
      flunk "a scheduled worker failed: #{failed.to_h.inspect}" if failed
      rows if rows.all? { |row| row&.status == "completed" }
    end
    receipts = await("both exact worker results in the held parent's queue") do
      rows = chat.inputs.list.items.select do |input|
        executions.any? { |execution| execution.child_conversation_public_id == input.sender_conversation_public_id }
      end
      rows if rows.length == 2
    end
    assert_equal 2, executions.map(&:run_public_id).uniq.length,
      "the parent receives two independent owners, not two results from one loop"
    assert_predicate chat.fetch, :busy?
    receipts.each do |receipt|
      result = receipt.callback_result
      execution = executions.find { |row| row.child_conversation_public_id == result.conversation_public_id }
      refute_nil execution
      assert_equal execution.input_public_id, result.input_public_id
      assert_equal execution.turn_public_id, result.turn_public_id
    end

    held_loop.tasks_context(question.key).resolve(content: "Read both completed worker results")
    combined = await("one completed parent report carrying both worker identities") do
      rows = chat.turns.list.items.select { |turn| turn.kind == "direct_reply" && turn.callback_sources.length == 2 }
      failed = rows.find { |turn| turn.status == "failed" }
      flunk "the combined report failed: #{failed.to_h.inspect}" if failed
      rows.find { |turn| turn.status == "completed" }
    end
    assert_nil combined.sender_conversation_public_id
    assert_nil combined.sender_run_public_id
    assert_nil combined.sender_task_key
    assert_equal receipts.map(&:public_id).sort, combined.callback_sources.map(&:input_public_id).sort
    assert_equal executions.map(&:input_public_id).sort,
      combined.callback_sources.map { |source| source.result.input_public_id }.sort
    assert_equal executions.map(&:run_public_id).sort,
      combined.callback_sources.map(&:sender_run_public_id).sort
    request = @workspace.run(combined.active_variant.run_public_id).tasks_context("r1").request
    assembled = JSON.generate(request.entries)
    markers.each { |marker| assert_includes assembled, marker, "both real file results reach the one sealed model request" }
    combined.callback_sources.each do |source|
      result = source.result
      child = @workspace.conversation(result.conversation_public_id)
      turn = child.turns.list.items.find { |row| row.public_id == result.turn_public_id }
      assert_equal result.input_public_id, turn.input_public_id
      variant = child.turns.variants(turn.public_id).items.find { |row| row.public_id == result.variant_public_id }
      refute_nil variant, "the independent formal result is readable by its fixed version"
      marker = markers.fetch(executions.index { |row| row.input_public_id == result.input_public_id })
      assert_includes variant.content, marker
    end
    remaining = chat.inputs.list.items.map(&:public_id)
    receipts.each { |receipt| refute_includes remaining, receipt.public_id }
    assert_equal 1, chat.turns.list.items.count { |turn| turn.kind == "direct_reply" && turn.callback_sources.length == 2 }
  end

  private

    def create_job(jobs, **fields)
      created = jobs.create(**fields, model: MODEL, approval_mode: "bypass")
      @job_doors[created.public_id] = jobs
      created
    end

    def open_conversation(prompt)
      chat = @workspace.conversation(@workspace.conversations.create(
        default_runner_executor_public_id: @runner.executor_public_id, idempotency_key: SecureRandom.uuid).public_id)
      receipt = @peer.submit_and_exit(base_url: @base_url, workspace_public_id: @workspace.public_id,
        conversation_public_id: chat.public_id, kind: "direct_reply", model: MODEL, text: prompt,
        idempotency_key: SecureRandom.uuid)
      materialization = await("the submitted input's materialization") { chat.inputs.materialization(receipt) }
      assert_equal receipt, chat.turns.fetch(materialization.turn_public_id).input_public_id
      refute_nil materialization.run_public_id
      [chat, @workspace.run(materialization.run_public_id)]
    end

    def callback_turns(chat, child_id)
      chat.turns.list.items.select { |turn| turn.sender_conversation_public_id == child_id && turn.kind == "direct_reply" }
    end

    def task_text(detail)
      detail.output || detail.content.to_a.filter_map { |block| block["text"] }.join("\n")
    end

    def script(name, arguments, remainder, echo_content: false, prior_answers: 0)
      echo = echo_content ? " echo=content" : ""
      calls = Array.new(prior_answers + 1, "#{name}:#{CGI.escape(JSON.generate(arguments))}").join(",")
      "!mock#{echo} tool_call=#{calls} -- #{remainder}"
    end

    def await(what)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TIMEOUT
      loop do
        result = yield
        return result if result
        flunk "the deployment did not reach #{what} within #{TIMEOUT} seconds" if
          Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep POLL
      end
    end
end
