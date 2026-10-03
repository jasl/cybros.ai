require "test_helper"

# THE FLOOR ROW: one fact per (account, provider), raised never lowered,
# read strictly against the clock. Every case runs the real upsert on the
# real database — `GREATEST` and `ON CONFLICT` are PostgreSQL's words.
# The account is a singleton here (`index_accounts_singleton`), so the
# (account, provider) grain has one witness per provider; the unique index
# and the FK's cascade are the schema's own words.
class ModelProviderRuntimeStateTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @now = DatabaseClock.now
  end

  def floor(until_at, account: @account, provider_id: "openrouter")
    ModelProviderRuntimeState.raise_floor(
      account_id: account.id, provider_id: provider_id, until_at: until_at
    )
  end

  def row(account: @account, provider_id: "openrouter")
    ModelProviderRuntimeState.find_by!(account: account, provider_id: provider_id)
  end

  test "the first word inserts the row" do
    floor(@now + 30)

    assert_in_delta (@now + 30).to_f, row.next_admission_at.to_f, 0.001
    assert_equal 1, ModelProviderRuntimeState.count
  end

  test "an earlier second word keeps the later floor" do
    floor(@now + 60)
    floor(@now + 5)

    assert_in_delta (@now + 60).to_f, row.next_admission_at.to_f, 0.001,
      "a shorter window never replaces a longer one: the later-dated word still binds"
    assert_equal 1, ModelProviderRuntimeState.count, "one row per lane, whatever the provider repeats"
  end

  test "a later second word raises the floor" do
    floor(@now + 5)
    floor(@now + 60)

    assert_in_delta (@now + 60).to_f, row.next_admission_at.to_f, 0.001
  end

  test "floored_at is strict: a floor at exactly now no longer holds" do
    floor(@now + 30, provider_id: "openrouter")
    floor(@now, provider_id: "dev")
    floor(@now - 1, provider_id: "anthropic")

    assert_equal %w[openrouter], ModelProviderRuntimeState.floored_at(@now).pluck(:provider_id)
    assert row.floored?(@now)
    assert_not row(provider_id: "dev").floored?(@now)
    assert_not row(provider_id: "anthropic").floored?(@now)
  end

  test "the provider id is bounded by the policy's own length" do
    state = ModelProviderRuntimeState.new(
      account: @account, provider_id: "x" * (ModelProviderPolicy::PROVIDER_ID_MAX_LENGTH + 1),
      next_admission_at: @now
    )

    assert_not state.valid?
    assert_not ModelProviderRuntimeState.new(account: @account, provider_id: "", next_admission_at: @now).valid?
  end
end
