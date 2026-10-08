require "test_helper"
require "cgi/escape"
require "json"
require "securerandom"
require "support/actor_provisioning"
require "support/peer_program"
require "support/steward_session"

# The child finishes real work before its receipt encounters a provider refusal. Its ask is the
# public rendezvous that lets the parent finish and the answerer change its default first. Both
# model names remain valid in the catalog; the refusal comes from the fake provider's HTTP socket.
class ResultDeliveryFallbackTest < Minitest::Test
  ORIGINAL_MODEL = "dev/mock-text".freeze
  FALLBACK_MODEL = "dev/mock-text-only".freeze
  MEMORY_PATH = "conversation/performed.md".freeze
  POLL = 1
  PATIENCE = 60
  QUIET = 3

  World = Data.define(:client, :workspace)

  class << self
    def world
      @world ||= begin
        base_url = E2E.base_url
        steward = E2E::ActorProvisioning.world(base_url).rho_steward
        actor = E2E::StewardSession.actor(base_url: base_url, human: steward)
        E2E.enable_dev_lane!
        E2E.hosts.start
        peer = E2E::PeerProgram.pair(base_url: base_url, actor: actor, name: "mail-fallback")
        workspace = peer.client.workspaces.create(
          name: "Mail fallback #{SecureRandom.hex(4)}", idempotency_key: SecureRandom.uuid
        ).workspace
        World.new(client: peer.client, workspace: peer.client.workspace(workspace.public_id))
      end
    end
  end

  def setup
    @client = self.class.world.client
    @workspace = self.class.world.workspace
    catalog = @client.tools.list.to_h { |entry| [entry.name, entry.definition] }
    @tools = %w[memory_write spawn ask].map { |name| catalog.fetch(name) }
    declare(default_model: nil, tools: @tools)
    created = @workspace.conversations.create(idempotency_key: SecureRandom.uuid)
    @chat = @workspace.conversation(created.public_id)
  end

  def teardown
    @chat&.cancel unless passed?
  rescue CybrosAgent::Api::Conflict
    # A failed assertion may follow a completed conversation, which has nothing left to cancel.
    nil
  end

  def test_child_mail_uses_the_answerers_default_model_after_an_http_refusal
    open_child_receipt(error_model: "mock-text", mail_tools: [])
    mailed, mail_loop = await_mail_loop
    completed = await("the receipt never completed on the fallback model") do
      row = mail_loop.fetch
      row if row.status == "completed"
    end

    key = completed.deliverable_task_key
    rounds = round_results(mail_loop, key)
    assert_equal [ORIGINAL_MODEL, FALLBACK_MODEL], rounds.map { |event| event.payload.fetch("model") }
    assert_http_refusal rounds.first
    assert_equal "completed", rounds.last.payload.fetch("status")
    assert_equal [key], completed.tasks.map(&:key), "tool-less mail still owns a retryable loop"
    assert_empty mail_loop.tasks_context(key).request.request_options.fetch("tools", [])
    assert_includes mail_loop.task(key).output, @receipt_text
    assert_receipt_preserved(mail_loop, key)
    assert_completed_work_unchanged(mailed)
    assert_usage_attribution(mail_attempts: 2, mail_input: 13, mail_output: 5)
  end

  def test_failed_result_delivery_fallback_parks_and_retry_reuses_the_receipt_without_repeating_completed_work
    open_child_receipt(error_model: nil, mail_tools: @tools)
    mailed, mail_loop = await_mail_loop
    held = await_attention(mail_loop)
    key = held.attention.blocked_task_keys.fetch(0)
    rounds = round_results(mail_loop, key)
    assert_equal [ORIGINAL_MODEL, FALLBACK_MODEL], rounds.map { |event| event.payload.fetch("model") }
    rounds.each { |event| assert_http_refusal event }
    assert_equal "failed", rounds.last.payload.fetch("status")
    assert_receipt_preserved(mail_loop, key)
    assert_usage_attribution(mail_attempts: 2, mail_input: 0, mail_output: 0)

    sleep QUIET
    still_held = mail_loop.fetch
    assert_equal "needs_attention", still_held.status
    assert_equal rounds.map(&:public_id), round_results(mail_loop, key).map(&:public_id),
      "the two refusals exhaust the automatic fallback; no unbounded background retry"

    retried = mail_loop.tasks_context(key).retry(model: ORIGINAL_MODEL)
    assert_equal key, retried.key, "explicit retry owns the existing receipt task"
    await("the explicitly selected model was never attempted") do
      observed = round_results(mail_loop, key)
      observed if observed.length > rounds.length
    end
    after_retry = await_attention(mail_loop)
    final_rounds = round_results(mail_loop, key)
    assert_equal [ORIGINAL_MODEL, FALLBACK_MODEL, ORIGINAL_MODEL],
      final_rounds.map { |event| event.payload.fetch("model") },
      "explicit retry does not replenish the exhausted automatic fallback"
    assert_http_refusal final_rounds.last
    assert_equal [key], after_retry.tasks.map(&:key)
    assert_equal held.public_id, after_retry.public_id
    assert_equal held.turn.public_id, after_retry.turn.public_id
    assert_receipt_preserved(mail_loop, key)
    assert_completed_work_unchanged(mailed)
    assert_usage_attribution(mail_attempts: 3, mail_input: 0, mail_output: 0)
    @chat.cancel
  end

  private

    def declare(default_model:, tools:)
      @client.profile.declare_configuration(
        tool_definitions: tools, approval_mode: "bypass", approval_rules: nil,
        prompt_mechanism: "default", compaction_policy: nil, default_model: default_model
      )
    end

    def open_child_receipt(error_model:, mail_tools:)
      @receipt_text = "child-finished-#{SecureRandom.hex(5)}"
      refusal = "!mock error=401#{" error_model=#{error_model}" if error_model} usage=13:5 -- #{@receipt_text}"
      answer = "#{@receipt_text}\n#{refusal}"
      child_prompt = script([["ask", { "prompt" => "Release the completed child result?" }]],
        "child work", reply: answer, usage: "7:3")
      @chat.inputs.create(
        kind: "direct_reply", model: ORIGINAL_MODEL, idempotency_key: SecureRandom.uuid,
        text: script([
          ["memory_write", { "path" => MEMORY_PATH, "content" => @receipt_text }],
          ["spawn", { "prompt" => child_prompt, "label" => "receipt" }],
        ], "source finished", usage: "11:2")
      )

      source_turn = await("the source turn never materialized") do
        @chat.turns.list.items.find { |turn| turn.active_variant&.run_public_id }
      end
      @source_loop = @workspace.run(source_turn.active_variant.run_public_id)
      await("the source never completed its tools") { @source_loop.fetch.status == "completed" }
      @source_tasks = completed_tasks(@source_loop)
      assert_equal %w[memory_write spawn], @source_tasks.filter_map { |task| task.fetch(:tool_name) }
      @memory = @chat.memory.read(MEMORY_PATH)
      assert_equal @receipt_text, @memory.content

      child = await("the source never spawned its child") { @chat.children.items.first }
      @child_chat = @workspace.conversation(child.public_id)
      child_turn = await("the child never materialized") do
        @child_chat.turns.list.items.find { |turn| turn.active_variant&.run_public_id }
      end
      @child_loop = @workspace.run(child_turn.active_variant.run_public_id)
      ask = await("the child never reached its public rendezvous") do
        @child_loop.fetch.tasks.find { |task| task.kind == "await_task" && task.status == "awaiting_input" }
      end

      declared = declare(default_model: FALLBACK_MODEL, tools: mail_tools)
      assert_equal FALLBACK_MODEL, declared.configuration.default_model
      @child_loop.tasks_context(ask.key).resolve(content: [{ "type" => "text", "text" => "release" }])
      await("the child never completed") { @child_loop.fetch.status == "completed" }
      @child_tasks = completed_tasks(@child_loop)
      @child_turn_id = child_turn.public_id
    end

    def await_mail_loop
      mailed = await("the child receipt was never materialized") do
        items = events(@chat)
        accepted = items.find { |event| event.type == "input_accepted" && event.payload["origin"] == "child" }
        if accepted
          items.find do |event|
            event.type == "input_materialized" &&
              event.payload["input_public_id"] == accepted.payload.fetch("input_public_id")
          end
        end
      end
      opened = events(@chat).find do |event|
        event.type == "turn_status" && event.payload["status"] == "running" &&
          event.payload["turn_public_id"] == mailed.payload.fetch("turn_public_id")
      end
      refute_nil opened, "the materialized receipt must name its running turn"
      id = opened.payload["run_public_id"]
      refute_nil id, "mail without declared tools must still materialize a loop"
      [mailed, @workspace.run(id)]
    end

    def await_attention(context)
      await("the failed receipt never asked for attention") do
        row = context.fetch
        row if row.status == "needs_attention" && row.attention&.blocked_task_keys&.any?
      end
    end

    def assert_http_refusal(event)
      assert_equal "provider_model_unavailable", event.payload.fetch("error_key")
      assert_match(/401/, event.payload.fetch("error_detail"))
    end

    def assert_receipt_preserved(context, key)
      request = context.tasks_context(key).request
      text = JSON.generate(request.entries)
      assert_includes text, @receipt_text
      assert_includes text, @child_chat.public_id
      assert_includes text, "task_result"
      assert_equal key, context.task(key).task.key
    end

    def assert_completed_work_unchanged(mailed)
      assert_equal @source_tasks, completed_tasks(@source_loop), "the parent's completed tools never rerun"
      assert_equal @child_tasks, completed_tasks(@child_loop), "the child's completed work never reruns"
      assert_equal [@child_turn_id], @child_chat.turns.list.items.map(&:public_id)
      assert_equal [@child_chat.public_id], @chat.children.items.map(&:public_id)
      assert_equal @memory, @chat.memory.read(MEMORY_PATH), "content and written_at stay unchanged"
      items = events(@chat)
      assert_equal 1, items.count { |event| event.type == "input_accepted" && event.payload["origin"] == "child" }
      materializations = items.count do |event|
        event.type == "input_materialized" && event.payload["input_public_id"] == mailed.payload.fetch("input_public_id")
      end
      assert_equal 1, materializations
    end

    def assert_usage_attribution(mail_attempts:, mail_input:, mail_output:)
      # Three source rounds and two child rounds are already finished. The
      # parent's mail may retry, but neither imports the other's paid work.
      parent = @chat.fetch.usage_summary
      child = @child_chat.fetch.usage_summary
      assert_equal 3 + mail_attempts, parent.request_count,
        "both the refused attempt and its fallback remain in the parent's total"
      assert_equal 33 + mail_input, parent.input_tokens
      assert_equal 6 + mail_output, parent.output_tokens
      assert_equal parent.input_tokens + parent.output_tokens, parent.total_tokens
      assert_equal [2, 14, 6, 20],
        [child.request_count, child.input_tokens, child.output_tokens, child.total_tokens],
        "the child owns only its two calls, even when its result causes parent fallback or retry"
    end

    def completed_tasks(context)
      context.fetch.tasks.map do |task|
        task.to_h.slice(:key, :kind, :status, :tool_name, :started_at, :completed_at)
      end
    end

    def round_results(context, key)
      events(@chat).select do |event|
        event.type == "round_result" && event.payload["task_key"] == key &&
          event.payload["run_public_id"] == context.run_public_id
      end
    end

    def events(context)
      items = []
      after = nil
      loop do
        page = context.events(after: after, limit: 200)
        items.concat(page.items)
        after = page.next_after
        break if after.nil?
      end
      items
    end

    def script(calls, remainder, reply: nil, usage: nil)
      spelled = calls.map { |name, arguments| "#{name}:#{CGI.escape(JSON.generate(arguments))}" }
      answer = " reply=#{CGI.escape(reply)}" if reply
      "!mock tool_call=#{spelled.join(",")}#{answer}#{" usage=#{usage}" if usage} -- #{remainder}"
    end

    def await(message)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + PATIENCE
      loop do
        result = yield
        return result if result

        flunk(message) if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep POLL
      end
    end
end
