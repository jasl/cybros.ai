module DeviceAuthorizations
  # Issues the one-time raw device secret and persists only its digest. The
  # Active Record model owns row integrity and lifecycle transitions; this
  # narrow workflow owns secret generation and collision retry.
  class Issue
    USER_CODE_GENERATION_ATTEMPTS = 5

    Result = Data.define(:authorization, :device_code)

    class << self
      def call(...)
        new(...).call
      end

      private

        def generate_user_code
          Array.new(DeviceAuthorization::USER_CODE_LENGTH) do
            index = SecureRandom.random_number(DeviceAuthorization::USER_CODE_ALPHABET.length)
            DeviceAuthorization::USER_CODE_ALPHABET[index]
          end.join
        end
    end

    # Branch B's kind defaults to the runner's; an Agent request carries none.
    # The combined shape (both sets) fixes the runner's kind AND its private
    # scope here, at issuance: the in-process runner is always private (shared
    # capacity runs separately, on a runner-mode registration), so the scope
    # never changes hands at Connect and the scope-change validation never
    # sees this shape.
    def initialize(account:, agent_identifier: nil, agent_display_name: nil,
                   requested_executor_display_name: nil,
                   runner_identifier: nil, runner_display_name: nil,
                   requested_executor_kind: nil,
                   request_ip: nil, request_user_agent: nil)
      @account = account
      @agent_identifier = agent_identifier
      @agent_display_name = agent_display_name
      @requested_executor_display_name = requested_executor_display_name
      @runner_identifier = runner_identifier
      @runner_display_name = runner_display_name
      @requested_executor_kind = requested_executor_kind ||
        (TaskExecutor::MACHINE_KINDS.first if runner_identifier)
      @selected_assignment_scope = ("user_private" if agent_identifier && runner_identifier)
      @request_ip = request_ip
      @request_user_agent = request_user_agent
    end

    def call
      attempts = 0
      begin
        parts = DeviceAuthorization::DIGESTED.mint_parts
        authorization = DeviceAuthorization.create!(
          account: @account,
          client_id: OAuth::DEVICE_CLIENT_ID,
          agent_identifier: @agent_identifier,
          agent_display_name: @agent_display_name,
          requested_executor_display_name: @requested_executor_display_name,
          runner_identifier: @runner_identifier,
          runner_display_name: @runner_display_name,
          requested_executor_kind: @requested_executor_kind,
          selected_assignment_scope: @selected_assignment_scope,
          device_code_lookup_id: parts.lookup_id,
          device_code_digest: parts.digest,
          user_code: self.class.send(:generate_user_code),
          interval: DeviceAuthorization.default_interval,
          expires_at: DeviceAuthorization::TTL.from_now,
          request_ip: @request_ip,
          request_user_agent: @request_user_agent&.first(255)
        )
        Result.new(authorization: authorization, device_code: parts.raw)
      rescue ActiveRecord::RecordNotUnique
        # A live-code collision retries generation instead of surfacing the
        # storage race to the client.
        attempts += 1
        retry if attempts < USER_CODE_GENERATION_ATTEMPTS
        raise
      end
    end
  end
end
