module Rho
  module Extensions
    module ScheduledJobs
      class Manage
        NAME = "manage_scheduled_job".freeze
        DESCRIPTION = <<~TEXT.strip.freeze
          Create or manage a background job for this conversation when the person asks for future work. Save a self-contained prompt describing the work and what to report; Nexus runs it independently when due, with ordinary tools and approvals, then sends its result back to this conversation. Use rule.kind=once with an absolute ISO8601 run_at for one-time work; interval with every_seconds and an absolute starts_at for periodic work; daily with local_time HH:MM and an explicit IANA time_zone for a daily local time. Do not implement a timer, sleep until due, or schedule a successor yourself. Creation retains this calling round's model, tools and approval policy. Updates affect future runs only and require expected_lock_version from read_scheduled_jobs. Pause stops future dispatch; resume chooses the next future time; cancel stops the schedule. Already-running work uses the ordinary task stop control. Do not claim a job was saved unless this tool returns its accepted record.
        TEXT
        RULE_SCHEMA = {
          "type" => "object",
          "properties" => {
            "kind" => { "type" => "string", "enum" => %w[once interval daily] },
            "run_at" => { "type" => "string", "minLength" => 1 },
            "every_seconds" => { "type" => "integer", "minimum" => 60, "maximum" => 31_536_000 },
            "starts_at" => { "type" => "string", "minLength" => 1 },
            "local_time" => { "type" => "string", "minLength" => 1 },
            "time_zone" => { "type" => "string", "minLength" => 1 },
          },
          "required" => ["kind"],
          "oneOf" => [
            { "properties" => { "kind" => { "const" => "once" } }, "required" => ["run_at"] },
            { "properties" => { "kind" => { "const" => "interval" } }, "required" => %w[every_seconds starts_at] },
            { "properties" => { "kind" => { "const" => "daily" } }, "required" => %w[local_time time_zone] },
          ],
          "additionalProperties" => false,
        }.freeze
        SCHEMA = {
          "type" => "object",
          "properties" => {
            "action" => { "type" => "string", "enum" => %w[create update pause resume cancel] },
            "job_id" => { "type" => "string", "minLength" => 1 },
            "name" => { "type" => "string", "minLength" => 1 },
            "prompt" => { "type" => "string", "minLength" => 1 },
            "rule" => RULE_SCHEMA,
            "expected_lock_version" => { "type" => "integer", "minimum" => 0 },
          },
          "required" => ["action"],
          "oneOf" => [
            { "properties" => { "action" => { "const" => "create" } }, "required" => %w[prompt rule] },
            { "properties" => { "action" => { "const" => "update" } }, "required" => %w[job_id expected_lock_version] },
            { "properties" => { "action" => { "enum" => %w[pause resume cancel] } }, "required" => ["job_id"] },
          ],
          "additionalProperties" => false,
        }.freeze
        EFFECT_PROFILE = { "kind" => "write", "destructive" => true, "world" => "closed",
          "idempotency" => "keyed", "reconciliation" => "lookup" }.freeze
        TIMEOUT_MS = 30_000

        def initialize(env:)
          @env = env
        end

        def call(args)
          session = Session.new
          fields = args.slice("name", "prompt", "rule").transform_keys(&:to_sym)
          row = case args.fetch("action")
          when "create"
            session.jobs.create(**fields, **session.creation_fields).scheduled_job
          when "update"
            session.jobs.update(args.fetch("job_id"), **fields,
              expected_lock_version: args.fetch("expected_lock_version"))
          when "pause", "resume", "cancel"
            session.jobs.public_send(args.fetch("action"), args.fetch("job_id"))
          else
            raise ArgumentError, "unknown scheduled job action"
          end
          Rho::Runner::Result.ok(JSON.generate(row.to_h))
        rescue CybrosAgent::Error => error
          Rho::Runner::Result.error("scheduled job was not confirmed: #{error.code || error.message}")
        rescue Session::Unavailable => error
          Rho::Runner::Result.error(error.message)
        end
      end
    end
  end
end
