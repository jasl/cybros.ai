require "test_helper"

# The layered blast-radius brakes, counted from the running set.
#
# They are not fairness — fairness is the rotation's job. These only bound how
# much one provider, one workload, or one owner can occupy at once, which is
# what keeps a runaway agent or a wedged provider from taking the platform.
class ModelInvocations::RunningCapacityTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    DevModelLane.ensure_enabled!(@account)
  end

  # Each brake is isolated, because on a real lane the narrowest one binds
  # first and a test that did not isolate would keep measuring that one.
  test "a provider is available until its declared ceiling is occupied" do
    ceiling = ModelCatalog.provider_concurrency_limit("dev")
    with_workload_headroom do
      (ceiling - 1).times { running_invocation }
      assert available?

      running_invocation
      assert_not available?, "the ceiling counts running work, not reservations"
    end
  end

  # The per-workload limit narrows the provider's own, so one workload cannot
  # take the whole provider even while the provider has room.
  test "a workload is capped under the provider it shares" do
    workload_limit = ModelCatalog.provider_concurrency_limit("dev", workload: "text_generation")
    assert_operator workload_limit, :<, ModelCatalog.provider_concurrency_limit("dev")

    workload_limit.times { running_invocation }

    assert_not available?, "the workload is full"
    assert_operator ModelInvocation.where(status: "running").count, :<,
      ModelCatalog.provider_concurrency_limit("dev"), "while the provider still has room"
  end

  test "one owner cannot occupy the platform" do
    described = ModelInvocations::RunningCapacity
    with_provider_headroom(described::USER_ACTIVE_LIMIT * 2) do
      described::USER_ACTIVE_LIMIT.times { running_invocation }

      assert_not available?
      assert available?(payer_id: users(:owner).id),
        "another owner is unaffected by the first one's brake"
    end
  end

  # The brake is keyed on the payer and counts by the same key: an Agent's work
  # rides its steward's brake, whoever created the row (review gap 20, 2026-09-05).
  test "an agent's running work counts against its steward's brake" do
    described = ModelInvocations::RunningCapacity
    agent = create_agent_member(steward: @human)
    with_provider_headroom(described::USER_ACTIVE_LIMIT * 2) do
      described::USER_ACTIVE_LIMIT.times { running_invocation(creator: agent) }

      assert_not available?(payer_id: @human.id), "the steward pays, so the steward is braked"
      assert available?(payer_id: users(:owner).id), "another steward is unaffected"
    end
  end

  test "a steward's own work and its agents' work share one brake" do
    described = ModelInvocations::RunningCapacity
    agent = create_agent_member(steward: @human)
    with_provider_headroom(described::USER_ACTIVE_LIMIT * 2) do
      (described::USER_ACTIVE_LIMIT - 1).times { running_invocation(creator: agent) }
      assert available?(payer_id: @human.id), "one slot left under the steward's brake"

      running_invocation(creator: @human)

      assert_not available?(payer_id: @human.id), "the steward's own row took the last slot"
    end
  end

  # The terminal transition IS the release: no counter is decremented, so no
  # path can forget to.
  test "terminal work releases its capacity by being terminal" do
    invocations = Array.new(
      ModelCatalog.provider_concurrency_limit("dev", workload: "text_generation")
    ) { running_invocation }
    assert_not available?

    invocations.first.update!(status: "completed", terminal_at: Time.current)

    assert available?, "nothing decremented a counter; the row simply left the running set"
  end

  private

    # Raises the caps a test is NOT about, so each brake is measured alone —
    # on a real lane the narrowest one binds first, and a test that did not
    # isolate would keep re-measuring that one.
    def with_workload_headroom(limit = 1_000, &)
      real = ModelCatalog.method(:provider_concurrency_limit)
      ModelCatalog.stub(:provider_concurrency_limit,
                        lambda { |id, workload: nil, snapshot: ModelCatalog.current|
                          workload ? limit : real.call(id, snapshot: snapshot)
                        }, &)
    end

    def with_provider_headroom(limit = 1_000, &)
      ModelCatalog.stub(
        :provider_concurrency_limit,
        ->(_id, workload: nil, snapshot: ModelCatalog.current) { limit }, &
      )
    end

    def available?(provider_id: "dev", workload: "text_generation", payer_id: nil)
      ModelInvocations::RunningCapacity.available?(
        provider_id: provider_id, workload: workload, payer_id: payer_id || @human.id
      )
    end

    def running_invocation(creator: @human)
      selection = DevModelLane.selection(
        workload: "text_generation", account: @account, model: "dev/mock-text"
      )
      one_shot = OneShot.create!(
        account: @account, workspace: workspaces(:shared), creating_user: creator,
        workload: selection.workload
      )
      DevModelLane.create_invocation!(one_shot: one_shot, selection: selection)
        .tap { |row| row.update!(status: "running") }
    end
end
