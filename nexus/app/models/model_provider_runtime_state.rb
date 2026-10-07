# THE PROVIDER'S FACT ABOUT ITS OWN LANE: when a provider answered an
# overloaded status with `Retry-After`, the time it named is a FLOOR on
# admission for this account's lane — every queued invocation on it, not the
# attempt that heard it. One row per (account, provider), the credential's
# grain; written by `ApplyResult` from the header, never computed; read by
# `AdmitQueuedWork`'s candidate query and by the lane presenter as
# `unavailable_until`; cleared by nothing but the clock — a row whose time
# has passed is inert and the next header overwrites it. This admission
# floor comes from the provider; it is not a kernel-imposed execution
# ceiling.
class ModelProviderRuntimeState < ApplicationRecord
  belongs_to :account

  validates :provider_id, presence: true, length: { maximum: ModelProviderConfig::PROVIDER_ID_MAX_LENGTH }

  # The lanes still under a floor at `now`: strict, so a floor at exactly
  # `now` admits — the same edge the requeue's own `next_admission_at: ..now` takes.
  scope :floored_at, ->(now) { where(arel_table[:next_admission_at].gt(now)) }

  # Raises the lane's floor to `until_at` — never lowers it: two attempts that
  # settle together each carry the provider's word, and the later-dated word
  # is the one that still binds. Rung 1 of the ladder (the unique index is the
  # write discipline). IMPLICIT LOCK, recorded for the writer audit (the guard
  # sees locking SELECTs only): ON CONFLICT DO UPDATE holds the conflicting
  # row for the rest of the caller's transaction — acquired after
  # `model_invocations` (ranked) and after the usage rows, last inside
  # ApplyResult's locked block; no other writer takes this row.
  def self.raise_floor(account_id:, provider_id:, until_at:)
    upsert(
      { account_id: account_id, provider_id: provider_id, next_admission_at: until_at },
      unique_by: %i[account_id provider_id],
      on_duplicate: Arel.sql(
        "next_admission_at = GREATEST(model_provider_runtime_states.next_admission_at, EXCLUDED.next_admission_at), " \
        "updated_at = EXCLUDED.updated_at"
      )
    )
  end

  def floored?(now) = next_admission_at > now
end
