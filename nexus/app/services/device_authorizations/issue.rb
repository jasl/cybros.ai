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
    # An application-bound Runner fixes its private assignment at issuance;
    # Connect cannot widen it and Consume must match an existing binding.
    def initialize(account:, client_id: OAuth::DEVICE_CLIENT_ID,
                   grant_type: "device_code", connection_mode: "connect",
                   redirect_uri: nil, code_challenge: nil, agent_identifier: nil, agent_display_name: nil,
                   requested_executor_display_name: nil,
                   registration_identifier: nil, runner_display_name: nil,
                   requested_executor_kind: nil, assignment_agent_public_id: nil,
                   request_ip: nil, request_user_agent: nil)
      @account = account
      @client_id = client_id
      @grant_type = grant_type
      @connection_mode = connection_mode
      @redirect_uri = redirect_uri
      @code_challenge = code_challenge
      @agent_identifier = agent_identifier
      @agent_display_name = agent_display_name
      @requested_executor_display_name = requested_executor_display_name
      @registration_identifier = registration_identifier
      @runner_display_name = runner_display_name
      @requested_executor_kind = requested_executor_kind ||
        (Executor::MACHINE_KINDS.first if registration_identifier)
      @assignment_agent_public_id = assignment_agent_public_id
      @selected_assignment_scope = ("agent_private" if registration_identifier && (agent_identifier || assignment_agent_public_id))
      @request_ip = request_ip
      @request_user_agent = request_user_agent
    end

    def call
      attempts = 0
      begin
        parts = DeviceAuthorization::DIGESTED.mint_parts
        authorization = DeviceAuthorization.create!(
          account: @account,
          client_id: @client_id,
          grant_type: @grant_type,
          connection_mode: @connection_mode,
          redirect_uri: @redirect_uri,
          code_challenge: @code_challenge,
          agent_identifier: @agent_identifier,
          agent_display_name: @agent_display_name,
          requested_executor_display_name: @requested_executor_display_name,
          registration_identifier: @registration_identifier,
          runner_display_name: @runner_display_name,
          requested_executor_kind: @requested_executor_kind,
          assignment_agent_public_id: @assignment_agent_public_id,
          selected_assignment_scope: @selected_assignment_scope,
          device_code_lookup_id: parts.lookup_id,
          device_code_digest: parts.digest,
          user_code: self.class.send(:generate_user_code),
          interval: DeviceAuthorization.default_interval,
          expires_at: (@grant_type == "authorization_code" ? DeviceAuthorization::CODE_TTL : DeviceAuthorization::TTL).from_now,
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
