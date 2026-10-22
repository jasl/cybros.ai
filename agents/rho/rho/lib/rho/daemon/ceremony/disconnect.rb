module Rho
  class Daemon
    class Ceremony
      # `POST /disconnect`: the two refusals, the count, the
      # revokes, and retirement of the connection through `lose`.
      module Disconnect
        def disconnect
          about = @lineage.credentials
          identity = @lineage.identity
          if about.nil? || identity.nil?
            return Refusal.new(status: 409, code: "not_connected", message: "This daemon holds no connection")
          end

          in_flight = @lineage.runners.sum { |runner| runner.snapshot.in_flight.to_i }
          if in_flight.positive?
            return Refusal.new(status: 409, code: "work_in_flight",
              message: "#{in_flight} tool call(s) are running; stop them or wait before disconnecting")
          end
          result = Rho::Disconnect.call(home: @home, identity: identity, credentials: about,
            executor_client: ->(credential) { @wire.executor_client(credential) }, log: @log)
          adoption = @lineage.lose(about: about)
          @settle.call(adoption, :disconnected) if adoption
          @log.info("connection.disconnected", revoked: result.revoked.join(","), unclaimed: result.unclaimed)
          [200, {
            revoked: result.revoked, unclaimed: result.unclaimed, mode: result.mode,
            runner_executor_public_id: result.runner_executor_public_id,
            identity: Lineage::Status.identity_facts(result.identity),
          }]
        rescue CybrosAgent::Error, Rho::Error => error
          Refusal.new(status: 502, code: "disconnect_failed", message: CybrosAgent::Redaction.call(error.message))
        end
      end
    end
  end
end
