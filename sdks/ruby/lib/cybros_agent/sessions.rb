module CybrosAgent
  # Password login creates a Human API Session. Credential persistence and
  # logout policy belong to the operator application, never this client.
  class Sessions < Api::BaseClient
    include Platform::Projections

    def initialize(base_url:, transport: nil, request_timeout: DEFAULT_REQUEST_TIMEOUT)
      initialize_dispatch(base_url:, transport:, request_timeout:, credential_provider: -> { nil })
    end

    def create(email:, password:)
      answer = dispatch.call("/api/v1/session", method: :post,
        body: { "email" => email, "password" => password }, success: 201)
      shape(Platform::SessionGrant, answer)
    end
  end
end
