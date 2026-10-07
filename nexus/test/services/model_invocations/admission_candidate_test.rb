require "test_helper"

# C2-4 A11: what an Invocation would cost at its ceiling, resolved without
# locks so admission can hold its locks for as short a time as possible.
#
# Known-free is the row's own schedule: a complete `catalog_only` formula
# whose every rate is zero. Each of the two conjuncts gets a test that
# removes exactly one of them.
class ModelInvocations::AdmissionCandidateTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @creator = users(:member)
    DevModelLane.ensure_enabled!(@account)
  end

  test "an all-zero catalog_only lane is known free" do
    result = ModelInvocations::AdmissionCandidate.call(invocation: invocation_for("dev/mock-text"))

    assert_predicate result, :accepted?
    assert_predicate result, :known_free?
    assert_equal "admitted_free", result.shape
  end

  test "a model hidden after acceptance is refused at admission" do
    invocation = invocation_for("dev/mock-text")
    policy = ModelProviderConfig.find_by!(account: @account, provider_id: "dev")
    policy.set_model_visibility("dev/mock-text", visible: false)
    policy.save!

    result = ModelInvocations::AdmissionCandidate.call(invocation: invocation)

    assert_equal :model_hidden, result.refusal
  end

  test "a model marked unavailable after acceptance is refused at admission" do
    invocation = invocation_for("dev/mock-text")
    policy = ModelProviderConfig.find_by!(account: @account, provider_id: "dev")
    policy.set_model_availability("dev/mock-text", available: false)
    policy.save!

    result = ModelInvocations::AdmissionCandidate.call(invocation: invocation)

    assert_equal :model_hidden, result.refusal
  end

  # The zero conjunct removed: the same lane with a nonzero rate is priced.
  test "a nonzero rate on the same lane is priced" do
    @account.update!(cost_unit: "USD")

    result = ModelInvocations::AdmissionCandidate.call(
      invocation: invocation_for(DevModelLane::PRICED_TEXT_MODEL)
    )

    assert_predicate result, :accepted?
    assert_not_predicate result, :known_free?
    assert_equal "priced", result.shape
  end

  # The catalog_only conjunct removed: zero rates under a schedule the
  # provider may still report a cost for are a quote, not a fact about the
  # amount — the lane is priced (at zero, until the provider says otherwise).
  test "an all-zero schedule that is not catalog_only stays priced" do
    @account.update!(cost_unit: "USD")
    invocation = invocation_for("dev/mock-text")
    snapshot = ModelCatalog.current
    entry = snapshot.models.fetch("dev/mock-text")
    reported = entry.merge("pricing" => entry.fetch("pricing").merge(
      "schedule" => entry.dig("pricing", "schedule").merge("kind" => "provider_reported_then_catalog_fallback")
    ))
    quoted = snapshot.with(models: snapshot.models.merge("dev/mock-text" => reported))

    result = ModelCatalog.stub(:current, quoted) do
      ModelInvocations::AdmissionCandidate.call(invocation: invocation)
    end

    assert_not_predicate result, :known_free?
    assert_equal "priced", result.shape
  end

  # Free costs nothing in every unit, so an Account that has configured none still reaches the free
  # branch — which is what lets the dev lane run before any unit or budget exists.
  test "known-free needs no Account unit" do
    @account.update!(cost_unit: nil)

    result = ModelInvocations::AdmissionCandidate.call(invocation: invocation_for("dev/mock-text"))

    assert_predicate result, :known_free?
  end

  test "pricing without an Account unit leaves admission unmetered" do
    @account.update!(cost_unit: nil)

    result = ModelInvocations::AdmissionCandidate.call(
      invocation: invocation_for(DevModelLane::PRICED_TEXT_MODEL)
    )

    assert_predicate result, :accepted?
    assert_predicate result, :unmetered?
  end

  test "pricing in a different unit admits without inventing a converted cost" do
    @account.update!(cost_unit: "EUR")
    result = ModelInvocations::AdmissionCandidate.call(invocation: invocation_for(DevModelLane::PRICED_TEXT_MODEL))
    assert_predicate result, :accepted?
    assert_predicate result, :unmetered?
  end

  test "a model that left the catalog refuses rather than quoting from a stale copy" do
    invocation = invocation_for("dev/mock-text")
    ModelInvocation.where(id: invocation.id).update_all(model_ref: "gone")

    result = ModelInvocations::AdmissionCandidate.call(invocation: invocation.reload)

    assert_equal ModelInvocations::AdmissionCandidate::UNKNOWN_MODEL, result.refusal
  end

  private

    def invocation_for(model)
      selection = DevModelLane.selection(
        workload: "text_generation", account: @account, model: model
      )
      inference_request = InferenceRequest.create!(
        account: @account, workspace: workspaces(:shared), creating_user: @creator,
        workload: selection.workload
      )
      DevModelLane.create_invocation!(inference_request: inference_request, selection: selection)
    end
end
