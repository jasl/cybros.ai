module Rho
  # The terminal connection ceremony uses the same application grant as the
  # browser. Its Human credential is a separate operator session; Connection
  # only receives the Agent and Runner lineages it knows how to install.
  class ApplicationConnection
    def self.runtime_credentials(grant)
      grant.agent || grant.runner || raise(ConnectionError, "The login did not include a runtime connection")
    end

    def initialize(home:, public_url: home.base_url, transport: nil, clock: -> { Time.now })
      @home, @clock = home, clock
      @login = CybrosAgent::ApplicationOAuth::Client.new(base_url: home.base_url, public_url: public_url, transport: transport)
      @runtime = CybrosAgent::DeviceFlow::Client.new(base_url: home.base_url,
        client_id: CybrosAgent::ApplicationOAuth::Client::CLIENT_ID, transport: transport)
    end

    def request_authorization(**claims) = @login.request_authorization(**claims)
    def request_runner_authorization(**claims) = @login.request_runner_authorization(**claims)
    def cancel_authorization(authorization) = @login.cancel_authorization(authorization)
    def rotate(refresh_token:) = @runtime.rotate(refresh_token: refresh_token)
    def revoke(token:) = @runtime.revoke(token: token)

    def human_credential
      @human ||= CybrosAgent::Credentials.load(authority: @login,
        store: StateFile.new(@home.operator_credentials_path), clock: @clock)
      raise CybrosAgent::Credentials::PlaneUnavailable, "Sign in with rho connect before managing Nexus" unless @human

      @human.platform_credential
    end

    def await_credentials(authorization) = @login.await_credentials(authorization)

    def accept_human(grant)
      @human = CybrosAgent::Credentials::OAuth.issue(credentials: grant, authority: @login,
        store: StateFile.new(@home.operator_credentials_path), clock: @clock)
    end
  end
end
