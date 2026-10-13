require "test_helper"

# The budget-open path (item 6): the configure-once cost unit and the
# admin-opened windowed balance — the two halves that turn priced
# admission's soft guard from uncapped into the hard stop.
class API::V1::AdminBudgetsTest < ActionDispatch::IntegrationTest
  setup do
    @admin = create_access_token_fixture(user: users(:owner), name: "Ops", plane: :platform)
    @member_token = create_access_token_fixture(user: users(:member), name: "M")
  end

  test "the cost unit configures once, replays quietly, and refuses a rewrite" do
    put "/api/v1/admin/account/cost_unit", headers: bearer(@admin),
      as: :json, params: { account: { cost_unit: "USD" } }
    assert_response :success
    assert_equal "USD", response.parsed_body.dig("account", "cost_unit")

    put "/api/v1/admin/account/cost_unit", headers: bearer(@admin),
      as: :json, params: { account: { cost_unit: "USD" } }
    assert_response :success, "a same-value replay is already-configured"

    put "/api/v1/admin/account/cost_unit", headers: bearer(@admin),
      as: :json, params: { account: { cost_unit: "EUR" } }
    assert_response :conflict
    assert_equal "cost_unit_conflict", response.parsed_body.dig("error", "code")
  end

  test "a budget opens once per key, replays the standing budget, and conflicts on divergence" do
    configure_unit
    post budgets_path, headers: bearer(@admin).merge("Idempotency-Key" => "aug"),
      as: :json, params: open_payload("25.00")
    assert_response :created
    body = response.parsed_body.fetch("budget")
    assert_equal "25.0", body["credited_amount"]
    assert_equal "USD", body["cost_unit"]
    public_id = body.fetch("public_id")

    post budgets_path, headers: bearer(@admin).merge("Idempotency-Key" => "aug"),
      as: :json, params: open_payload("25.00")
    assert_response :created
    assert_equal public_id, response.parsed_body.dig("budget", "public_id"),
      "an exact replay is the standing budget"
    assert_equal 1, UsageBudget.count

    post budgets_path, headers: bearer(@admin).merge("Idempotency-Key" => "aug"),
      as: :json, params: open_payload("99.00")
    assert_response :conflict
    assert_equal "idempotency_envelope_mismatch", response.parsed_body.dig("error", "code")
  end

  test "window stamps parse in the app zone and render at second precision" do
    configure_unit
    post budgets_path, headers: bearer(@admin).merge("Idempotency-Key" => "zone"),
      as: :json, params: { budget: { amount: "25.00", starts_at: "2026-01-01T10:00:00" } }
    assert_response :created
    assert_equal "2026-01-01T10:00:00Z", response.parsed_body.dig("budget", "starts_at")
    assert_nil response.parsed_body.dig("budget", "expires_at")
  end

  test "an unconfigured unit and an overlapping window refuse typed" do
    post budgets_path, headers: bearer(@admin).merge("Idempotency-Key" => "k1"),
      as: :json, params: open_payload("25.00")
    assert_response :unprocessable_entity
    assert_equal "account_unit_unconfigured", response.parsed_body.dig("error", "code")

    configure_unit
    post budgets_path, headers: bearer(@admin).merge("Idempotency-Key" => "k2"),
      as: :json, params: open_payload("25.00")
    assert_response :created

    post budgets_path, headers: bearer(@admin).merge("Idempotency-Key" => "k3"),
      as: :json, params: open_payload("10.00")
    assert_response :conflict
    assert_equal "budget_window_overlap", response.parsed_body.dig("error", "code")
  end

  test "a float amount and a missing key are refused before any write" do
    configure_unit
    post budgets_path, headers: bearer(@admin).merge("Idempotency-Key" => "k"),
      as: :json, params: { budget: { amount: 25.5, starts_at: Time.current.iso8601 } }
    assert_response :unprocessable_entity, "floats never carry money"

    post budgets_path, headers: bearer(@admin), as: :json, params: open_payload("25.00")
    assert_response :bad_request
    assert_equal "idempotency_key_required", response.parsed_body.dig("error", "code")
    assert_equal 0, UsageBudget.count
  end

  # The item-6 review's 500 hunt: every column bound answers typed, and an
  # amount finer than the ledger's scale is refused rather than silently
  # rounded into a phantom conflict on its own exact replay.
  test "unbounded inputs refuse typed instead of escaping as driver errors" do
    configure_unit

    post budgets_path, headers: bearer(@admin).merge("Idempotency-Key" => "k" * 65),
      as: :json, params: open_payload("25.00")
    assert_response :unprocessable_entity, "an overlong operation key is invalid, never a 500"

    post budgets_path, headers: bearer(@admin).merge("Idempotency-Key" => "k"),
      as: :json, params: { budget: { amount: "25.00", starts_at: 1.minute.ago.iso8601,
                                     reason: "r" * 300 } }
    assert_response :unprocessable_entity

    post budgets_path, headers: bearer(@admin).merge("Idempotency-Key" => "k2"),
      as: :json, params: open_payload("1#{"0" * 30}")
    assert_response :unprocessable_entity, "past numeric(38,18) is refused, not overflowed"

    post budgets_path, headers: bearer(@admin).merge("Idempotency-Key" => "k3"),
      as: :json, params: open_payload("0.0000000000000000005")
    assert_response :unprocessable_entity,
      "finer than scale 18 would round at insert and phantom-conflict its own replay"

    post budgets_path,
      headers: bearer(@admin).merge("Idempotency-Key" => "settle:#{SecureRandom.uuid_v7}"),
      as: :json, params: open_payload("25.00")
    assert_response :unprocessable_entity,
      "the settle namespace is the machine's: a planted key would swallow a receipt's charge"
    assert_equal 0, UsageBudget.count
  end

  test "a member credential is not an administrator" do
    post budgets_path, headers: bearer(@member_token).merge("Idempotency-Key" => "k"),
      as: :json, params: open_payload("25.00")
    assert_response :unauthorized, "a member-plane token does not even authenticate here"

    put "/api/v1/admin/account/cost_unit", headers: bearer(@member_token),
      as: :json, params: { account: { cost_unit: "USD" } }
    assert_response :unauthorized
  end

  test "the opened budget is what admission's guard reads" do
    configure_unit
    post budgets_path, headers: bearer(@admin).merge("Idempotency-Key" => "k"),
      as: :json, params: open_payload("0")
    assert_response :created

    DevModelLane.ensure_enabled!(accounts(:cybros))
    selection = DevModelLane.selection(
      workload: "text_generation", account: accounts(:cybros),
      model: DevModelLane::PRICED_TEXT_MODEL
    )
    inference_request = InferenceRequest.create!(
      account: accounts(:cybros), workspace: workspaces(:shared), creating_user: users(:member),
      workload: selection.workload
    )
    invocation = DevModelLane.create_invocation!(inference_request: inference_request, selection: selection)
    seal = ContentBodies::Replace.call(
      owner: invocation.inference_request, role: InferenceRequests::Create::BODY_ROLE,
      entries: Nexus::InputEntries.for("say hi"), seal: true
    )
    assert seal.accepted?
    ModelInvocations::AdmitQueuedWork.call

    invocation.reload
    assert_equal "failed", invocation.status
    assert_equal "budget_exhausted", invocation.failure_reason_key,
      "a zero-credit window is the hard stop, end to end"
  end

  # THE GATE OWNS `administrator_required`, so by the time the action runs the
  # caller IS an administrator — and the service's `:not_authorized` can only
  # mean the TARGET side failed: an Agent member whose steward is someone
  # else, or a Human member already removed. Rendering `administrator_required`
  # there told an administrator to become what they already are; the plane's
  # own word for a target that cannot be acted on is `user_not_administrable`,
  # decided for removals (2026-07-30 round, admin-users.md) and reused here.
  test "a removed member's budget refusal names the target, not the caller's role" do
    configure_unit
    post "/api/v1/admin/users/#{users(:member).public_id}/removal", headers: bearer(@admin)
    assert_response :success

    post "/api/v1/admin/users/#{users(:member).public_id}/budgets",
      headers: bearer(@admin).merge("Idempotency-Key" => "gone"),
      as: :json, params: open_payload("10.00")

    assert_response :forbidden
    assert_equal "user_not_administrable", response.parsed_body.dig("error", "code")
  end

  test "an agent's budget belongs to its steward, and the refusal says which fact failed" do
    configure_unit
    users(:curator).update!(role: "admin")
    second_admin = create_access_token_fixture(user: users(:curator), name: "Ops2", plane: :platform)

    post "/api/v1/admin/users/#{users(:agent).public_id}/budgets",
      headers: bearer(second_admin).merge("Idempotency-Key" => "stew"),
      as: :json, params: open_payload("10.00")

    assert_response :forbidden
    assert_equal "user_not_administrable", response.parsed_body.dig("error", "code"),
      "an administrator who is not this agent's steward lacks a relationship, not a role"
  end

  # THE ADJUST DOOR: a credit appends an attributed entry and moves the head in one transaction; the
  # key is the ledger's operation key — an exact replay reads the same entry, a divergent payload
  # conflicts — and a debit past the headroom refuses.
  test "a budget adjusts under its key, replays the same entry, and refuses a debit past its headroom" do
    configure_unit
    budget_id = open_budget("25.00")

    patch budget_path(budget_id), headers: bearer(@admin).merge("Idempotency-Key" => "adj-1"),
      as: :json, params: { budget: { kind: "credit", amount: "5.00", reason: "top-up" } }
    assert_response :success
    assert_equal "30.0", response.parsed_body.dig("budget", "credited_amount")
    entry = response.parsed_body.fetch("entry")
    assert_equal ["credit_adjustment", "5.0", "top-up", 2], entry.values_at("kind", "amount", "reason", "sequence")

    patch budget_path(budget_id), headers: bearer(@admin).merge("Idempotency-Key" => "adj-1"),
      as: :json, params: { budget: { kind: "credit", amount: "5.00", reason: "top-up" } }
    assert_response :success
    assert_equal 2, response.parsed_body.dig("entry", "sequence"), "an exact replay is the standing entry"
    assert_equal "30.0", response.parsed_body.dig("budget", "credited_amount"), "and moved nothing twice"

    patch budget_path(budget_id), headers: bearer(@admin).merge("Idempotency-Key" => "adj-1"),
      as: :json, params: { budget: { kind: "debit", amount: "5.00" } }
    assert_response :conflict
    assert_equal "idempotency_envelope_mismatch", response.parsed_body.dig("error", "code")

    patch budget_path(budget_id), headers: bearer(@admin).merge("Idempotency-Key" => "adj-2"),
      as: :json, params: { budget: { kind: "debit", amount: "31.00" } }
    assert_response :conflict
    assert_equal "budget_insufficient_headroom", response.parsed_body.dig("error", "code")

    patch budget_path(budget_id), headers: bearer(@admin).merge("Idempotency-Key" => "adj-3"),
      as: :json, params: { budget: { kind: "refund", amount: "1.00" } }
    assert_response :unprocessable_entity, "a kind outside credit | debit is invalid, never a 500"

    patch budget_path(budget_id), headers: bearer(@admin),
      as: :json, params: { budget: { kind: "credit", amount: "1.00" } }
    assert_response :bad_request
    assert_equal "idempotency_key_required", response.parsed_body.dig("error", "code")

    patch budget_path(SecureRandom.uuid_v7), headers: bearer(@admin).merge("Idempotency-Key" => "adj-4"),
      as: :json, params: { budget: { kind: "credit", amount: "1.00" } }
    assert_response :not_found, "a budget the target does not hold is absence"
  end

  # THE REVOKE DOOR: the single-transition freeze — new admissions stop, entries stand — replayed by
  # its stored key and reason; a second key on a revoked budget says so, a credit afterwards stays
  # legal.
  test "a budget revokes once under its key, replays, and a second key reads already_revoked" do
    configure_unit
    budget_id = open_budget("25.00")

    post "#{budget_path(budget_id)}/revocation", headers: bearer(@admin).merge("Idempotency-Key" => "rev-1"),
      as: :json, params: { revocation: { reason: "misuse" } }
    assert_response :success
    assert_not_nil response.parsed_body.dig("budget", "revoked_at")
    assert_equal "misuse", UsageBudget.find_by!(public_id: budget_id).revoke_reason

    post "#{budget_path(budget_id)}/revocation", headers: bearer(@admin).merge("Idempotency-Key" => "rev-1"),
      as: :json, params: { revocation: { reason: "misuse" } }
    assert_response :success, "the same key and reason replay the standing row"

    post "#{budget_path(budget_id)}/revocation", headers: bearer(@admin).merge("Idempotency-Key" => "rev-1"),
      as: :json, params: { revocation: { reason: "other" } }
    assert_response :conflict
    assert_equal "idempotency_envelope_mismatch", response.parsed_body.dig("error", "code")

    post "#{budget_path(budget_id)}/revocation", headers: bearer(@admin).merge("Idempotency-Key" => "rev-2")
    assert_response :conflict
    assert_equal "budget_already_revoked", response.parsed_body.dig("error", "code")

    patch budget_path(budget_id), headers: bearer(@admin).merge("Idempotency-Key" => "adj-9"),
      as: :json, params: { budget: { kind: "credit", amount: "1.00" } }
    assert_response :success, "deficit repair credits a revoked budget"

    post "#{budget_path(budget_id)}/revocation", headers: bearer(@admin)
    assert_response :bad_request
    assert_equal "idempotency_key_required", response.parsed_body.dig("error", "code")
  end

  # An Agent member's budget is administered by its steward on every door.
  test "adjust and revoke refuse an agent's budget to an administrator who is not its steward" do
    configure_unit
    steward = create_access_token_fixture(user: users(:owner), name: "Steward", plane: :platform)
    post "/api/v1/admin/users/#{users(:agent).public_id}/budgets",
      headers: bearer(steward).merge("Idempotency-Key" => "agent-open"), as: :json, params: open_payload("10.00")
    assert_response :created
    budget_id = response.parsed_body.dig("budget", "public_id")
    users(:curator).update!(role: "admin")
    second_admin = create_access_token_fixture(user: users(:curator), name: "Ops2", plane: :platform)
    agent_budget = "/api/v1/admin/users/#{users(:agent).public_id}/budgets/#{budget_id}"

    patch agent_budget, headers: bearer(second_admin).merge("Idempotency-Key" => "adj-s"),
      as: :json, params: { budget: { kind: "credit", amount: "1.00" } }
    assert_response :forbidden
    assert_equal "user_not_administrable", response.parsed_body.dig("error", "code")

    post "#{agent_budget}/revocation", headers: bearer(second_admin).merge("Idempotency-Key" => "rev-s")
    assert_response :forbidden
    assert_equal "user_not_administrable", response.parsed_body.dig("error", "code")
    assert_nil UsageBudget.find_by!(public_id: budget_id).revoked_at
  end

  private

    def budget_path(public_id) = "#{budgets_path}/#{public_id}"

    def open_budget(amount)
      post budgets_path, headers: bearer(@admin).merge("Idempotency-Key" => "open-#{amount}"),
        as: :json, params: open_payload(amount)
      assert_response :created
      response.parsed_body.dig("budget", "public_id")
    end

    def budgets_path
      "/api/v1/admin/users/#{users(:member).public_id}/budgets"
    end

    # ONE `starts_at` FOR THE WHOLE TEST, and that is the point of the helper.
    # It read `1.minute.ago.iso8601` on every call, so two posts meant to be an
    # EXACT idempotent replay carried different payloads whenever they landed
    # either side of a second boundary — and the envelope, correctly, called
    # that a mismatch. The test then failed on its own timing rather than on
    # anything the code did. Frozen per test run: a replay is only a replay if
    # the bytes are the same.
    def open_payload(amount)
      @open_starts_at ||= 1.minute.ago.iso8601
      { budget: { amount: amount, starts_at: @open_starts_at } }
    end

    def bearer(fixture)
      { "Authorization" => "Bearer #{fixture.secret}" }
    end

    def configure_unit
      put "/api/v1/admin/account/cost_unit", headers: bearer(@admin),
        as: :json, params: { account: { cost_unit: "USD" } }
      assert_response :success
    end
end
