module DeploymentTestHelper
  OPERATION_ID = "019a0000-0000-7000-8000-000000000001"
  IDEMPOTENCY_KEY = "019a0000-0000-7000-8000-000000000002"

  class Client
    attr_accessor :state, :upgrade_receipt, :failure
    attr_reader :calls

    def initialize(state:, receipt:)
      @state, @upgrade_receipt = state, receipt
      @calls = []
    end

    def status
      @calls << { operation: :status }
      @failure || response(@state)
    end

    def check(tag: "latest", backup: true)
      @calls << { operation: :check, tag: tag, backup: backup }
      preflight = @state.preflight
      if preflight
        checks = backup ? preflight.checks : preflight.checks.reject { |check| check.name == "installation_space" }
        @state = @state.with(preflight: preflight.with(backup: backup, checks: checks))
      end
      @failure || response(@state)
    end

    def upgrade(idempotency_key:, actor_public_id:, candidate:, backup: true)
      @calls << { operation: :upgrade, idempotency_key: idempotency_key,
        actor_public_id: actor_public_id, candidate: candidate, backup: backup }
      if @failure
        @failure
      else
        @upgrade_receipt = @upgrade_receipt.with(idempotency_key: idempotency_key,
          actor_public_id: actor_public_id, target: candidate, backup: backup)
        @state = @state.with(active_operation: @upgrade_receipt, last_operation: @upgrade_receipt)
        response(@upgrade_receipt, status: 202)
      end
    end

    def receipt(operation_id:)
      @calls << { operation: :receipt, operation_id: operation_id }
      @failure || response(@upgrade_receipt)
    end

    def log(operation_id:, cursor: nil)
      @calls << { operation: :log, operation_id: operation_id, cursor: cursor }
      @failure || response(Nexus::Deployment::Log.new(
        entries: cursor == "tail" ? [] : [Nexus::Deployment::LogEntry.new(cursor: "tail", text: "Preparing images\n")],
        next_cursor: "tail", operation: @upgrade_receipt
      ))
    end

    def complete
      @upgrade_receipt = @upgrade_receipt.with(status: "succeeded", phase: "completed",
        completed_at: "2026-10-08T09:30:10Z")
      @state = @state.with(installed: @upgrade_receipt.target, active_operation: nil,
        last_operation: @upgrade_receipt)
    end

    def back_up(backup)
      @upgrade_receipt = @upgrade_receipt.with(phase: "backing_up", database_backup: backup)
      @state = @state.with(active_operation: @upgrade_receipt, last_operation: @upgrade_receipt)
    end

    private

      def response(data, status: 200)
        Nexus::Deployment::Response.new(status: status, data: data, error: nil)
      end
  end

  def deployment_release
    { "release" => "2610080750", "images" => [
      { "name" => "nexus", "reference" => "registry.example/nexus@sha256:#{"a" * 64}" },
    ] }
  end

  def deployment_receipt
    Nexus::Deployment::Receipt.from_h(
      "id" => OPERATION_ID, "idempotency_key" => IDEMPOTENCY_KEY, "actor_public_id" => users(:owner).public_id,
      "target" => deployment_release, "previous" => nil, "phase" => "preparing", "status" => "running",
      "accepted_at" => "2026-10-08T09:30:00Z", "updated_at" => "2026-10-08T09:30:01Z",
      "completed_at" => nil, "error" => nil, "recovery" => nil, "log_cursor" => "tail", "backup" => true, "database_backup" => nil
    )
  end

  def deployment_preflight(ready: true, backup: true)
    {
      "checked_at" => "2026-10-08T09:00:00Z", "ready" => ready, "backup" => backup,
      "checks" => [
        { "name" => "installation_space", "status" => ready ? "passed" : "blocked",
          "message" => ready ? "The installation volume has enough free space." : "The installation volume needs more free space.",
          "next_step" => ready ? nil : "Free space on the installation volume and check again.",
          "available_bytes" => ready ? 4_194_304 : 1_048_576, "required_bytes" => 2_097_152 },
        { "name" => "image_store_space", "status" => "warning", "message" => "Image storage needs an operator check.",
          "next_step" => "Check available image storage on the Docker host.", "available_bytes" => nil, "required_bytes" => nil },
      ],
    }
  end

  def deployment_backup(available: true)
    Nexus::Deployment::DatabaseBackup.new(created_at: "2026-10-08T09:30:02Z", size_bytes: 1_048_576, available: available)
  end

  def deployment_state
    Nexus::Deployment::State.from_h(
      "supported" => true,
      "sources" => [{ "name" => "nexus", "reference" => "registry.example/nexus" }],
      "installed" => deployment_release.merge("release" => "2610080749"),
      "candidate" => deployment_release.merge("checked_at" => "2026-10-08T09:00:00Z",
        "source_url" => "https://example.test/source"),
      "preflight" => deployment_preflight, "active_operation" => nil, "last_operation" => nil
    )
  end

  def fake_deployment_client
    Client.new(state: deployment_state, receipt: deployment_receipt)
  end

  def deployment_error(code: :updater_unavailable, status: 503, operation_id: nil)
    Nexus::Deployment::Response.new(status: status, data: nil, error: Nexus::Deployment::Error.new(
      code: code, message: "The updater could not complete this request.", operation_id: operation_id
    ))
  end
end
