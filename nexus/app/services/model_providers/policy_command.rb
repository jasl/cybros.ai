module ModelProviders
  # The provider-policy command skeleton: every mutation supplies the
  # expected lock_version. The overlay is plain data validated by its reader,
  # so no digest echo rides the write path.
  class PolicyCommand
    Result = Data.define(:outcome, :policy) do
      def done? = %i[applied noop].include?(outcome)
      def blocked? = !done?
    end

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(account:, provider_id:, expected_lock_version:)
      @account = account
      @provider_id = provider_id.to_s
      @expected_lock_version = expected_lock_version
    end

    def call
      return Result.new(outcome: :invalid, policy: nil) unless valid_before_transaction?

      ModelProviderPolicy.transaction do
        policy = ModelProviderPolicy.lock.find_by(account_id: @account.id, provider_id: @provider_id)
        policy ? mutate(policy) : create_row
      end
    end

    private

    def valid_before_transaction?
      @provider_id.present? && @provider_id.length <= ModelProviderPolicy::PROVIDER_ID_MAX_LENGTH
    end

    # The caller's version rides on the row: a same-value replay changes
    # nothing (no write, no bump), and a changed row saves under the
    # optimistic CAS that version fences, so a stale caller loses.
    def mutate(policy)
      return Result.new(outcome: :stale, policy: nil) if @expected_lock_version.nil?

      policy.lock_version = @expected_lock_version
      apply_change(policy)
      return Result.new(outcome: :noop, policy: policy) unless policy.changed?

      if policy.save
        Result.new(outcome: :applied, policy: policy)
      else
        Result.new(outcome: :invalid, policy: nil)
      end
    rescue ActiveRecord::StaleObjectError
      Result.new(outcome: :stale, policy: nil)
    end

    # Commands that author a lane opt into creation; other verbs need its anchor.
    def create_row
      Result.new(outcome: :not_found, policy: nil)
    end

    def create_policy(**attributes)
      return Result.new(outcome: :stale, policy: nil) unless @expected_lock_version.nil?

      policy = ModelProviderPolicy.create_or_find_by(account: @account, provider_id: @provider_id) do |row|
        row.assign_attributes(model_overrides: ModelProviderPolicy.empty_overrides, **attributes)
      end
      if !policy.persisted?
        Result.new(outcome: :invalid, policy: nil)
      elsif policy.previously_new_record?
        Result.new(outcome: :applied, policy: policy)
      else
        mutate(policy)
      end
    end

    def apply_change(policy)
      raise NotImplementedError
    end
  end
end
