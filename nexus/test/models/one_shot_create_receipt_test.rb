require "test_helper"

# Replay evidence for one accepted create. The receipt is controller-adjacent, so the danger is not
# that it stores too little but that it stores something a caller said: a replay is only trustworthy
# while every fact in it was derived from the durable target.
class OneShotCreateReceiptTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @creator = users(:member)
  end

  def create_one_shot(workload: "text_generation")
    OneShot.create!(
      account: @account, workspace: @workspace, creating_user: @creator,
      workload: workload
    )
  end

  def create_receipt(one_shot: create_one_shot, **overrides)
    OneShotCreateReceipt.create!(
      **{ one_shot: one_shot, idempotency_key: SecureRandom.uuid,
          request_digest: SecureRandom.hex(32) }.merge(overrides)
    )
  end

  test "the accepted result is derived from the target, and a caller's cannot survive" do
    one_shot = create_one_shot

    receipt = create_receipt(
      one_shot: one_shot,
      result: { "one_shot_public_id" => "someone-elses", "http_status" => 201 }
    )

    assert_equal(
      { "one_shot_public_id" => one_shot.public_id.to_s, "workload" => one_shot.workload },
      receipt.result
    )
  end

  test "the replay scope is derived from the target too" do
    one_shot = create_one_shot

    receipt = create_receipt(
      one_shot: one_shot,
      account: Account.new(name: "Wrong"), workspace: workspaces(:personal),
      acting_user: users(:owner), workload: "embedding"
    )

    assert_equal one_shot.account, receipt.account
    assert_equal one_shot.workspace, receipt.workspace
    assert_equal one_shot.creating_user, receipt.acting_user
    assert_equal one_shot.workload, receipt.workload
  end

  # A rendered response would rot the moment the adapter changed; the target's
  # locator plus its workload is everything an adapter needs to render again.
  test "the result carries no HTTP fact" do
    assert_equal %w[one_shot_public_id workload], create_receipt.result.keys.sort
  end

  test "one OneShot has at most one receipt" do
    one_shot = create_one_shot
    create_receipt(one_shot: one_shot)

    assert_raises ActiveRecord::RecordNotUnique do
      create_receipt(one_shot: one_shot)
    end
  end

  test "one scoped key is reserved once" do
    key = SecureRandom.uuid
    create_receipt(idempotency_key: key)

    assert_raises ActiveRecord::RecordNotUnique do
      create_receipt(idempotency_key: key)
    end
  end

  # The item-6 re-scope: the key belongs to the CALLER in the workspace,
  # never to a workload — the digest arbitrates payload divergence, and a
  # second row under the same key would be the duplicate the index exists
  # to make impossible.
  test "the same key is one reservation whatever the workload" do
    key = SecureRandom.uuid
    create_receipt(idempotency_key: key)

    assert_raises ActiveRecord::RecordNotUnique do
      create_receipt(one_shot: create_one_shot(workload: "embedding"), idempotency_key: key)
    end
  end

  test "the recorded evidence is write-once" do
    receipt = create_receipt

    assert_raises ActiveRecord::ReadonlyAttributeError do
      receipt.update(request_digest: SecureRandom.hex(32))
    end
    assert_raises ActiveRecord::ReadonlyAttributeError do
      receipt.update(result: { "one_shot_public_id" => "moved" })
    end
  end
end
