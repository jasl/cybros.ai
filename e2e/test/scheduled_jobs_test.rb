require "test_helper"
require "cgi/escape"
require "fileutils"
require "json"
require "securerandom"
require "time"
require "tmpdir"
require "support/actor_provisioning"
require "support/ceremony"
require "support/rho_daemon"
require "support/secret_hygiene"
require "support/steward_session"

# A saved job executes through the deployed scheduler, child conversation and
# ordinary runner. The main conversation is held on a public ask rendezvous;
# its busy state must not prevent the child from reading a real project file.
# The result then returns through ordinary child mail, with durable provenance.
class ScheduledJobsTest < Minitest::Test
  MODEL = "dev/mock-text".freeze
  POLL = 1
  TIMEOUT = E2E::RhoDaemon::WATCH_TIMEOUT

  def setup
    @base_url = E2E.base_url
    steward = E2E::ActorProvisioning.world(@base_url).rho_steward
    actor = E2E::StewardSession.actor(base_url: @base_url, human: steward)
    @home = Dir.mktmpdir("rho-scheduled-jobs-e2e")
    @project = File.realpath(Dir.mktmpdir("rho-scheduled-jobs-project"))
    @job_doors = {}
    @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home, tools_root: @project)
    @daemon.start
    E2E::Ceremony.confirm(actor: actor, started: @daemon.start_ceremony, status: -> { @daemon.status })
    workspace_id = @daemon.await("rho never adopted its workspace") do
      row = @daemon.status["workspace"]
      flunk "rho workspace failed: #{row.inspect}" if row&.fetch("state") == "error"
      row.fetch("public_id") if row&.fetch("state") == "adopted"
    end
    client = CybrosAgent::Client.new(base_url: @base_url, credential: steward.member_token)
    @workspace = client.workspace(workspace_id)
    E2E.enable_dev_lane!
    E2E.hosts.start
  end

  def teardown
    unless passed?
      [@daemon&.log_path, @daemon&.rho_log_path].compact.each do |path|
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
    @daemon&.stop
    [@home, @project].compact.each { |path| FileUtils.remove_entry(path) if File.directory?(path) }
  end

  def test_saved_jobs_keep_their_policy_run_independently_and_return_one_callback
    chat, held_loop = open_conversation(script("ask", { "prompt" => "Hold the main conversation" }, "main finished"))
    @held_loop = held_loop
    question = await("the main conversation's ask") do
      held_loop.fetch.tasks.find { |task| task.await? && task.status == "awaiting_input" }
    end
    assert_predicate chat.fetch, :busy?

    verify_interval_lifecycle(chat)
    verify_model_created_job

    secret = "scheduled-file-result-#{SecureRandom.hex(12)}"
    File.write(File.join(@project, "scheduled-result.txt"), secret)
    prompt = script("read", { "path" => "scheduled-result.txt" }, "report the file contents")
    rule = { "kind" => "once", "run_at" => (Time.now + 5).utc.iso8601 }
    key = SecureRandom.uuid
    jobs = chat.scheduled_jobs
    created = create_job(jobs, prompt: prompt, rule: rule, idempotency_key: key)
    refute_predicate created, :replayed?
    execution = await("the once job's independent execution") do
      row = jobs.executions(created.public_id).items.first
      flunk "the scheduled child failed: #{row.to_h.inspect}" if row && %w[failed canceled].include?(row.status)
      row if row&.status == "completed"
    end

    refute_equal chat.public_id, execution.child_conversation_public_id
    refute_equal held_loop.agent_loop_public_id, execution.agent_loop_public_id
    refute_nil execution.input_public_id
    refute_nil execution.turn_public_id
    assert_equal Time.iso8601(rule.fetch("run_at")), Time.iso8601(execution.scheduled_for)
    assert_operator Time.iso8601(execution.created_at), :>=, Time.iso8601(rule.fetch("run_at"))
    child = @workspace.conversation(execution.child_conversation_public_id)
    assert_equal chat.public_id, child.fetch.parent.public_id
    child_loop = @workspace.agent_loop(execution.agent_loop_public_id)
    first_entries = child_loop.tasks_context("r1").request.entries
    first_request = JSON.generate(first_entries)
    assert_includes JSON.generate(first_entries.last), "Conversation kind: scheduled.",
      "the deployed profile knows this is an execution before its first model round"
    refute_includes first_request, "{{conversation_kind}}", "the execution fact is compiled, not a literal macro"
    read = child_loop.fetch.tasks.find { |task| task.tool_name == "read" }
    refute_nil read, "the scheduled prompt used the ordinary read tool"
    assert_equal "completed", read.status
    refute_nil read.claimed_by, "the actual runner claimed the read"
    assert_includes task_text(child_loop.task(read.key)), secret, "only the real project file contains this result"
    assert_includes child.turns.list.items.find { |turn| turn.public_id == execution.turn_public_id }.text, secret

    assert_predicate chat.fetch, :busy?, "the child completed while the original main turn remained held"
    assert_equal "awaiting_input", held_loop.task(question.key).task.status
    mail = await("the child's queued result on the busy main conversation") do
      chat.inputs.list.items.find do |input|
        input.origin == "child" && input.sender_conversation_public_id == child.public_id
      end
    end
    assert_equal "pending", mail.state
    assert_empty callback_turns(chat, child.public_id), "the result waits at the main conversation's turn boundary"

    held_loop.tasks_context(question.key).resolve(content: "Continue the main conversation")
    callback = await("the main conversation's completed callback") do
      rows = callback_turns(chat, child.public_id)
      failed = rows.find { |turn| turn.status == "failed" }
      flunk "the callback failed: #{failed.to_h.inspect}" if failed
      rows.find { |turn| turn.status == "completed" }
    end
    assert_equal execution.agent_loop_public_id, callback.sender_agent_loop_public_id
    assert_equal created.public_id, callback.sender_task_key
    refute_equal held_loop.agent_loop_public_id, callback.active_variant.agent_loop_public_id
    request = @workspace.agent_loop(callback.active_variant.agent_loop_public_id).tasks_context("r1").request
    receipt = request.entries.last.fetch("parts").filter_map { |part| part["text"] }.join("\n")
    assert_includes receipt, secret, "the current callback carries the child's actual tool result"
    assert_includes receipt, "<prompt>#{prompt[0, 80]}</prompt>",
      "a directly saved job carries its accepted request brief even though the main never requested that work"
    assert_includes receipt, "scheduled_for=\"#{Time.iso8601(execution.scheduled_for).utc.iso8601(6)}\"",
      "the callback identifies this occurrence's original planned time"
    assert_includes callback.text, secret
    assert_equal "completed", jobs.fetch(created.public_id).status

    replay = jobs.create(prompt: prompt, rule: rule, model: MODEL, approval_mode: "bypass", idempotency_key: key)
    assert_predicate replay, :replayed?
    assert_equal created.public_id, replay.public_id
    page = jobs.executions(created.public_id)
    assert_equal [execution.input_public_id], page.items.map(&:input_public_id)
    refute_nil page.last_cursor
    tail = jobs.executions(created.public_id, after: page.last_cursor)
    assert_empty tail.items
    assert_equal page.last_cursor, tail.last_cursor

    continued = continue_main(chat, after: callback.position)
    assert_includes continued.text, "continued"
    assert_equal [callback.public_id], callback_turns(chat, child.public_id).map(&:public_id),
      "one execution returned once across a subsequent ordinary main turn"
    assert_equal [execution.input_public_id], jobs.executions(created.public_id).items.map(&:input_public_id)

    verify_parent_followup(chat, child, after: continued.position, jobs: jobs,
      job_id: created.public_id, execution: execution)
  end

  def test_two_independent_worker_finals_share_a_parent_reply_and_keep_exact_result_identity
    chat, held_loop = open_conversation(script("ask", { "prompt" => "Hold for both worker results" }, "main finished"))
    @held_loop = held_loop
    question = await("the main conversation's hold before both schedules") do
      held_loop.fetch.tasks.find { |task| task.await? && task.status == "awaiting_input" }
    end
    markers = 2.times.map { |index| "worker-#{index}-#{SecureRandom.hex(12)}" }
    jobs = chat.scheduled_jobs
    run_at = (Time.now + 5).utc.iso8601
    created = markers.each_with_index.map do |marker, index|
      path = "independent-#{index}.txt"
      File.write(File.join(@project, path), marker)
      create_job(jobs, prompt: script("read", { "path" => path }, "report this worker's file"),
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
    assert_equal 2, executions.map(&:agent_loop_public_id).uniq.length,
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
    assert_nil combined.sender_agent_loop_public_id
    assert_nil combined.sender_task_key
    assert_equal receipts.map(&:public_id).sort, combined.callback_sources.map(&:input_public_id).sort
    assert_equal executions.map(&:input_public_id).sort,
      combined.callback_sources.map { |source| source.result.input_public_id }.sort
    assert_equal executions.map(&:agent_loop_public_id).sort,
      combined.callback_sources.map(&:sender_agent_loop_public_id).sort
    request = @workspace.agent_loop(combined.active_variant.agent_loop_public_id).tasks_context("r1").request
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

    def verify_parent_followup(chat, child, after:, jobs:, job_id:, execution:)
      marker = "scheduled-followup-#{SecureRandom.hex(12)}"
      prompt = script("send", { "to" => child.public_id, "message" => "!mock reply=#{marker} -- answer the follow-up" },
        "follow-up sent")
      chat.inputs.create(kind: "direct_reply", model: MODEL, text: prompt,
        approval_mode: "bypass", idempotency_key: SecureRandom.uuid)
      parent = await("the parent conversation's follow-up request") do
        chat.turns.list.items.find do |turn|
          turn.position > after && turn.kind == "direct_reply" && turn.role == "assistant" &&
            turn.status == "completed" && turn.sender_conversation_public_id.nil?
        end
      end
      owner = @workspace.agent_loop(parent.active_variant.agent_loop_public_id)
      send = owner.fetch.tasks.find { |task| task.tool_name == "send" }
      refute_nil send, "the parent sent a new request into its scheduled child"
      assert_equal "completed", send.status
      reply = await("the scheduled child's reply to its parent's later request") do
        callback_turns(chat, child.public_id).find do |turn|
          turn.position > parent.position && turn.status == "completed" && turn.sender_task_key == send.key
        end
      end
      assert_equal owner.agent_loop_public_id, reply.sender_agent_loop_public_id,
        "the later request owns its reply independently of the original clock occurrence"
      assert_includes reply.text, marker
      assert_equal [execution.input_public_id], jobs.executions(job_id).items.map(&:input_public_id),
        "a follow-up does not create another scheduled occurrence"
      assert_equal "completed", jobs.fetch(job_id).status
    end

    def verify_interval_lifecycle(chat)
      jobs = chat.scheduled_jobs
      rule = { "kind" => "interval", "every_seconds" => 3_600, "starts_at" => (Time.now + 3_600).utc.iso8601 }
      created = create_job(jobs, prompt: "inspect the project later", rule: rule, idempotency_key: SecureRandom.uuid)
      assert_equal "active", created.scheduled_job.status
      assert_includes jobs.list.items.map(&:public_id), created.public_id
      row = jobs.fetch(created.public_id)
      updated = jobs.update(row.public_id, expected_lock_version: row.lock_version, prompt: "inspect the revised project later")
      assert_equal "inspect the revised project later", updated.prompt
      assert_operator updated.lock_version, :>, row.lock_version
      assert_equal "paused", jobs.pause(row.public_id).status
      assert_equal "active", jobs.resume(row.public_id).status
      assert_equal "canceled", jobs.cancel(row.public_id).status
      assert_empty jobs.executions(row.public_id).items, "future lifecycle edits do not dispatch an occurrence"
    end

    def verify_model_created_job
      arguments = { "action" => "create", "prompt" => "inspect the project from a model-created plan",
        "rule" => { "kind" => "interval", "every_seconds" => 3_600, "starts_at" => (Time.now + 3_600).utc.iso8601 } }
      chat, source = open_conversation(script("manage_scheduled_job", arguments, "job saved"))
      completed = await("the model's schedule tool to complete") do
        row = source.fetch
        flunk "the schedule tool's turn failed: #{row.to_h.inspect}" if row.status == "failed"
        row if row.status == "completed"
      end
      call = completed.tasks.find { |task| task.tool_name == "manage_scheduled_job" }
      refute_nil call
      assert_equal "completed", call.status
      rows = chat.scheduled_jobs.list.items
      assert_equal 1, rows.length
      row = rows.fetch(0)
      @job_doors[row.public_id] = chat.scheduled_jobs
      assert_equal source.agent_loop_public_id, row.source_agent_loop_public_id
      assert_equal call.key, row.source_task_key
      detail = source.task(call.key)
      declaring = source.task(detail.declaring_task_key)
      names = declaring.tool_definitions.map { |entry| entry.dig("function", "name") || entry.fetch("name") }
      assert_equal names.sort, row.tool_names.sort, "the actual calling model round owns the saved tool policy"
      assert_equal declaring.task.model.fetch("model"), row.model.model
      assert_equal completed.approval_mode, row.approval_mode
      refute_nil completed.turn.answering_user_public_id
      assert_equal completed.turn.answering_user_public_id, row.answering_user_public_id,
        "the calling turn owns the saved answerer"
      assert_equal "canceled", chat.scheduled_jobs.cancel(row.public_id).status
    end

    def create_job(jobs, **fields)
      created = jobs.create(**fields, model: MODEL, approval_mode: "bypass")
      @job_doors[created.public_id] = jobs
      created
    end

    def open_conversation(prompt)
      output, status = @daemon.cli("do", prompt, "--model", MODEL, "--dir", @project)
      assert_predicate status, :success?, "rho do failed:\n#{output}"
      conversation_id, loop_id = %w[conversation loop].map { |name| output[/^#{name}:\s+(\S+)/, 1] }
      refute_nil conversation_id, output
      refute_nil loop_id, output
      [@workspace.conversation(conversation_id), @workspace.agent_loop(loop_id)]
    end

    def continue_main(chat, after:)
      chat.inputs.create(kind: "direct_reply", model: MODEL, text: "!mock reply=continued -- continue normally",
        approval_mode: "bypass", idempotency_key: SecureRandom.uuid)
      await("a subsequent ordinary main conversation reply") do
        chat.turns.list.items.find do |turn|
          turn.role == "assistant" && turn.position > after && turn.status == "completed" &&
            turn.sender_conversation_public_id.nil?
        end
      end
    end

    def callback_turns(chat, child_id)
      chat.turns.list.items.select { |turn| turn.sender_conversation_public_id == child_id && turn.kind == "direct_reply" }
    end

    def task_text(detail)
      detail.output || detail.content.to_a.filter_map { |block| block["text"] }.join("\n")
    end

    def script(name, arguments, remainder)
      "!mock tool_call=#{name}:#{CGI.escape(JSON.generate(arguments))} -- #{remainder}"
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
