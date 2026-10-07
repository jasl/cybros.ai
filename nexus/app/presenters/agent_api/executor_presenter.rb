module AgentAPI
  # The executor plane's self-description: the five fields under
  # `executor`, its presence beside its contact sample (the
  # self-read is honest and tautological: an HTTP read is contact, never a
  # socket), and when they were measured — GET /executor's answer, and the
  # announcement's, from one place. Never the served-tools list: an
  # executor declared it and it is not the executor's to read back.
  #
  # DISCOVERY is a DIFFERENT reader: what a principal may address,
  # with the declaration facts the machine announced — `served_tools` whole
  # (name, effect_profile, timeout_ms?, description?, input_schema?), the
  # environment snapshot and `served_documents` (the `{name, description}`
  # entries it can load for a model) — the feeder of
  # a remote runner's declaration.
  # Presence, the contact sample and `connected_at` ride it for display,
  # never as a reason to choose. `binding` is the `runner` read on a host.
  class ExecutorPresenter
    class << self
      def description(executor, measured_at:, live_server_ids:)
        {
          executor: {
            public_id: executor.public_id,
            kind: executor.executor_kind,
            status: executor.status,
            display_name: executor.display_name,
            credential_epoch: executor.credential_epoch,
            presence: Nexus::Presence.of(executor, live_server_ids: live_server_ids),
            last_seen_at: executor.last_seen_at,
            connected_at: executor.connected_at,
          },
          measured_at: measured_at,
        }
      end

      def discovery(executor, live_server_ids:)
        {
          public_id: executor.public_id,
          kind: executor.executor_kind,
          display_name: executor.display_name,
          status: executor.status,
          assignment_scope: executor.assignment_scope,
          served_tools: executor.served_tools,
          environment: executor.environment,
          served_documents: executor.served_documents,
          presence: Nexus::Presence.of(executor, live_server_ids: live_server_ids),
          last_seen_at: executor.last_seen_at,
          connected_at: executor.connected_at,
        }
      end

      # The binding readable on both hosts: nil before any binding and after
      # a reap (the FK nullifies).
      def binding(executor, live_server_ids:)
        return nil if executor.nil?

        {
          executor_public_id: executor.public_id,
          display_name: executor.display_name,
          presence: Nexus::Presence.of(executor, live_server_ids: live_server_ids),
          last_seen_at: executor.last_seen_at,
        }.compact
      end
    end
  end
end
