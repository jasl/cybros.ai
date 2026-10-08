require "support/runtime"

class TelegramRecoveryTest < Minitest::Test
  include TelegramRuntimeSupport

  # Keep the production signature: keyword-only fakes previously hid invalid calls.
  class LifecycleClient < TelegramRuntimeSupport::Client
    attr_reader :polls, :closed
    attr_accessor :on_poll

    def initialize(bot_id: 42, transient_identity_failure: false)
      super()
      @bot_id, @transient_identity_failure = bot_id, transient_identity_failure
      @polls, @closed = [], false
    end

    def call(method, params = {}, poll: false)
      return super unless %w[getMe getUpdates].include?(method)

      @calls << [method, params]
      if method == "getMe"
        if @transient_identity_failure
          @transient_identity_failure = false
          raise Rho::IngressTelegram::Client::Unavailable.new(reason: :connection, ambiguous: true)
        end
        { "id" => @bot_id, "username" => "rho_bot" }
      else
        @polls << [params, poll]
        @on_poll.call
        []
      end
    end

    def close = @closed = true
  end

  class ImmediateRetryRuntime < Rho::IngressTelegram::Runtime
    attr_reader :delays

    def initialize(**options)
      super
      @delays = []
    end

    private

      def sleep(duration)
        @delays << duration
        Kernel.sleep(0)
      end
  end

  def test_start_retries_transient_identification_before_polling
    @client = LifecycleClient.new(transient_identity_failure: true)
    instance = unidentified_runtime
    @client.on_poll = -> { instance.close }

    Async { |task| task.with_timeout(1) { instance.start } }.wait

    assert_equal %w[getMe getMe setMyCommands getUpdates], @client.calls.map(&:first)
    menu = @client.calls.find { |method, _params| method == "setMyCommands" }.last.fetch(:commands)
    assert_includes menu.map { |entry| entry.fetch(:command) }, "stop"
    assert_includes instance.delays, 5
    assert_equal 1, @client.polls.length
    options, polling = @client.polls.first
    assert polling
    assert_equal %w[message callback_query stopped_message_generation], options.fetch(:allowed_updates)
    assert_equal "42", @state.read.fetch("bot_id")
    assert @client.closed
  end

  def test_start_with_a_different_bot_never_polls_or_rebinds_state
    @client = LifecycleClient.new(bot_id: 99)
    instance = unidentified_runtime

    Async do |task|
      task.with_timeout(1) do
        assert_raises(Rho::ConfigurationError) { instance.start }
      end
    end.wait

    assert_equal ["getMe"], @client.calls.map(&:first)
    assert_empty @client.polls
    assert_empty instance.delays
    assert_equal "configuration_error", instance.status.fetch("connection")
    assert_equal "42", @state.read.fetch("bot_id")
    assert @client.closed
  end

  def test_callback_ack_uses_client_signature_and_exact_original_task
    receive(telegram_message(1, "start"))
    @bridge.pending_rows = [approval]
    @runtime.tick
    id = @state.read.fetch("questions").keys.fetch(0)

    # Telegram gives the original message date, not the time of this click.
    receive(approval_callback(2, id, message_date: 1))
    assert_equal [["approve", "child-loop", "dangerous-tool", "workspace-home"]], @bridge.decisions
    assert_equal ["answerCallbackQuery", { callback_query_id: "callback-2" }], @client.calls.last
    assert_equal 3, @state.read.fetch("offset")

    receive(approval_callback(3, id, message_date: 1))
    assert_equal 1, @bridge.decisions.length
    assert_equal ["answerCallbackQuery", { callback_query_id: "callback-3" }], @client.calls.last
    assert_includes @state.read.fetch("deliveries").fetch("control:3").fetch("text"), "no longer available"
  end

  def test_expired_queued_question_is_not_sent_and_a_new_question_can_be_delivered
    receive(telegram_message(1, "start"))
    @state.change { |document| document["retry_at"] = @now + 1 }
    @bridge.pending_rows = [approval]
    @runtime.tick
    id = @state.read.fetch("questions").keys.fetch(0)
    assert_equal "pending", @state.read.fetch("deliveries").fetch("question:#{id}").fetch("status")
    assert_empty approval_messages

    @now += 1
    @bridge.pending_rows = []
    @runtime = runtime
    @runtime.tick
    refute @state.read.fetch("questions").key?(id)
    refute @state.read.fetch("deliveries").key?("question:#{id}")
    assert_empty approval_messages

    receive(approval_callback(2, id))
    assert_empty @bridge.decisions
    assert_includes @state.read.fetch("deliveries").fetch("control:2").fetch("text"), "no longer available"
    @runtime = runtime
    @runtime.tick

    @bridge.pending_rows = [approval.merge("task_key" => "new-tool")]
    @runtime = runtime
    @runtime.tick
    fresh_id = @state.read.fetch("questions").keys.fetch(0)
    refute_equal id, fresh_id
    assert_equal 1, approval_messages.length
    buttons = approval_messages.first.last.fetch(:reply_markup).fetch("inline_keyboard").first
    assert_equal ["approve:#{fresh_id}", "deny:#{fresh_id}"], buttons.map { |button| button.fetch("callback_data") }
    assert_equal "sent", @state.read.fetch("deliveries").fetch("question:#{fresh_id}").fetch("status")
  end

  def test_decision_survives_follower_removing_the_resolved_question_before_ack
    receive(telegram_message(1, "start"))
    @bridge.pending_rows = [approval]
    @runtime.tick
    id = @state.read.fetch("questions").keys.fetch(0)
    follower = @runtime
    @now += Rho::IngressTelegram::Runtime::RECONCILE_INTERVAL
    @bridge.define_singleton_method(:approve) do |run_id, task_key, workspace_public_id: nil|
      @decisions << ["approve", run_id, task_key, workspace_public_id]
      @pending_rows = []
      follower.tick
    end

    receive(approval_callback(2, id))

    assert_equal [["approve", "child-loop", "dangerous-tool", "workspace-home"]], @bridge.decisions
    refute @state.read.fetch("questions").key?(id)
    assert_equal "Response accepted.", @state.read.fetch("deliveries").fetch("control:2").fetch("text")
    assert_equal 3, @state.read.fetch("offset")
    receive(approval_callback(2, id))
    assert_equal 1, @bridge.decisions.length
  end

  def test_long_tool_refreshes_same_draft_but_full_final_is_always_formal
    receive(telegram_message(1, "start"))
    @runtime.tick
    assert_equal "sendMessageDraft", @client.calls.first.first
    @client.calls.clear
    route = @state.read.fetch("routes").fetch("1:0")
    limits = Rho::IngressTelegram::RateLimit.new(clock: -> { @now })
    sender = Rho::IngressTelegram::Delivery.new(client: @client, state: @state, limits: limits, clock: -> { @now })
    snapshot = @bridge.current.merge("reasoning" => "private reasoning", "log" => "private tool log",
      "text" => "partial answer", "transcript" => "private transcript")
    sender.progress(route, "conversation-1", snapshot)
    @now += 14
    sender.progress(route, "conversation-1", snapshot)
    assert_equal 1, @client.calls.length
    @now += 1
    sender.progress(route, "conversation-1", snapshot)
    assert_equal %w[sendMessageDraft sendMessageDraft], @client.calls.map(&:first)
    drafts = @client.calls.map(&:last)
    assert_equal drafts.first.fetch(:draft_id), drafts.last.fetch(:draft_id)
    assert_equal "Working on your request.\nNow: running a command", drafts.last.fetch(:text)
    assert drafts.all? { |params| params.fetch(:can_stop) }
    assert_operator Rho::IngressTelegram::Render.utf16_length(drafts.last.fetch(:text)), :<=, 800
    assert_equal "loop-1", @state.read.fetch("routes").dig("1:0", "draft", "run_id")

    body = "完整答案😀\n" * 800
    @state.enqueue("final", route: route, text: body)
    parts = Rho::IngressTelegram::Render.chunks(body)
    parts.length.times do
      @now += 1
      sender.flush
    end
    formal = @client.calls.drop(2)
    assert_equal ["sendMessage"] * parts.length, formal.map(&:first)
    assert_equal body, formal.map { |_method, params| params.fetch(:text) }.join
    assert_equal "sent", @state.read.fetch("deliveries").fetch("final").fetch("status")
    assert_equal parts.length, @state.read.fetch("deliveries").fetch("final").fetch("message_ids").length
  end

  private

    def unidentified_runtime
      logger = Object.new
      logger.define_singleton_method(:warn) { |*| }
      ImmediateRetryRuntime.new(settings: @settings, state: @state, bridge: @bridge,
        client: @client, log: logger, clock: -> { @now })
    end

    def approval
      { "workspace_public_id" => "workspace-home", "run_public_id" => "child-loop", "task_key" => "dangerous-tool", "kind" => "approval",
        "question" => "Run the reviewed command?" }
    end

    def approval_callback(id, question_id, message_date: 1_000)
      { "update_id" => id, "callback_query" => { "id" => "callback-#{id}",
        "from" => { "id" => 1, "first_name" => "Person 1" }, "data" => "approve:#{question_id}",
        "message" => { "message_id" => 100, "date" => message_date,
          "chat" => { "id" => 1, "type" => "private" } } } }
    end

    def approval_messages
      @client.calls.select { |_method, params| params.key?(:reply_markup) }
    end
end
