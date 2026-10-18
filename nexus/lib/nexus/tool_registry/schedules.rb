module Nexus
  module ToolRegistry
    module Schedules
      RULE = {
        "type" => "object", "properties" => {
          "kind" => { "type" => "string", "enum" => %w[once interval daily] },
          "run_at" => { "type" => "string", "minLength" => 1 },
          "every_seconds" => { "type" => "integer", "minimum" => 60, "maximum" => 31_536_000 },
          "starts_at" => { "type" => "string", "minLength" => 1 },
          "local_time" => { "type" => "string", "minLength" => 1 },
          "time_zone" => { "type" => "string", "minLength" => 1 },
        }, "required" => ["kind"], "additionalProperties" => false,
      }.freeze

      TOOLS = [
        Tool.new(
          canonical: "nexus.schedules.read", name: "read_schedules",
          template: <<~TEXT.strip,
            Read this conversation's one-time and recurring background jobs. Use action=list
            to discover job IDs; show and history require job_id. Show includes instructions,
            next occurrence and lock_version; history lists independent executions. Follow
            next_after with after for another page. A completed one-time schedule has dispatched
            its run; last_execution reports whether the actual work has finished.
          TEXT
          parameters: { "type" => "object", "properties" => {
            "action" => { "type" => "string", "enum" => %w[list show history] },
            "job_id" => { "type" => "string", "minLength" => 1 },
            "after" => { "type" => "string", "description" => "The UUID returned as next_after." },
            "limit" => { "type" => "integer", "minimum" => 1, "maximum" => 50, "default" => 30 },
          }, "required" => ["action"], "additionalProperties" => false },
          effect_profile: READ_ONLY_CLOSED,
          executor: "Runs::ScheduleTool::Run", job: "Runs::ToolDiscoveryJob",
        ),
        Tool.new(
          canonical: "nexus.schedules.manage", name: "manage_schedule",
          template: <<~TEXT.strip,
            Create or manage background work when the person asks for future work. Save a
            self-contained prompt describing the work and what to report. The platform runs it
            independently when due, with this calling round's model, tools and approval policy,
            and returns its result here. action=create requires prompt and rule. rule.kind=once
            needs an absolute ISO8601 run_at; interval needs every_seconds and an absolute
            starts_at; daily needs local_time HH:MM and an explicit IANA time_zone. Update
            requires job_id and expected_lock_version from {{read_schedules}}; pause, resume
            and cancel require job_id. Updates affect future runs. Pause stops dispatch;
            resume chooses the next future occurrence; cancel stops the schedule and removes
            a pending execution input. Already-running work uses the ordinary stop control.
            Do not sleep until due or schedule a successor. Only claim a job was saved after
            this tool returns its accepted record.
          TEXT
          parameters: { "type" => "object", "properties" => {
            "action" => { "type" => "string", "enum" => %w[create update pause resume cancel] },
            "job_id" => { "type" => "string", "minLength" => 1 },
            "name" => { "type" => "string", "minLength" => 1 },
            "prompt" => { "type" => "string", "minLength" => 1 },
            "rule" => RULE,
            "expected_lock_version" => { "type" => "integer", "minimum" => 0 },
          }, "required" => ["action"], "additionalProperties" => false },
          effect_profile: MEMORY_WRITE,
          executor: "Runs::ScheduleTool::Run", job: "Runs::ToolDiscoveryJob",
        ),
      ].freeze
    end
  end
end
