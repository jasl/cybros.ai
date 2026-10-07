module OAuth
  # One input grammar for application login and the original connector. Only
  # the application client may request Human authority or a browser callback.
  class ConnectionRequest
    include ActiveModel::Model

    CONNECTION_FIELDS = %i[
      client_id scope agent_identifier agent_display_name executor_display_name
      registration_identifier runner_display_name executor_kind connection_mode
    ].freeze
    FIELDS = (CONNECTION_FIELDS + %i[
      response_type redirect_uri state code_challenge code_challenge_method
    ]).freeze

    attr_accessor(*FIELDS, :flow)

    validates :client_id, inclusion: { in: [OAuth::DEVICE_CLIENT_ID, OAuth::APPLICATION_CLIENT_ID] }
    validates :connection_mode, inclusion: { in: %w[connect login] }
    validates :agent_identifier, length: { maximum: User::AGENT_IDENTIFIER_MAX_LENGTH }, allow_nil: true
    validates :agent_display_name, length: { maximum: User::DISPLAY_NAME_MAX_LENGTH }, allow_nil: true
    validates :executor_display_name, length: { maximum: TaskExecutor::DISPLAY_NAME_MAX_LENGTH }, allow_nil: true
    validates :registration_identifier, length: { maximum: TaskExecutor::REGISTRATION_IDENTIFIER_MAX_LENGTH }, allow_nil: true
    validates :runner_display_name, length: { maximum: TaskExecutor::DISPLAY_NAME_MAX_LENGTH }, allow_nil: true
    validate :connection_shape
    validate :application_shape
    validate :authorization_code_shape

    def initialize(attributes = {})
      super({ flow: :device_code, connection_mode: "connect" }.merge(attributes))
    end

    def application?
      client_id == OAuth::APPLICATION_CLIENT_ID
    end

    def code_flow?
      flow == :authorization_code
    end

    def issue_attributes
      {
        client_id: client_id,
        agent_identifier: agent_identifier,
        agent_display_name: agent_display_name,
        requested_executor_display_name: executor_display_name,
        registration_identifier: registration_identifier,
        runner_display_name: runner_display_name,
        requested_executor_kind: (executor_kind if registration_identifier),
        connection_mode: connection_mode,
        grant_type: flow.to_s,
        redirect_uri: (redirect_uri if code_flow?),
        code_challenge: (code_challenge if code_flow?),
      }
    end

    def form_attributes
      FIELDS.to_h { |field| [field, public_send(field)] }.compact
    end

    private

      def connection_shape
        agent = agent_identifier.present?
        runner = registration_identifier.present?
        errors.add(:agent_identifier, :blank) unless agent || runner
        if agent
          errors.add(:agent_identifier, :invalid) unless identifier_valid?(agent_identifier)
          errors.add(:agent_display_name, :blank) if agent_display_name.blank?
          errors.add(:executor_display_name, :blank) if executor_display_name.blank?
          errors.add(:executor_kind, :invalid) unless executor_kind.nil? || (runner && executor_kind == "runner")
        elsif agent_display_name.present? || executor_display_name.present?
          errors.add(:agent_identifier, :blank)
        end
        if runner
          errors.add(:registration_identifier, :invalid) unless identifier_valid?(registration_identifier)
          errors.add(:runner_display_name, :blank) if runner_display_name.blank?
          errors.add(:executor_kind, :invalid) unless executor_kind.nil? || TaskExecutor::MACHINE_KINDS.include?(executor_kind)
        elsif runner_display_name.present? || executor_kind.present?
          errors.add(:registration_identifier, :blank)
        end
      end

      def identifier_valid?(value)
        value == value.strip && value.match?(/\A[[:print:]]+\z/)
      end

      def application_shape
        if application?
          errors.add(:scope, :invalid) unless scope.nil? || scope == OAuth::APPLICATION_SCOPE
        elsif connection_mode != "connect" || code_flow?
          errors.add(:client_id, :invalid)
        end
      end

      def authorization_code_shape
        return unless code_flow?

        errors.add(:response_type, :invalid) unless response_type == "code"
        errors.add(:redirect_uri, :invalid) unless redirect_uri && redirect_uri.length <= 2048 && Client.redirect_allowed?(redirect_uri)
        errors.add(:state, :invalid) unless state.present? && state.bytesize <= 512
        errors.add(:code_challenge, :invalid) unless code_challenge&.match?(/\A[A-Za-z0-9_-]{43}\z/)
        errors.add(:code_challenge_method, :invalid) unless code_challenge_method == "S256"
      end
  end
end
