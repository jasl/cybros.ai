require "test_helper"
require_relative "../../test_helpers/agent_membership_test_helper"

# Canceling proven-unstarted work reverses admission without claiming that provider IO began. Every
# pre-IO ending uses this same transition.
#
# THERE IS NO MONEY IN IT ANY MORE. These tests were mostly about a hold
# moving back exactly once; admission holds nothing after the course
# correction's Stage 1, so what is left is the terminal CAS — which ordinal
# ends, under which word, and who is allowed to end it.
class ModelInvocations::CancelUnstartedTest < ActiveSupport::TestCase
  include AgentMembershipTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    DevModelLane.ensure_enabled!(@account)
    @account.update!(cost_unit: "USD")
  end

  # A pre-IO ending terminalizes the ordinal and returns nothing, because
  # admission holds nothing (course correction Stage 1). One vocabulary, so
  # an operator can tell what ended each ordinal.
  test "an unstarted attempt terminalizes with the caller's class" do
    %w[failed canceled timed_out].each do |status|
      attempt = admit(consumer: @human, payer: @human, model: "dev/mock-text").attempt

      result = release(attempt, terminal_status: status)

      assert_predicate result, :terminalized?
      assert_equal status, attempt.reload.status
      assert_equal "not_applicable", attempt.settlement_state
      assert_not_nil attempt.terminal_at
    end
  end

  test "every admission shape takes the same branch" do
    @account.update!(cost_unit: "USD")
    ["dev/mock-text", "dev/mock-unmetered", DevModelLane::PRICED_TEXT_MODEL].each do |model|
      attempt = admit(consumer: @human, payer: @human, model: model).attempt

      assert_predicate release(attempt, terminal_status: "failed"), :terminalized?
      assert_equal "failed", attempt.reload.status
    end
  end

  # Arriving second is ordinary rather than exceptional: this reports what it
  # found and writes nothing over the first winner's class.
  test "a second caller replays instead of relabelling" do
    attempt = admit(consumer: @human, payer: @human, model: "dev/mock-text").attempt
    release(attempt, terminal_status: "canceled")

    result = release(attempt, terminal_status: "failed")

    assert_predicate result, :replayed?
    assert_equal "canceled", attempt.reload.status, "the first winner keeps its class"
  end

  # An attempt that reached the provider may have been billed; it is closed
  # by the settlement path with a receipt, never quietly relabelled here.
  test "a started attempt is refused" do
    attempt = admit(consumer: @human, payer: @human, model: "dev/mock-text").attempt
    invocation = attempt.model_invocation
    ModelInvocations::ProviderStart.call(
      attempt: attempt, host: "solid_queue",
      base_url: ModelCatalog.provider_base_url(invocation.provider_id),
      profile: DevModelLane.profile_for_invocation(invocation)
    )

    result = release(attempt, terminal_status: "failed")

    assert_equal ModelInvocations::CancelUnstarted::STARTED, result.outcome
    assert_equal "running", attempt.reload.status
  end

  test "an unnamed terminal class is refused rather than guessed" do
    admitted = admit(consumer: @human, payer: @human, model: "dev/mock-text")

    assert_raises(ArgumentError) do
      release(admitted.attempt, terminal_status: "completed")
    end
  end

  private

    def release(attempt, terminal_status:)
      ApplicationRecord.transaction do
        attempt.model_invocation.lock!
        ModelInvocations::CancelUnstarted.call(
          attempt: attempt, terminal_status: terminal_status
        )
      end
    end

    def admit(consumer:, payer:, model: nil)
      invocation = invocation_for(model || DevModelLane::PRICED_TEXT_MODEL)
      quote = ModelInvocations::AdmissionCandidate.call(invocation: invocation)
      ApplicationRecord.transaction do
        PrincipalLocks.descend(consumer, payer)
        invocation.lock!
        ModelInvocations::AdmitUsage.call(
          invocation: invocation, quote: quote, consumer: consumer, payer: payer, ordinal: 1
        )
      end
    end

    def invocation_for(model)
      selection = DevModelLane.selection(
        workload: "text_generation", account: @account, model: model
      )
      one_shot = OneShot.create!(
        account: @account, workspace: workspaces(:shared), creating_user: @human,
        workload: selection.workload
      )
      DevModelLane.create_invocation!(one_shot: one_shot, selection: selection)
    end
end
