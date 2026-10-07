module CybrosAgent
  # The planes one connection produced. The
  # executor role is a proper subset of the agent-program role, so the gem
  # composes planes from the credentials that actually arrived instead of
  # making every host re-derive which client it is entitled to build:
  #
  #   agent application -> client + executor_client
  #   runner            -> executor_client
  #   combined          -> client + executor_client + runner_client
  #
  # There is no member-only shape: an agent connection always produces its
  # delivery address, so the asymmetry left is a runner's, which
  # is no principal and therefore has no member plane — and, since the inbox
  # rides the executor plane, a runner WORKS with that one client.
  # The combined grant's `runner_client` is a second executor client on the
  # in-process runner's own credential: the same plane, another address.
  Planes = Data.define(:client, :executor_client, :runner_client)

  # Builds the planes a connection result supports. Options apply to whichever
  # clients are constructed.
  def self.planes_for(credentials, base_url:, transport: nil, **options)
    Planes.new(
      client: (
        if credentials.member_plane?
          Client.new(base_url: base_url, credential: credentials.access_token, transport: transport, **options)
        end
      ),
      executor_client: (
        if credentials.executor_plane?
          ExecutorClient.new(
            base_url: base_url, credential: credentials.executor_access_token,
            transport: transport, **options
          )
        end
      ),
      runner_client: (
        if credentials.runner_plane?
          ExecutorClient.new(
            base_url: base_url, credential: credentials.runner_access_token,
            transport: transport, **options
          )
        end
      )
    )
  end
end
