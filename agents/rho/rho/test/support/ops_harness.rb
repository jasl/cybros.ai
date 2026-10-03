module RhoTest
  # Shared daemon setup and loop requests for the Ops route tests.
  module OpsHarness
    include DaemonHarness

    def boot(extensions: [Rho::Extensions::Ops], config: agent_mode, **options) = super(extensions:, config:, **options)

    def create(daemon, body)
      response = request(daemon, :post, "/loops", token: bearer(daemon), body: body)
      [response.code, JSON.parse(response.body)]
    end

    def store = host_store
  end
end
