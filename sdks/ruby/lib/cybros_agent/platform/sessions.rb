module CybrosAgent
  module Platform
    # Password or browser-approved device login creates a Human API Session. Credential persistence and
    # logout policy belong to the operator application, never this client.
    class Sessions < Api::BaseClient
      include Projections

      def initialize(base_url:, transport: nil, request_timeout: DEFAULT_REQUEST_TIMEOUT)
        transport ||= HttpTransport.new(base_url: base_url)
        @terminal = TerminalLogin.new(base_url: base_url, transport: transport, request_timeout: request_timeout, client_id: "cybros-terminal")
        initialize_dispatch(base_url:, transport:, request_timeout:, credential_provider: -> { nil })
      end

      def create_with_device
        authorization = @terminal.request_login
        yield authorization
        @terminal.await_credentials(authorization)
      end

      def create(email:, password:)
        answer = dispatch.call("/api/v1/session", method: :post,
          body: { "email" => email, "password" => password }, success: 201)
        shape(SessionGrant, answer)
      end

      class TerminalLogin < DeviceFlow::Client
        include Projections

        def request_login
          start_authorization({ client_id: @client_id }, branch: :terminal, executor_kind: nil)
        end

        private

          def initial_credentials(body, branch:)
            grant = shape(SessionGrant, body.merge("token" => body.fetch("access_token")))
            unless grant.session.kind == "api" && !grant.token.empty? && integer(body, "expires_in").positive? &&
                %w[refresh_token plane executor_access_token runner agent].none? { |field| body.key?(field) }
              raise DeviceFlow::AuthorizationLostError, "invalid terminal session"
            end
            grant
          rescue KeyError, NoMethodError, TypeError, Api::MalformedResponse
            raise DeviceFlow::AuthorizationLostError.new("invalid terminal session"), cause: nil
          end
      end
      private_constant :TerminalLogin
    end
  end
end
