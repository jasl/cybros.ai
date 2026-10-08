module Nexus
  # The installation owner projects Nexus's own deployment across private IPC.
  # Agent application installation state stays outside the kernel.
  module Deployment
    Image = Data.define(:name, :reference) do
      def self.from_h(value)
        name = value.fetch("name").to_s
        # The updater is independently deployed. A combined-installation reply
        # must never become an actionable Nexus administration selection.
        raise ArgumentError, "Expected the Nexus deployment image" unless name == "nexus"

        new(name: name, reference: value.fetch("reference"))
      end
    end

    Release = Data.define(:release, :images) do
      def self.from_h(value)
        new(release: value.fetch("release"), images: value.fetch("images").map { |image| Image.from_h(image) })
      end

      def to_h
        { release: release, images: images.map(&:to_h) }
      end
    end

    Candidate = Data.define(:target, :checked_at, :source_revision, :source_url) do
      def self.from_h(value)
        new(target: Release.from_h(value), checked_at: value.fetch("checked_at"),
          source_revision: value["source_revision"], source_url: value["source_url"])
      end
    end

    PreflightCheck = Data.define(:name, :status, :message, :next_step, :available_bytes, :required_bytes) do
      def self.from_h(value)
        new(name: value.fetch("name"), status: value.fetch("status"), message: value.fetch("message"),
          next_step: value.fetch("next_step"), available_bytes: value.fetch("available_bytes"),
          required_bytes: value.fetch("required_bytes"))
      end
    end

    Preflight = Data.define(:checked_at, :ready, :backup, :checks) do
      def self.from_h(value)
        new(checked_at: value.fetch("checked_at"), ready: value.fetch("ready"), backup: value.fetch("backup"),
          checks: value.fetch("checks").map { |check| PreflightCheck.from_h(check) })
      end

      def to_h
        { checked_at: checked_at, ready: ready, backup: backup, checks: checks.map(&:to_h) }
      end
    end

    DatabaseBackup = Data.define(:created_at, :size_bytes, :available) do
      def self.from_h(value)
        new(created_at: value.fetch("created_at"), size_bytes: value.fetch("size_bytes"),
          available: value.fetch("available"))
      end
    end

    Error = Data.define(:code, :message, :operation_id) do
      def self.from_h(value)
        new(code: value.fetch("code").to_sym, message: value.fetch("message"),
          operation_id: value["operation_id"])
      end
    end

    Receipt = Data.define(:id, :idempotency_key, :actor_public_id, :target, :previous,
      :phase, :status, :accepted_at, :updated_at, :completed_at, :error, :recovery, :log_cursor, :backup, :database_backup) do
      def self.from_h(value)
        backup = value.fetch("database_backup")
        new(
          id: value.fetch("id"), idempotency_key: value.fetch("idempotency_key"),
          actor_public_id: value.fetch("actor_public_id"), target: Release.from_h(value.fetch("target")),
          previous: value["previous"] && Release.from_h(value.fetch("previous")),
          phase: value.fetch("phase"), status: value.fetch("status"),
          accepted_at: value.fetch("accepted_at"), updated_at: value.fetch("updated_at"),
          completed_at: value["completed_at"], error: value["error"] && Error.from_h(value.fetch("error")),
          recovery: value["recovery"], log_cursor: value["log_cursor"], backup: value.fetch("backup"),
          database_backup: backup && DatabaseBackup.from_h(backup)
        )
      end
    end

    State = Data.define(:supported, :sources, :installed, :candidate, :preflight, :active_operation, :last_operation) do
      def self.from_h(value)
        preflight = value.fetch("preflight")
        new(
          supported: value.fetch("supported"),
          sources: value.fetch("sources").map { |image| Image.from_h(image) },
          installed: value["installed"] && Release.from_h(value.fetch("installed")),
          candidate: value["candidate"] && Candidate.from_h(value.fetch("candidate")),
          preflight: preflight && Preflight.from_h(preflight),
          active_operation: value["active_operation"] && Receipt.from_h(value.fetch("active_operation")),
          last_operation: value["last_operation"] && Receipt.from_h(value.fetch("last_operation"))
        )
      end
    end

    LogEntry = Data.define(:cursor, :text) do
      def self.from_h(value)
        new(cursor: value.fetch("cursor"), text: value.fetch("text"))
      end
    end

    Log = Data.define(:entries, :next_cursor, :operation) do
      def self.from_h(value)
        new(entries: value.fetch("entries").map { |entry| LogEntry.from_h(entry) },
          next_cursor: value.fetch("next_cursor"), operation: Receipt.from_h(value.fetch("operation")))
      end
    end

    Response = Data.define(:status, :data, :error) do
      def success? = error.nil?
    end
  end
end
