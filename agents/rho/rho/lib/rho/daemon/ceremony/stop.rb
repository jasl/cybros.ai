module Rho
  class Daemon
    class Ceremony
      # The ceremony half of an orderly stop:
      # Nexus's cancel/Consume winner decides whether the poller may be killed,
      # must reach durable staging, or the stop is aborted with the home lock held.
      module Stop
        # Killing the poller does not prove its masked Consume→staging writer is
        # gone, and the home lock must not release before it is.
        STOP_CEREMONY_DRAIN_DEADLINE = 5

        def prepare_for_stop
          slot = @lineage.slot_snapshot
          connection = slot.connection
          thread = slot.poller
          return if connection.nil?

          case connection.phase
          when :starting
            raise ConnectionError,
              "cannot stop safely while a connection authorization is still starting; try again"
          when :pending, :pending_runner
            unless thread
              raise ConnectionError,
                "cannot stop safely while a pending connection has not published its poller"
            end
            case connection.cancellation_outcome
            when :canceled
              quiesce_canceled_poller(connection)
            when :consumed
              wait_for_consumed_poller(thread)
            else
              raise ConnectionError, "Nexus returned an unknown cancellation outcome during shutdown"
            end
          when :activating
            wait_for_consumed_poller(thread) if thread
          when :active
            # The Connection can reach active one instruction before the daemon
            # adopts it. Do not kill that final hand-off.
            wait_for_consumed_poller(thread) if thread && !connection.oauth.equal?(slot.credentials)
          else
            nil # an error has no live writer; any staged bundle is already durable
          end
        rescue ConnectionError
          raise
        rescue CybrosAgent::Error, Rho::Error => error
          raise ConnectionError,
            "cannot determine a safe connection shutdown outcome " \
            "(#{CybrosAgent::Redaction.call(error.message)})"
        end

        def drain_poller
          thread = @lineage.slot_snapshot.poller
          return if thread.nil?

          thread.kill
          thread.join
          @lineage.release_poller(thread)
        end

        private

          def wait_for_consumed_poller(thread)
            deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + STOP_CEREMONY_DRAIN_DEADLINE
            while thread.alive? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
              sleep 0.01
            end
            return unless thread.alive?

            raise ConnectionError,
              "the authorized connection did not reach a durable checkpoint before the shutdown deadline"
          end
      end
    end
  end
end
