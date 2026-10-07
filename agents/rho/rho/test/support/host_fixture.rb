module RhoTest
  # Stock the two actual owners: Nexus policy and this daemon's follower cache.
  # Reading returns the daemon's verified projection, never a second disk policy.
  class HostFixture
    def initialize(daemon)
      @daemon = daemon
      @cache = daemon.host_followers.send(:store)
    end

    def rows = @cache.rows
    def find(public_id) = @cache.find(public_id)
    def forget(host) = @cache.forget(host)

    def remember(host, workspace:, **fields)
      @cache.remember(host, workspace: workspace, **fields)
      policy_fields = fields.slice(:model, :notes, :code_mode)
      if host.outlives_turn? && policy_fields.any?
        client = @daemon.wire.client(@daemon.lineage.credentials.member_credential)
        hosted = host.context(client.workspace(workspace))
        policy = Rho::HostPolicy.new(store: -> { hosted.store_entries },
          owner_public_id: @daemon.lineage.identity.user_public_id, host_public_id: host.public_id)
          .change(**policy_fields)
        @cache.project(host, policy)
        if policy.notes.key?(Rho::Daemon::HostFollowers::SIDE_NOTE)
          @daemon.wire.api_transport.stock_conversation(host.public_id, side: true)
        end
      end
    end
  end
end
