module ModelInvocations
  # Which host/transport pair may serve a prepared attempt, derived from
  # the profile and the closed host-to-transport map. A gate, not a status.
  module ExecutionClaim
    # No fallback delay: the start CAS is the race handling, and a runner earns
    # primacy by listening faster.

    class << self
      # Two levels before IO: the pair the platform implements, and the pair
      # this profile declared it can serve.
      def pair_allowed?(profile:, host:)
        transport = ExecutionAdapter.transport_for(host)
        return false if transport.nil?

        profile.allowed_execution_pairs.any? do |pair|
          pair.execution_host_kind == host && pair.http_transport_kind == transport
        end
      end
    end
  end
end
