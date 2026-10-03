require "test_helper"

# The item's contract: a closed type vocabulary, a positive OneShot-local
# sequence the database arbitrates, and the same bounded-canonical payload
# rule as the envelope.
class OneShotEventItemTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @one_shot = build_one_shot
    @event = OneShotEvent.create!(
      account: @account, one_shot: @one_shot,
      idempotency_key: SecureRandom.uuid_v7
    )
  end

  test "the type vocabulary refuses strangers, tool types included" do
    refute_predicate build_item(item_type: "vanished"), :valid?
    # The agent loop's types return with the agent loop, not before.
    refute_predicate build_item(item_type: "tool_call_started"), :valid?
    assert_predicate build_item(item_type: "text_delta"), :valid?
  end

  test "the sequence is positive and unique per OneShot" do
    refute_predicate build_item(sequence: 0), :valid?
    build_item(sequence: 1).save!

    assert_raises(ActiveRecord::RecordNotUnique) { build_item(sequence: 1).save! }

    other = build_one_shot
    other_event = OneShotEvent.create!(
      account: @account, one_shot: other,
      idempotency_key: SecureRandom.uuid_v7
    )
    assert build_item(one_shot: other, one_shot_event: other_event, sequence: 1).save!,
      "sequences are OneShot-local"
  end

  test "identity and position are frozen after insert" do
    item = build_item(sequence: 1).tap(&:save!)

    assert_raises(ActiveRecord::ReadonlyAttributeError) { item.update!(sequence: 2) }
    assert_raises(ActiveRecord::ReadonlyAttributeError) { item.update!(item_type: "result") }
  end

  test "the payload is bounded" do
    refute_predicate build_item(payload: { "text" => "y" * 70_000 }), :valid?
  end

  private

    def build_one_shot
      OneShot.create!(
        account: @account, workspace: workspaces(:shared), creating_user: users(:member),
        workload: "text_generation"
      )
    end

    def build_item(one_shot: @one_shot, one_shot_event: @event, sequence: 1, **overrides)
      OneShotEventItem.new(
        account: @account, one_shot: one_shot, one_shot_event: one_shot_event,
        sequence: sequence, item_type: "run_status", payload: {},
        occurred_at: Time.current, **overrides
      )
    end
end
