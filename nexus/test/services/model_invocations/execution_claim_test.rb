require "test_helper"

# C2-4 A16 and A17: the two derived claim gates.
#
# Both exist to be computed rather than stored, so the tests are mostly about
# what is NOT there — no role column, no eligibility state, and no reading of
# the registry at claim time.
class ModelInvocations::ExecutionClaimTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    DevModelLane.ensure_enabled!(@account)
    # The dev text lane is runner-primary and allows the queue pair as its
    # degraded fallback, which is the shape both gates are about.
    @streamed = DevModelLane.selection(
      workload: "text_generation", account: @account
    ).execution_profile
    # Image generation is job-primary: one allowed pair, no grace for anyone.
    @blob = DevModelLane.selection(
      workload: "image_generation", account: @account
    ).execution_profile
  end

  test "a pair must be one the platform implements and one this profile allows" do
    assert described.pair_allowed?(profile: @streamed, host: "model_runner")
    assert described.pair_allowed?(profile: @streamed, host: "solid_queue")

    # Globally legal, but this profile declares only the queue pair.
    assert_not described.pair_allowed?(profile: @blob, host: "model_runner")
    assert described.pair_allowed?(profile: @blob, host: "solid_queue")
  end

  test "an unknown host is refused" do
    assert_not described.pair_allowed?(profile: @streamed, host: "lambda")
  end

  # NOTHING HERE DECIDES WHEN. The gate says which host may serve the work;
  # the start CAS decides who actually gets it. A17's five-second fallback
  # delay lived here and made the only host that exists wait for a runner
  # that does not, so it was deleted rather than tuned.
  test "the module answers which host may serve, never when" do
    assert_not described.respond_to?(:wake_delay_for),
      "a wake delay is a scheduling preference the CAS already settles"
    assert_not described.respond_to?(:claimable?),
      "only the CAS may refuse a claim"
    assert_equal %i[profile host],
      described.method(:pair_allowed?).parameters.map(&:last)
  end

  private

    def described = ModelInvocations::ExecutionClaim
end
