require "support/daemon_run_helpers"

class DaemonInputIdempotencyTest < Minitest::Test
  include RhoTest::DaemonRunHelpers

  # The kernel owns receipts, scoped to the acting credential and door. This
  # transport double can lose a response AFTER accepting the input, so a retry
  # through Core, the daemon and the real SDK must carry the same key and body.
  class ReceiptApi < NexusDoubles::FakeAgentApi
    attr_reader :writes

    def initialize(lose_input_response: false)
      super(trace: NexusDoubles::RUNNING_TRACE)
      @receipts = {}
      @writes = []
      @lose_input_response = lose_input_response
    end

    def call(path, method: :get, credential: nil, body: nil, headers: {}, **options)
      return super unless method == :post && path.match?(%r{/(conversations|inputs)\z})

      key = headers.fetch("Idempotency-Key")
      @writes << [path, key]
      scope = [credential, path, key]
      if (receipt = @receipts[scope])
        previous, response = receipt
        raise CybrosAgent::Api::Conflict.new("The request changed", code: "idempotency_envelope_mismatch") if previous != body

        return response
      end

      response = super
      @receipts[scope] = [JSON.parse(JSON.generate(body)), response]
      if path.end_with?("/inputs") && @lose_input_response
        @lose_input_response = false
        raise CybrosAgent::TransportError, "The accepted input response was lost"
      end
      response
    end
  end

  def test_retrying_an_open_after_the_first_input_response_is_lost_reuses_both_receipts
    api = ReceiptApi.new(lose_input_response: true)
    core = connected_core(api)

    error = assert_raises(Rho::Core::Refused) do
      core.open_conversation(prompt: "fix it", model: "dev/mock-text", idempotency_key: "telegram-event-1")
    end
    assert_equal 502, error.status
    assert_equal 1, api.conversation_creates.length
    assert_equal 1, api.conversation_inputs.length, "acceptance happened before the response was lost"

    answer = core.open_conversation(prompt: "fix it", model: "dev/mock-text", idempotency_key: "telegram-event-1")

    assert_equal "c-1", answer.dig("conversation", "public_id")
    assert_equal "cin-1", answer.dig("input", "public_id")
    assert_equal 1, api.conversation_creates.length, "the create receipt returns the existing conversation"
    assert_equal 1, api.conversation_inputs.length, "the first input is accepted only once"
    assert_equal ["telegram-event-1"] * 4, api.writes.map(&:last)

    error = assert_raises(Rho::Core::Refused) do
      core.open_conversation(prompt: "different words", model: "dev/mock-text", idempotency_key: "telegram-event-1")
    end
    assert_equal [409, "idempotency_envelope_mismatch"], [error.status, error.code]
    assert_equal 1, api.conversation_inputs.length
    assert_equal ["telegram-event-1"] * 6, api.writes.map(&:last), "a conflict never mints a replacement key"
  end

  def test_promptless_open_reuses_the_create_key_and_never_posts_an_input
    api = ReceiptApi.new
    core = connected_core(api)

    first = core.open_conversation(title: "Telegram", idempotency_key: "chat-1")
    replay = core.open_conversation(title: "Telegram", idempotency_key: "chat-1")

    assert_equal first.fetch("conversation"), replay.fetch("conversation")
    assert_equal 1, api.conversation_creates.length
    assert_empty api.conversation_inputs
    assert_equal %w[chat-1 chat-1], api.writes.map(&:last)
  end

  def test_prepared_images_replay_the_accepted_input_after_a_lost_response_without_new_uploads
    api = ReceiptApi.new(lose_input_response: true)
    core = connected_core(api)
    fields = { model: "dev/mock-text", upload_public_ids: ["up-prepared"], idempotency_key: "image-update" }
    error = assert_raises(Rho::Core::Refused) { core.open_conversation(**fields) }
    assert_equal 502, error.status

    answer = core.open_conversation(**fields)
    assert_equal "cin-1", answer.dig("input", "public_id")
    assert_equal 1, api.conversation_inputs.length
    assert_equal ["", ["up-prepared"]], api.conversation_inputs.first.fetch("input").values_at("text", "attachments")
    assert_empty api.uploads

    error = assert_raises(Rho::Core::Refused) do
      core.open_conversation(**fields.merge(upload_public_ids: ["different-upload"]))
    end
    assert_equal [409, "idempotency_envelope_mismatch"], [error.status, error.code]
    assert_equal 1, api.conversation_inputs.length
  end

  def test_say_reuses_the_input_key_and_preserves_a_conflict
    api = ReceiptApi.new
    core = connected_core(api)
    conversation = core.open_conversation(model: "dev/mock-text").dig("conversation", "public_id")

    first = core.say(conversation, "hello", mode: "queue", idempotency_key: "event-2")
    replay = core.say(conversation, "hello", mode: "queue", idempotency_key: "event-2")

    assert_equal first.dig("input", "public_id"), replay.dig("input", "public_id")
    assert_equal 1, api.conversation_inputs.length
    assert_equal %w[event-2 event-2], api.writes.last(2).map(&:last)

    error = assert_raises(Rho::Core::Refused) do
      core.say(conversation, "changed", mode: "queue", idempotency_key: "event-2")
    end
    assert_equal [409, "idempotency_envelope_mismatch"], [error.status, error.code]
    assert_equal 1, api.conversation_inputs.length
    assert_equal "event-2", api.writes.last.last
  end

  def test_omitting_the_key_keeps_independent_random_keys_for_each_write
    api = ReceiptApi.new
    core = connected_core(api)

    2.times { core.open_conversation(prompt: "hello", model: "dev/mock-text") }
    2.times { core.open_conversation }
    2.times { core.say("c-1", "hello") }

    keys = api.writes.map(&:last)
    assert_equal 8, keys.length
    assert_equal keys.length, keys.uniq.length
    keys.each { |key| assert_match(/\A[0-9a-f-]{36}\z/, key) }
    assert_equal 4, api.conversation_creates.length
    assert_equal 4, api.conversation_inputs.length
  end

  private

    def connected_core(api)
      now = Time.now
      daemon = member_ready(boot(realtime_factory: ->(*) { nil },
        clock: -> { now }, sleeper: ->(_) { now += Rho::Daemon::HostFollowers::MATERIALIZATION_WAIT }), api)
      Rho::Core.new(home: daemon.home)
    end
end
