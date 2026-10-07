module Rho
  module Extensions
    module Schedules
      class Read
        NAME = "read_schedules".freeze
        DESCRIPTION = <<~TEXT.strip.freeze
          Read this conversation's one-time and recurring background jobs, including their instructions, next run, and execution history. Use action=list to discover job IDs, show with job_id for one job and its lock_version, or history with job_id to inspect its independent executions. Follow next_after with after when another page is available. A completed one-time schedule means it has dispatched its run; last_execution reports the actual work's status. These jobs are stored in Nexus and continue independently of this conversation's current turn.
        TEXT
        SCHEMA = {
          "type" => "object",
          "properties" => {
            "action" => { "type" => "string", "enum" => %w[list show history] },
            "job_id" => { "type" => "string", "minLength" => 1 },
            "after" => { "type" => "string", "minLength" => 1 },
            "limit" => { "type" => "integer", "minimum" => 1, "maximum" => 50 },
          },
          "required" => ["action"],
          "oneOf" => [
            { "properties" => { "action" => { "const" => "list" } } },
            { "properties" => { "action" => { "enum" => %w[show history] } }, "required" => ["job_id"] },
          ],
          "additionalProperties" => false,
        }.freeze
        EFFECT_PROFILE = { "kind" => "read_only", "destructive" => false, "effect_scope" => "closed",
          "idempotency" => "intrinsic", "reconciliation" => "none" }.freeze
        TIMEOUT_MS = 30_000

        def initialize(env:)
          @env = env
        end

        def call(args)
          jobs = Session.new.jobs
          page = { after: args["after"], limit: args.fetch("limit", 30) }
          result = case args.fetch("action")
          when "list"
            rows = jobs.list(**page)
            { schedules: rows.items.map(&:to_h), next_after: rows.next_after }
          when "show" then jobs.fetch(args.fetch("job_id")).to_h
          when "history"
            rows = jobs.executions(args.fetch("job_id"), **page)
            { executions: rows.items.map(&:to_h), next_after: rows.next_after, last_cursor: rows.last_cursor }
          else
            raise ArgumentError, "unknown scheduled job read action"
          end
          Rho::Runner::Result.ok(JSON.generate(result))
        rescue CybrosAgent::Error => error
          Rho::Runner::Result.error("scheduled jobs could not be read: #{error.code || error.message}")
        rescue Session::Unavailable => error
          Rho::Runner::Result.error(error.message)
        end
      end
    end
  end
end
