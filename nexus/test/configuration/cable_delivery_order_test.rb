require "test_helper"

# THE CABLE DELIVERS ONE STREAM'S MESSAGES IN THE ORDER THEY WERE BROADCAST.
#
# The transcript stream is not durable and carries no sequence: a follower
# joins the deltas in arrival order and the SDK accumulator proves they ARE
# the sealed body. That is only true while the transport keeps the order
# the sink published in, and on Rails main it did not. Solid Cable's
# listener reads a poll's batch by `id` and hands EACH message to
# `ActionCable.server.executor` — the "streamer", a thread POOL of
# `executor_pool_size` threads (Rails' default 10; the older API posted to
# the single event-loop thread) — so two messages read in one poll are
# transmitted by two threads, and whichever wins writes first. The streaming
# journey saw it as `efullyweighing it up car`: the mock's two 18-byte
# reasoning chunks, 40 ms apart, inside one 100 ms poll, swapped on the
# way to the socket — identically on two machines.
#
# The order is a fact about the transport, so it is pinned there:
# `config.action_cable.executor_pool_size = 1` makes the streamer one
# thread, and one thread is FIFO however long a delivery takes. This drives
# the real adapter against the test cable database — the listener thread,
# the batch read, the post — with the first delivery made slow, which is
# what a pool cannot survive and a single thread cannot fail.
class CableDeliveryOrderTest < ActiveSupport::TestCase
  CHANNEL = "cable_delivery_order:#{SecureRandom.hex(4)}".freeze
  CHUNKS = ["weighing it up car", "efully"].freeze
  DELIVERY_WAIT = 10

  setup do
    SolidCable::Message.delete_all
  end

  teardown do
    SolidCable::Message.delete_all
  end

  test "the streamer is one thread, so a poll's batch reaches the socket in id order" do
    assert_equal 1, ActionCable.server.config.executor_pool_size,
      "the transcript stream has no sequence; its order is the streamer's FIFO"
  end

  test "two messages read in one poll are delivered in broadcast order however long the first takes" do
    adapter = ActionCable::SubscriptionAdapter::SolidCable.new(ActionCable.server)
    delivered = Queue.new
    adapter.subscribe(CHANNEL, lambda { |payload|
      # The first delivery is the slow one: on a pool the second message's
      # thread finishes first, on one thread it cannot start yet.
      sleep 0.2 if payload == CHUNKS.first
      delivered << payload
    })

    # ONE statement, so the listener's poll sees both rows or neither —
    # the same batch shape as two broadcasts inside one polling interval,
    # without a window for a poll to fall between them.
    SolidCable::Message.insert_all(CHUNKS.map do |chunk|
      { channel: CHANNEL, payload: chunk, created_at: Time.current,
        channel_hash: SolidCable::Message.channel_hash_for(CHANNEL) }
    end)

    seen = Array.new(CHUNKS.size) { delivered.pop(timeout: DELIVERY_WAIT) }
    assert_equal CHUNKS, seen,
      "the deltas were joined out of order on the way to the socket: #{seen.compact.join.inspect}"
  ensure
    adapter&.shutdown
  end
end
