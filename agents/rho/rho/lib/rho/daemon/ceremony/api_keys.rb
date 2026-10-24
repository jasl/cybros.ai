module Rho
  class Daemon
    class Ceremony
      module APIKeyImport
        def import_api_keys(document)
          return Refusal.stopping if @lineage.stopping?
          return Refusal.bootstrapping if @lineage.bootstrapping?
          if Connection.staged_oauth?(@home)
            return Refusal.new(status: 409, code: "connection_pending",
              message: "Finish the pending connection before importing keys")
          end

          if @lineage.runner&.snapshot&.in_flight.to_i.positive?
            return Refusal.new(status: 409, code: "work_in_flight",
              message: "Stop running tool calls or wait before replacing the connection")
          end

          expected = @lineage.credentials
          connection = build_connection
          connection.reserve(notify: false)
          outcome = @lineage.claim_slot(connection, expected: expected)
          unless outcome == :claimed
            return Refusal.new(status: 409, code: "connection_changed",
              message: "Another connection is completing; retry after it finishes")
          end

          connection.receive_api_keys(document)
          adopt(connection)
          [200, connection.to_h]
        rescue CybrosAgent::Error, Rho::Error => error
          Refusal.new(status: 422, code: "api_key_connection_failed",
            message: CybrosAgent::Redaction.call(error.message))
        ensure
          @lineage.release_slot(connection) if outcome == :claimed
        end
      end
    end
  end
end
