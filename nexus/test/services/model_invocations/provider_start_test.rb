require "test_helper"

# The provider-start claim arbitrates one prepared Attempt and returns the
# ephemeral context Dispatch uses after the transaction commits.
class ModelInvocations::ProviderStartTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    DevModelLane.ensure_enabled!(@account)
    @invocation = create_invocation
    @profile = DevModelLane.profile_for_invocation(@invocation)
    @attempt = create_attempt
  end

  test "a claim starts the attempt and returns the send context" do
    result = start

    assert_predicate result, :started?
    attempt = result.attempt.reload

    assert_predicate attempt, :started?
    assert_equal "running", attempt.status
    assert_equal "pending", attempt.settlement_state
    assert_equal "running", @invocation.reload.status
    assert_equal "model_runner", result.context.host
    assert_equal "http://127.0.0.1:3000/mock_llm", result.context.base_url
    assert_equal @profile.profile_id, result.context.profile.profile_id
  end

  # No secret reaches a row, and the context that holds one does not render
  # itself into a log line. The row carries NOTHING about the credential now —
  # the five snapshot columns were written by every start and read by nothing,
  # and Stage 3 removed them. What matters is that the signer uses this exact
  # resolved credential without rereading mutable state, and that is a
  # property of the context, which is where it is asserted.
  test "the send context carries the credential and the row carries none" do
    result = start

    assert_kind_of ModelInvocations::ProviderStart::SendContext, result.context
    assert_equal "http://127.0.0.1:3000/mock_llm", result.context.base_url
    assert_not_includes result.context.inspect, "credential"
    assert_empty ModelInvocationAttempt.column_names.grep(/credential/),
      "no credential fact belongs on a durable row"
  end

  test "the current profile and endpoint stay in the send context" do
    current = ModelCatalog.current
    provider = current.providers.fetch("dev").merge("base_url" => "http://current.example/v1")
    model = current.models.fetch("dev/mock-text").merge(
      "model_id" => "current-wire-model",
      "wire_options" => { "responses_path" => "/current/responses" }
    )
    catalog = ModelCatalog::Snapshot.new(
      providers: current.providers.merge("dev" => provider),
      models: current.models.merge("dev/mock-text" => model),
      selectors: current.selectors
    ).freeze
    profile = ModelCatalog::ProfileBuilder.call(
      model_ref: "dev/mock-text", provider: provider, model: model
    )

    result = start(catalog: catalog, profile: profile)

    assert_predicate result, :started?
    assert_equal "http://current.example/v1", result.context.base_url
    assert_equal "current-wire-model", result.context.profile.model_pin
    assert_same profile, result.context.profile
    assert_empty ModelInvocationAttempt.column_names &
      %w[provider_endpoint wire_model_id adapter_profile_id]
  end

  test "a passed deadline refuses before any credential is read" do
    @attempt.update!(deadline_at: 1.minute.ago)

    result = start

    assert_equal ModelInvocations::ProviderStart::DEADLINE_PASSED, result.outcome
    assert_not_predicate @attempt.reload, :started?
  end

  test "a provider disabled after profile resolution is still a typed refusal" do
    policy = ModelProviderConfig.find_by!(account: @account, provider_id: "dev")
    policy.update!(enabled: false)

    result = start(profile: @profile)

    assert_equal ModelInvocations::ProviderStart::PROVIDER_DISABLED, result.outcome
    assert_not_predicate @attempt.reload, :started?
  end

  # A16 at the claim: the dev image lane allows only the queue pair, so the
  # streaming host cannot claim it however healthy it is.
  test "a host outside the current profile's allowed pairs cannot claim" do
    invocation = create_invocation(workload: "image_generation")
    attempt = create_attempt(invocation: invocation)

    result = ModelInvocations::ProviderStart.call(
      attempt: attempt, host: "model_runner",
      base_url: ModelCatalog.provider_base_url(invocation.provider_id),
      profile: DevModelLane.profile_for_invocation(invocation)
    )

    assert_equal ModelInvocations::ProviderStart::PAIR_DISALLOWED, result.outcome
  end

  # A17 is an enqueue preference, so an early fallback job is not an error to
  # refuse — it is simply a host that arrived first on a pair its profile
  # allows. A brand-new Attempt claims on the fallback with no waiting.
  test "the fallback host is not held off by any timer" do
    fresh = create_attempt(ordinal: 2)
    fresh.update_columns(created_at: Time.current)

    result = start(attempt: fresh, host: "solid_queue")

    assert_predicate result, :started?
    assert_equal "solid_queue", result.context.host
  end

  # And this is what actually keeps the two hosts apart — the predecessor's
  # mechanism, which needed no timer and no tuned constant.
  test "a started attempt refuses the second host, whichever one it is" do
    assert_predicate start, :started?

    second = start(host: "solid_queue")

    assert_equal ModelInvocations::ProviderStart::ALREADY_STARTED, second.outcome
    assert_equal "model_runner", start_context_host
  end

  # The rung with money behind it, driven through the real cancel kernel
  # rather than a status poke — because the point is that this state is that
  # writer's DESIGNED OUTPUT. It terminalizes the Invocation with a guarded
  # UPDATE and deliberately leaves Attempts alone, so the attempt is still
  # `prepared` and every attempt-shaped guard passes.
  test "a canceled parent refuses the claim instead of being resurrected" do
    ModelInvocation::Cancellation.call(
      scope: ModelInvocation.where(id: @invocation.id), reason: "workspace_archived"
    )
    assert_equal "prepared", @attempt.reload.status,
      "the cancel kernel does not touch attempts; that is why this guard exists"

    result = start

    assert_equal ModelInvocations::ProviderStart::AUTHORITY_LOST, result.outcome
    assert_not_predicate @attempt.reload, :started?
    invocation = @invocation.reload
    assert_equal "canceled", invocation.status, "a terminal invocation stays terminal"
    assert_not_nil invocation.canceled_at
  end

  # A terminal Attempt is refused by the same guard. No writer can produce
  # this yet — cancel and the deadline sweep are both later — but a `running`
  # status written over `timed_out` is not something a later pass can undo,
  # and the guard is the same line either way.
  test "an attempt that left prepared without starting is refused, not resurrected" do
    @attempt.update!(status: "timed_out")

    result = start

    assert_equal ModelInvocations::ProviderStart::NO_LONGER_PREPARED, result.outcome
    assert_equal "timed_out", @attempt.reload.status
    assert_not_predicate @attempt, :started?
  end

  private

    def start(host: "model_runner", attempt: nil, catalog: ModelCatalog.current, profile: nil)
      target = (attempt || @attempt).reload
      provider_id = target.model_invocation.provider_id
      result = ModelInvocations::ProviderStart.call(
        attempt: target, host: host,
        base_url: ModelCatalog.provider_base_url(provider_id, snapshot: catalog),
        profile: profile || DevModelLane.profile_for_invocation(target.model_invocation)
      )
      @start_context_host ||= result.context&.host
      result
    end

    attr_reader :start_context_host

    def create_attempt(invocation: @invocation, ordinal: 1)
      invocation.update!(status: "running") unless invocation.running?
      ModelInvocationAttempt.create!(
        account: @account, model_invocation: invocation,
        ordinal: ordinal, admission_shape: "admitted_free",
        deadline_at: 10.minutes.from_now
      )
    end

    def create_invocation(workload: "text_generation")
      selection = DevModelLane.selection(workload: workload, account: @account)
      inference_request = InferenceRequest.create!(
        account: @account, workspace: workspaces(:shared), creating_user: users(:member),
        workload: selection.workload
      )
      DevModelLane.create_invocation!(inference_request: inference_request, selection: selection)
    end
end
