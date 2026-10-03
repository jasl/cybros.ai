require "test_helper"

# The receipt's identity, money-shape, and immutability contract after the
# Stage 4 item 3 re-cut to the predecessor's shape. Rows here are hand-built
# on purpose: `UsageRecords::Record` is the one production writer, and what
# these tests freeze is what it must satisfy.
class UsageRecordTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    # Pinned so the attempt identity (account, invocation public id, ordinal)
    # actually recurs across builds — the collision under test.
    @invocation_public_id = SecureRandom.uuid_v7
  end

  test "everything is frozen after insert except the settlement flag" do
    record = build_record.tap(&:save!)

    # A finalized receipt is never repriced or re-attributed.
    assert_raises(ActiveRecord::ReadonlyAttributeError) do
      record.update!(cost_amount: 1)
    end
    assert_raises(ActiveRecord::ReadonlyAttributeError) do
      record.update!(status: "failed")
    end

    # The one column the settle batch owns.
    record.update!(spend_settled_at: Time.current)
    assert_predicate record.reload.spend_settled_at, :present?
  end

  test "both identities are unique per account" do
    build_record.save!

    duplicate_key = build_record(attempt_ordinal: 2)
    assert_raises(ActiveRecord::RecordNotUnique) { duplicate_key.save! }

    duplicate_attempt = build_record(idempotency_key: "other")
    assert_raises(ActiveRecord::RecordNotUnique) { duplicate_attempt.save! }
  end

  test "the money shapes follow what admission decided" do
    # Priced: a computed amount, or none when the catalog stopped answering —
    # unknown is null, never a coerced zero.
    assert_predicate build_record(cost_amount: BigDecimal("0.000116886")), :valid?
    assert_predicate build_record(cost_amount: nil, cost_unit: nil, unit_pricing: nil), :valid?
    refute_predicate build_record(cost_amount: BigDecimal("-0.01")), :valid?

    # Admitted-free records exact zero.
    assert_predicate free_record(cost_amount: BigDecimal(0)), :valid?
    refute_predicate free_record(cost_amount: nil), :valid?
    refute_predicate free_record(cost_amount: BigDecimal("0.01")), :valid?

    # Unmetered records tokens with money BLANK: the blank is the declaration, and any money present
    # contradicts it.
    assert_predicate unmetered_record, :valid?
    refute_predicate unmetered_record(cost_amount: BigDecimal(0)), :valid?
    refute_predicate unmetered_record(cost_unit: "USD"), :valid?
    refute_predicate unmetered_record(unit_pricing: { "input_per_mtok" => "1" }), :valid?
  end

  test "the status vocabulary refuses strangers" do
    refute_predicate build_record(status: "vanished"), :valid?
    assert_predicate build_record(status: "discarded", error_code: nil), :valid?
  end

  test "the receipt has no live association besides account" do
    associations = UsageRecord.reflect_on_all_associations.map(&:name)

    assert_equal [:account], associations
  end

  # The receipt carries the provider's request id, the service class, the
  # admission shape and the settle time as columns of its own.
  test "the receipt's settlement facts are columns" do
    assert_empty %w[provider_request_id service_class admission_shape spend_settled_at] - UsageRecord.column_names
  end

  private

    def build_record(**overrides)
      UsageRecord.new(
        account: @account, idempotency_key: "one_shot_attempt-abc123:1",
        model_invocation_public_id: @invocation_public_id, attempt_ordinal: 1,
        consumer_user_public_id: SecureRandom.uuid_v7,
        provider_id: "dev", catalog_model_ref: "dev/text",
        wire_model_id: "text", workload: "text_generation",
        purpose: "one_shot_attempt", service_class: "interactive",
        admission_shape: "priced", status: "succeeded",
        recorded_at: Time.current,
        cost_unit: "USD", cost_amount: BigDecimal("0.0009"),
        **overrides
      )
    end

    def free_record(**overrides)
      build_record(
        admission_shape: "admitted_free", unit_pricing: nil,
        cost_unit: nil, cost_amount: BigDecimal(0), **overrides
      )
    end

    def unmetered_record(**overrides)
      build_record(
        admission_shape: "unmetered", unit_pricing: nil,
        cost_unit: nil, cost_amount: nil, input_tokens: 100, output_tokens: 5,
        **overrides
      )
    end
end
