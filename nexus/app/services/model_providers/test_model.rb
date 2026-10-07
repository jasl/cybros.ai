module ModelProviders
  # One explicit admin probe followed by an optimistic availability edit. IO
  # owns no policy lock; a newer edit wins over this diagnostic's observation.
  class TestModel
    Result = Data.define(:outcome, :duration_ms, :http_status, :availability_update)

    def self.call(account:, provider_id:, model_ref:, expected_lock_version:)
      probe = TestConnection.call(account: account, provider_id: provider_id, model_ref: model_ref)
      availability_update = :unchanged
      if %i[succeeded model_not_found].include?(probe.outcome)
        change = SetModelAvailability.call(
          account: account, provider_id: provider_id, model_ref: model_ref,
          available: probe.outcome == :succeeded, expected_lock_version: expected_lock_version
        )
        availability_update = change.outcome
      end
      Result.new(**probe.to_h, availability_update: availability_update)
    end
  end
end
