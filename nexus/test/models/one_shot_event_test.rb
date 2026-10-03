require "test_helper"

# The internal envelope's contract: its idempotency key is immutable and
# scoped per OneShot.
class OneShotEventTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @one_shot = build_one_shot
  end

  test "identity is frozen after insert" do
    event = build_event.tap(&:save!)

    assert_raises(ActiveRecord::ReadonlyAttributeError) do
      event.update!(idempotency_key: "other")
    end
  end

  test "the key is unique per OneShot and reusable across OneShots" do
    build_event(idempotency_key: "key-1").save!

    assert_raises(ActiveRecord::RecordNotUnique) do
      build_event(idempotency_key: "key-1").save!
    end
    assert build_event(one_shot: build_one_shot, idempotency_key: "key-1").save!
  end

  private

    def build_one_shot
      OneShot.create!(
        account: @account, workspace: workspaces(:shared), creating_user: users(:member),
        workload: "text_generation"
      )
    end

    def build_event(one_shot: @one_shot, **overrides)
      OneShotEvent.new(
        account: @account, one_shot: one_shot,
        idempotency_key: SecureRandom.uuid_v7, **overrides
      )
    end
end
