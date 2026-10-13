module Rho
  module Extensions
    module Schedules
      class Manage
        NAME = "manage_schedule".freeze
        DESCRIPTION = <<~TEXT.strip.freeze
          Create or manage a background job for this conversation when the person asks for future work. Save a self-contained prompt describing the work and what to report; Nexus runs it independently when due, with ordinary tools and approvals, then sends its result back to this conversation. Use rule.kind=once with an absolute ISO8601 run_at for one-time work; interval with every_seconds and an absolute starts_at for periodic work; daily with local_time HH:MM and an explicit IANA time_zone for a daily local time. Do not implement a timer, sleep until due, or schedule a successor yourself. action=create requires prompt and rule; update requires job_id and expected_lock_version from read_schedules; pause, resume and cancel require job_id. Creation retains this calling round's model, tools and approval policy. Updates affect future runs only. Pause stops future dispatch; resume chooses the next future time; cancel stops the schedule. Already-running work uses the ordinary task stop control. Do not claim a job was saved unless this tool returns its accepted record.
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
          "additionalProperties" => false,
        }.freeze
        # Which fields each rule kind and each action needs. Stated here and
        # checked in the handler rather than as a top-level `oneOf`: Anthropic's
        # tool API refuses top-level oneOf/allOf/anyOf in an input schema.
        RULE_FIELDS = { "once" => %w[run_at], "interval" => %w[every_seconds starts_at], "daily" => %w[local_time time_zone] }.freeze
        ACTION_FIELDS = { "create" => %w[prompt rule], "update" => %w[job_id expected_lock_version],
          "pause" => %w[job_id], "resume" => %w[job_id], "cancel" => %w[job_id] }.freeze
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
          "additionalProperties" => false,
        }.freeze
        EFFECT_PROFILE = { "kind" => "write", "destructive" => true, "effect_scope" => "closed",
          "idempotency" => "keyed", "reconciliation" => "lookup" }.freeze
        TIMEOUT_MS = 30_000

        def initialize(env:)
          @env = env
        end

        def call(args)
          refusal = missing_fields(args)
          return Rho::Runner::Result.error(refusal) if refusal

          session = Session.new
          fields = args.slice("name", "prompt", "rule").transform_keys(&:to_sym)
          row = case args.fetch("action")
          when "create"
            session.jobs.create(**fields, **session.creation_fields).schedule
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

        private

          # The sentence the model reads when an action or rule lacks a field.
          def missing_fields(args)
            action = args.fetch("action")
            missing = ACTION_FIELDS.fetch(action) - args.keys
            return "#{action} requires #{missing.join(", ")}" unless missing.empty?

            rule = args["rule"]
            return nil unless rule

            missing = RULE_FIELDS.fetch(rule.fetch("kind")) - rule.keys
            "rule.kind=#{rule.fetch("kind")} requires #{missing.join(", ")}" unless missing.empty?
          end
      end
    end
  end
end
