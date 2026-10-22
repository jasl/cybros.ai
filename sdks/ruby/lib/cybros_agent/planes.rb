module CybrosAgent
  # Member and transport remain separate credential planes on one application.
  Planes = Data.define(:client, :executor_client)

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
      )
    )
  end
end
