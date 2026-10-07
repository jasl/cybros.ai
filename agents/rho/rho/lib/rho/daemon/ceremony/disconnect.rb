module Rho
  class Daemon
    class Ceremony
      # `POST /disconnect`: the two refusals, the count, the
      # revokes, the lineage edges — the runner slot retired through
      # `lose_runner`, the whole connection through `lose`.
      module Disconnect
        def disconnect(runner_only:)
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
          if runner_only && (!about.runner? || @mode == "runner")
            return Refusal.new(status: 409, code: "no_runner",
              message: no_runner_message(identity))
          end

          result = Rho::Disconnect.call(home: @home, identity: identity, credentials: about, runner_only: runner_only,
            executor_client: ->(credential) { @wire.executor_client(credential) }, log: @log)
          if runner_only
            @lose_runner.call(about: about, identity: result.identity)
          else
            adoption = @lineage.lose(about: about)
            @settle.call(adoption, :disconnected) if adoption
          end
          @log.info("connection.disconnected", revoked: result.revoked.join(","), unclaimed: result.unclaimed)
          [200, {
            revoked: result.revoked, unclaimed: result.unclaimed, mode: result.mode,
            runner_executor_public_id: result.runner_executor_public_id,
            identity: Lineage::Status.identity_facts(result.identity),
          }]
        rescue CybrosAgent::Error, Rho::Error => error
          Refusal.new(status: 502, code: "disconnect_failed", message: CybrosAgent::Redaction.call(error.message))
        end

        private

          def no_runner_message(identity)
            if @mode == "runner"
              "this rho is in mode runner: the runner IS the whole connection — `rho disconnect` without --runner"
            elsif identity.runner_executor_public_id
              "this home's runner credential is already gone; `rho connect` re-pairs it"
            else
              "this home never paired a runner (mode #{@mode})"
            end
          end
      end
    end
  end
end
