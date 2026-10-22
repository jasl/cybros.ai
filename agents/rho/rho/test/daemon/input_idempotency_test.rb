require "support/daemon_run_helpers"
require "support/receipt_api"

class DaemonInputIdempotencyTest < Minitest::Test
  include RhoTest::DaemonRunHelpers

  def test_retrying_an_open_after_the_first_input_response_is_lost_reuses_both_receipts
    api = RhoTest::ReceiptApi.new(lose_input_response: true)
    core = connected_core(api)

    error = assert_raises(Rho::Core::Refused) do
      core.open_conversation(prompt: "fix it", model: "dev/mock-text", idempotency_key: "telegram-event-1")
    end
    assert_equal 502, error.status
    assert_equal 1, api.conversation_creates.length
    assert_equal 1, api.inputs.length, "acceptance happened before the response was lost"

    answer = core.open_conversation(prompt: "fix it", model: "dev/mock-text", idempotency_key: "telegram-event-1")

    assert_equal "c-1", answer.dig("conversation", "public_id")
    assert_equal "cin-1", answer.dig("input", "public_id")
    assert_equal 1, api.conversation_creates.length, "the create receipt returns the existing conversation"
    assert_equal 1, api.inputs.length, "the first input is accepted only once"
    assert_equal ["telegram-event-1"] * 4, api.writes.map(&:last)

    error = assert_raises(Rho::Core::Refused) do
      core.open_conversation(prompt: "different words", model: "dev/mock-text", idempotency_key: "telegram-event-1")
    end
    assert_equal [409, "idempotency_envelope_mismatch"], [error.status, error.code]
    assert_equal 1, api.inputs.length
    assert_equal ["telegram-event-1"] * 5, api.writes.map(&:last), "a conflict never mints a replacement key"
  end

  def test_promptless_open_reuses_the_create_key_and_never_posts_an_input
    api = RhoTest::ReceiptApi.new
    core = connected_core(api)

    first = core.open_conversation(title: "Telegram", idempotency_key: "chat-1")
    replay = core.open_conversation(title: "Telegram", idempotency_key: "chat-1")

    assert_equal first.fetch("conversation"), replay.fetch("conversation")
    assert_equal 1, api.conversation_creates.length
    assert_empty api.inputs
    assert_equal %w[chat-1 chat-1], api.writes.map(&:last)
  end

  def test_prepared_images_replay_the_accepted_input_after_a_lost_response_without_new_uploads
    api = RhoTest::ReceiptApi.new(lose_input_response: true)
    core = connected_core(api)
    fields = { model: "dev/mock-text", upload_public_ids: ["up-prepared"], idempotency_key: "image-update" }
    error = assert_raises(Rho::Core::Refused) { core.open_conversation(**fields) }
    assert_equal 502, error.status

    answer = core.open_conversation(**fields)
    assert_equal "cin-1", answer.dig("input", "public_id")
    assert_equal 1, api.inputs.length
    assert_equal ["", ["up-prepared"]], api.inputs.first.fetch("input").values_at("text", "attachments")
    assert_empty api.uploads

    error = assert_raises(Rho::Core::Refused) do
      core.open_conversation(**fields.merge(upload_public_ids: ["different-upload"]))
    end
    assert_equal [409, "idempotency_envelope_mismatch"], [error.status, error.code]
    assert_equal 1, api.inputs.length
  end

  def test_say_reuses_the_input_key_and_preserves_a_conflict
    api = RhoTest::ReceiptApi.new
    core = connected_core(api)
    conversation = core.open_conversation(model: "dev/mock-text").dig("conversation", "public_id")

    first = core.say(conversation, "hello", mode: "queue", idempotency_key: "event-2")
    replay = core.say(conversation, "hello", mode: "queue", idempotency_key: "event-2")

    assert_equal first.dig("input", "public_id"), replay.dig("input", "public_id")
    assert_equal 1, api.inputs.length
    assert_equal %w[event-2 event-2], api.writes.last(2).map(&:last)

    error = assert_raises(Rho::Core::Refused) do
      core.say(conversation, "changed", mode: "queue", idempotency_key: "event-2")
    end
    assert_equal [409, "idempotency_envelope_mismatch"], [error.status, error.code]
    assert_equal 1, api.inputs.length
    assert_equal "event-2", api.writes.last.last
  end

  def test_omitting_the_key_keeps_independent_random_keys_for_each_write
    api = RhoTest::ReceiptApi.new
    core = connected_core(api)

    2.times { core.open_conversation(prompt: "hello", model: "dev/mock-text") }
    2.times { core.open_conversation }
    2.times { core.say("c-1", "hello") }

    keys = api.writes.map(&:last)
    assert_equal 8, keys.length
    assert_equal keys.length, keys.uniq.length
    keys.each { |key| assert_match(/\A[0-9a-f-]{36}\z/, key) }
    assert_equal 4, api.conversation_creates.length
    assert_equal 4, api.inputs.length
  end

  private

    def connected_core(api)
      now = Time.now
      daemon = member_ready(boot(realtime_factory: ->(*) { nil },
        clock: -> { now }, sleeper: ->(_) { now += Rho::Daemon::HostFollowers::MATERIALIZATION_WAIT }), api)
      Rho::Core.new(home: daemon.home)
    end
end
