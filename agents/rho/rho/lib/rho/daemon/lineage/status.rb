module Rho
  class Daemon
    class Lineage
      # Pure functions over one snapshot taken under the monitor, so every
      # fact `/status` renders comes from the same instant.
      module Status
        module_function

        def document(snapshot)
          {
            state: snapshot.phase.to_s,
            version: VERSION,
            authority: authority(snapshot),
            connection: snapshot.connection_document,
            identity: snapshot.identity && identity_facts(snapshot.identity, snapshot.observation),
            workspace: snapshot.workspace.document,
            error: snapshot.connection_error,
          }.compact
        end

        # The handle beside the profile id is the LAST
        # PROBE's reading, never the pointer's: a steward may rename it,
        # and the pointer is compared field by field at boot. The
        # announcement passes no observation and names no handle.
        def identity_facts(identity, observation = nil)
          {
            user_public_id: identity.user_public_id,
            handle: observation&.report&.dig(:member_handle),
            executor_public_id: identity.executor_public_id,
            runner_executor_public_id: identity.runner_executor_public_id,
          }.compact
        end

        # The two vocabularies, on purpose: `planes` keeps the precise words
        # because a 401 is one undifferentiated type, and `signed` is the
        # ordinary login word a person already understands, derived from them.
        def authority(snapshot)
          if snapshot.lost
            return with_measured_at({ signed: "expired", planes: {} }, snapshot.observation)
          end
          return nil if snapshot.credentials.nil?

          observation = snapshot.observation
          unless observation && snapshot.credentials.equal?(observation.about)
            return { signed: "unknown" }
          end

          report = observation.report
          with_measured_at(
            { signed: signed_state(report), planes: report.fetch(:planes).transform_values(&:to_s) },
            observation
          )
        end

        # Over the AGENT planes: the runner plane prints its own line and never moves the login
        # word — except in runner mode, where it is the one plane there is.
        def signed_state(report)
          return "expired" if report[:lost]

          states = report[:planes].reject { |plane, _| plane == :runner_transport }.values
          states = report[:planes].values if states.empty?
          return "signed_out" if states.all? { |state| state == :absent }
          return "signed_in" if states.all? { |state| state == :live }
          return "unknown" if states.include?(:unknown)

          "expired"
        end

        def with_measured_at(authority, observation)
          return authority if observation.nil?

          authority.merge(measured_at: observation.measured_at.utc.iso8601)
        end
      end
    end
  end
end
