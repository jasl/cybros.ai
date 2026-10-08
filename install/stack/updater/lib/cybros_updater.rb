require "base64"
require "date"
require "fileutils"
require "json"
require "securerandom"
require "socket"
require "time"

module CybrosUpdater
  REQUEST_LIMIT = 16 * 1024
  RESPONSE_LIMIT = 128 * 1024
  LOG_WINDOW_LIMIT = 64 * 1024
  UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

  class Error < StandardError
    attr_reader :code, :status, :operation_id

    def initialize(code, message, status: 503, operation_id: nil)
      super(message)
      @code = code
      @status = status
      @operation_id = operation_id
    end

    def to_h
      { "code" => code, "message" => message }.tap do |value|
        value["operation_id"] = operation_id if operation_id
      end
    end
  end

  Image = Data.define(:name, :reference, :version) do
    def self.from_h(value)
      new(name: value.fetch("name"), reference: value.fetch("reference"), version: value["version"])
    end

    def to_h = { "name" => name, "reference" => reference, "version" => version }
  end

  Release = Data.define(:release, :images, :checked_at, :source_revision, :source_url) do
    def self.valid_tag?(value)
      value.match?(/\A[0-9]{10}\z/) && DateTime.strptime("20#{value}", "%Y%m%d%H%M").strftime("%y%m%d%H%M") == value
    rescue Date::Error
      false
    end

    def self.from_h(value)
      new(
        release: value.fetch("release"), images: value.fetch("images").map { |image| Image.from_h(image) },
        checked_at: value["checked_at"], source_revision: value["source_revision"], source_url: value["source_url"],
      )
    end

    def selection
      { "release" => release, "images" => images.map { |image| { "name" => image.name, "reference" => image.reference } } }
    end

    def to_h
      { "release" => release, "images" => images.map(&:to_h), "checked_at" => checked_at, "source_revision" => source_revision, "source_url" => source_url }
    end

    def reference(name) = images.find { |image| image.name == name }.reference
  end

  DatabaseBackup = Data.define(:created_at, :size_bytes, :available) do
    def self.from_h(value) = new(**value.transform_keys(&:to_sym))
    def to_h = super.transform_keys(&:to_s)
  end

  PreflightCheck = Data.define(:name, :status, :message, :next_step, :available_bytes, :required_bytes) do
    def self.from_h(value) = new(**value.transform_keys(&:to_sym))
    def to_h = super.transform_keys(&:to_s)
  end

  Preflight = Data.define(:scope, :backup, :checked_at, :checks) do
    def self.from_h(value)
      new(scope: value.fetch("scope", "installation"), backup: value.fetch("backup", true), checked_at: value.fetch("checked_at"), checks: value.fetch("checks").map { |check| PreflightCheck.from_h(check) })
    end

    def ready? = checks.none? { |check| check.status == "blocked" }
    def to_h = { "scope" => scope, "backup" => backup, "checked_at" => checked_at, "ready" => ready?, "checks" => checks.map(&:to_h) }
  end

  Inspection = Data.define(:candidate, :installed, :preflight)

  Receipt = Data.define(
    :id, :idempotency_key, :actor_public_id, :target, :previous, :phase, :status,
    :accepted_at, :updated_at, :completed_at, :error, :recovery, :log_cursor, :migrator_name, :database_backup, :backup,
  ) do
    def self.from_h(value)
      new(**value.transform_keys(&:to_sym).merge(
        backup: value.fetch("backup", true),
        target: Release.from_h(value.fetch("target")),
        previous: value["previous"] && Release.from_h(value.fetch("previous")),
        database_backup: value["database_backup"] && DatabaseBackup.from_h(value.fetch("database_backup")),
      ))
    end

    def to_h
      super.transform_keys(&:to_s).merge("target" => target.to_h, "previous" => previous&.to_h, "database_backup" => database_backup&.to_h)
    end

    def running? = status == "running"
    def needs_recovery? = %w[stopping backing_up migrating activating verifying].include?(phase) && status != "succeeded"
  end
end

require_relative "cybros_updater/store"
require_relative "cybros_updater/command"
require_relative "cybros_updater/backups"
require_relative "cybros_updater/docker"
require_relative "cybros_updater/engine"
require_relative "cybros_updater/transport"
