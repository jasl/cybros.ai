require "test_helper"

# The conversation plane's durable append: contiguous conversation-local
# sequences, same-key replay, and the one wire shape both transports share
# — with the lifecycle narrowing speaking THIS plane's vocabulary.
class Event::AppendTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @conversation = Conversation.create!(
      workspace: workspaces(:shared), creating_user: users(:member)
    )
  end

  def append(items:, **kwargs)
    Event::Append.call(host: @conversation, items: items, **kwargs)
  end

  def item(type: "input_accepted", payload: { "k" => "v" })
    { type: type, payload: payload }
  end

  test "sequences are conversation-local, contiguous, and start at 1" do
    append(items: [item, item])
    append(items: [item])

    assert_equal [1, 2, 3],
      @conversation.event_items.order(:sequence).pluck(:sequence)

    other = Conversation.create!(workspace: workspaces(:shared), creating_user: users(:member))
    Event::Append.call(host: other, items: [item])
    assert_equal [1], other.event_items.pluck(:sequence),
      "a fork or sibling starts its own stream at 1"
  end

  test "a same-key append replays the envelope and writes nothing" do
    first = append(items: [item], idempotency_key: "key-1")
    replay = append(items: [item, item], idempotency_key: "key-1")

    assert_equal first.id, replay.id
    assert_equal 1, @conversation.event_items.count
  end

  test "both transports share one shape and the lifecycle narrowing speaks this plane" do
    broadcasts = []
    ActionCable.server.stub(:broadcast, ->(name, message) { broadcasts << [name, message] }) do
      append(items: [item(type: "turn_status", payload: { "status" => "running" })])
      append(items: [item(type: "input_accepted")])
    end

    base = "agent_api:v1:conversation:#{@conversation.public_id}"
    names = broadcasts.map(&:first)
    assert_equal [
      "#{base}:events", "#{base}:lifecycle", "#{base}:events",
    ], names, "turn_status rides both streams; input_accepted the full stream only"

    event = broadcasts.first.last.fetch(:event)
    assert_equal "turn_status", event.fetch(:type)
    assert_equal({ type: "conversation", public_id: @conversation.public_id },
      event.fetch(:resource))
    assert_equal 1, event.fetch(:sequence)
    assert_equal 1, EventItem::ReplayCursor.decode(event.fetch(:cursor)),
      "the cursor is this stream's own prefix over the same sequence"
  end

  test "a standalone loop is a host of the same plane, named on the wire" do
    run = Run.create!(
      workspace: workspaces(:shared), creating_user: users(:member), status: "running",
      approval_mode: "bypass"
    )
    broadcasts = []
    ActionCable.server.stub(:broadcast, ->(name, message) { broadcasts << [name, message] }) do
      Event::Append.call(host: run, items: [item(type: "input_accepted")])
    end

    rendered = broadcasts.sole.last.fetch(:event)
    assert_equal({ type: "run", public_id: run.public_id }, rendered.fetch(:resource))
    assert_equal "agent_api:v1:run:#{run.public_id}:events", broadcasts.sole.first
    assert_equal [1], run.event_items.pluck(:sequence)
    assert_equal 2, run.reload.event_cursor.next_sequence
  end

  test "a host is born with its cursor; a host built outside its creator gets the backstop" do
    created = Conversations::Create.call(Conversations::Create::Command.new(
      workspace: workspaces(:shared), creating_user: users(:member),
      title: nil, metadata: {}, billing_subject: nil
    )).value
    assert_not_nil created.event_cursor, "one row per host aggregate, at create"

    assert_nil @conversation.event_cursor
    append(items: [item])
    assert_equal 2, @conversation.reload.event_cursor.next_sequence
  end

  # Two first appenders on different lanes both insert the cursor: the
  # loser must find the winner's row, not abort its lane.
  test "the cursor race resolves on the unique index" do
    assert_nil @conversation.event_cursor, "the association caches the miss"
    EventCursor.create!(host: @conversation, next_sequence: 7)

    append(items: [item])

    assert_equal [7], @conversation.event_items.pluck(:sequence)
    assert_equal 1, EventCursor.where(host: @conversation).count
  end

  # A loop-locked appender never holds a conversation host's row, so the
  # find-then-create key check can lose to a concurrent same-key append.
  test "the key race returns the existing envelope and writes nothing" do
    first = append(items: [item], idempotency_key: "raced")
    late = Event::Append.new(
      host: @conversation, items: [item, item], idempotency_key: "raced"
    )
    checks = 0
    replayed = late.method(:replayed)
    late.stub(:replayed, -> { (checks += 1) == 1 ? nil : replayed.call }) do
      assert_equal first.id, late.call.id
    end

    assert_equal 1, Event.count
    assert_equal 1, @conversation.event_items.count
    assert_equal 2, @conversation.reload.event_cursor.next_sequence,
      "the loser allocated no sequences"
  end

  test "a refused item takes its envelope with it" do
    oversized = { "blob" => "x" * 2_000_000 }

    assert_raises(ActiveRecord::RecordInvalid) do
      append(items: [item, item(payload: oversized)])
    end
    assert_equal 0, Event.count
    assert_equal 0, EventItem.count
  end
end
