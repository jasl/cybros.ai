module Nexus
  module Contract
    class << self
      private

        def platform_deployment
          target = Nexus::Deployment::Release.new(release: "fixture-v2",
            images: [Nexus::Deployment::Image.new(name: "nexus", reference: "registry.example/nexus@sha256:fixture")])
          receipt = Nexus::Deployment::Receipt.new(
            id: "01900000-0000-7000-8000-000000000060", idempotency_key: "01900000-0000-7000-8000-000000000061",
            actor_public_id: "01900000-0000-7000-8000-000000000001", target: target, previous: nil,
            phase: "completed", status: "succeeded", accepted_at: "2026-10-15T00:00:00Z",
            updated_at: "2026-10-15T00:01:00Z", completed_at: "2026-10-15T00:01:00Z",
            error: nil, recovery: nil, log_cursor: "fixture-cursor-1", backup: true,
            database_backup: Nexus::Deployment::DatabaseBackup.new(created_at: "2026-10-15T00:00:30Z",
              size_bytes: 1024, available: true)
          )
          state = Nexus::Deployment::State.new(supported: true, sources: target.images, installed: target,
            candidate: Nexus::Deployment::Candidate.new(target: target, checked_at: "2026-10-15T00:00:00Z",
              source_revision: "fixture-revision", source_url: "https://example.test/releases/fixture-v2"),
            preflight: Nexus::Deployment::Preflight.new(checked_at: "2026-10-15T00:00:00Z", ready: true,
              backup: true, checks: [Nexus::Deployment::PreflightCheck.new(name: "disk", status: "ready", message: "Ready",
                next_step: nil, available_bytes: 4096, required_bytes: 1024)]),
            active_operation: nil, last_operation: receipt)
          log = Nexus::Deployment::Log.new(entries: [Nexus::Deployment::LogEntry.new(cursor: "fixture-cursor-1", text: "Complete")],
            next_cursor: "fixture-cursor-1", operation: receipt)
          state_row = stringify_keys(API::DeploymentPresenter.state(state))
          receipt_row = stringify_keys(API::DeploymentPresenter.receipt(receipt))
          log_row = stringify_keys(API::DeploymentPresenter.log(log))
          error_row = stringify_keys(API::DeploymentPresenter.error(
            Nexus::Deployment::Error.new(code: :updater_unavailable, message: "Fixture updater unavailable", operation_id: receipt.id)
          ))
          {
            "valid_state_fixture" => { "deployment" => state_row },
            "valid_upgrade_fixture" => { "upgrade" => receipt_row },
            "valid_log_fixture" => { "log" => log_row },
            "valid_progress_event_fixture" => { "event" => "deployment.progress.v1", "id" => log.next_cursor, "data" => log_row },
            "valid_error_event_fixture" => { "event" => "deployment.error.v1", "data" => error_row },
            "unknown_status_fixture" => { "upgrade" => receipt_row.merge("status" => UNKNOWN_VALUE_FIXTURE) },
            "unknown_event_fixture" => { "event" => UNKNOWN_VALUE_FIXTURE, "id" => "future-cursor", "data" => { "future" => true } },
            "unknown_value_behavior" => "carry_unknown", "cursor_behavior" => "query_overrides_last_event_id",
            "stream_behavior" => "bounded_observation_without_mutation_retry",
          }
        end
    end
  end
end
