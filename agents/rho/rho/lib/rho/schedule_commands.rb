require "securerandom"
require "json"
require_relative "gateway/delivery_time"

module Rho
  # One human grammar for the terminal and chat. Relative times are resolved
  # before IO; a chat adapter persists the parsed fields with its retry key.
  module ScheduleCommands
    USAGE = "list | show ID | history ID | create once in DURATION TEXT | create once at TIME TEXT | " \
      "create every DURATION TEXT | create daily HH:MM IANA_ZONE TEXT | edit ID prompt TEXT | " \
      "edit ID once in DURATION|once at TIME|every DURATION|daily HH:MM IANA_ZONE | pause ID | resume ID | cancel ID".freeze
    Command = Data.define(:action, :id, :fields)

    class << self
      def parse(argument, now:)
        action, rest = argument.to_s.strip.split(/\s+/, 2)
        action ||= "list"
        case action
        when "list"
          Command.new(action: action, id: nil, fields: { after: rest }.compact)
        when "show", "pause", "resume", "cancel"
          id, extra = rest.to_s.split(/\s+/, 2)
          raise Rho::Error, USAGE if id.to_s.empty? || extra

          Command.new(action: action, id: id, fields: {})
        when "history"
          id, after = rest.to_s.split(/\s+/, 2)
          Command.new(action: action, id: required(id), fields: { after: after }.compact)
        when "create"
          rule, prompt = parse_rule(rest, now: now.to_f)
          Command.new(action: action, id: nil, fields: { prompt: required(prompt), rule: rule })
        when "edit"
          id, field, text = rest.to_s.split(/\s+/, 3)
          fields = if field == "prompt"
            { prompt: required(text) }
          else
            rule, extra = parse_rule([field, text].compact.join(" "), now: now.to_f)
            raise Rho::Error, USAGE if extra

            { rule: rule }
          end
          Command.new(action: action, id: required(id), fields: fields)
        else
          raise Rho::Error, USAGE
        end
      end

      def execute(core, conversation_id, command, workspace_public_id: nil, model: nil, approval_mode: nil,
                  tool_names: nil, to: nil, speaker_public_id: nil, idempotency_key: nil)
        scope = { workspace_public_id: workspace_public_id }
        case command.action
        when "list" then core.schedules(conversation_id, **command.fields, **scope)
        when "show" then core.schedule(conversation_id, command.id, **scope)
        when "history" then core.schedule_executions(conversation_id, command.id, **command.fields, **scope)
        when "create"
          core.create_schedule(conversation_id, **command.fields, model: model, approval_mode: approval_mode,
            tool_names: tool_names, to: to, speaker_public_id: speaker_public_id,
            idempotency_key: idempotency_key || SecureRandom.uuid, **scope)
        when "edit"
          current = core.schedule(conversation_id, command.id, **scope)
          core.update_schedule(conversation_id, command.id, **command.fields,
            expected_lock_version: current.fetch("lock_version"), **scope)
        when "pause", "resume", "cancel"
          core.public_send("#{command.action}_schedule", conversation_id, command.id, **scope)
        else
          raise ArgumentError, "unknown scheduled job action: #{command.action}"
        end
      end

      def render(command, result)
        case command.action
        when "list"
          rows = result.fetch("schedules")
          lines = rows.empty? ? ["No scheduled jobs."] : rows.map { |row| summary(row) }
          cursor = result.dig("pagination", "next_after")
          lines << "More jobs: list #{cursor}" if cursor
          lines.join("\n")
        when "history"
          rows = result.fetch("executions")
          lines = rows.empty? ? ["No executions yet."] : rows.map do |row|
            "#{row.fetch("child_conversation_public_id")} · #{row["status"] || "pending"} · #{row["scheduled_for"]}"
          end
          cursor = result.dig("pagination", "next_after")
          lines << "More executions: history #{command.id} #{cursor}" if cursor
          lines.join("\n")
        else
          lines = [summary(result), result.fetch("prompt"), "Rule: #{JSON.generate(result.fetch("rule"))}"]
          lines << "Last error: #{result.fetch("last_error_code")}" if result["last_error_code"]
          lines << "Last enqueued: #{result.fetch("last_enqueued_at")}" if result["last_enqueued_at"]
          if (execution = result["last_execution"])
            lines << "Latest execution: #{execution.fetch("status")} · #{execution.fetch("child_conversation_public_id")}"
          end
          lines.join("\n")
        end
      end

      private

        def required(value)
          text = value.to_s
          raise Rho::Error, USAGE if text.empty?

          text
        end

        def parse_rule(text, now:)
          kind, rest = text.to_s.split(/\s+/, 2)
          case kind
          when "once"
            mode, value, prompt = rest.to_s.split(/\s+/, 3)
            raise Rho::Error, USAGE unless %w[in at].include?(mode)

            [{ "kind" => "once", "run_at" => Gateway::DeliveryTime.resolve("#{mode} #{required(value)}", now: now) }, prompt]
          when "every"
            duration, prompt = rest.to_s.split(/\s+/, 2)
            seconds = Gateway::DeliveryTime.duration_seconds(required(duration))
            raise Rho::Error, "The interval must be positive" unless seconds.positive?
            [{ "kind" => "interval", "every_seconds" => seconds,
               "starts_at" => Time.at(now + seconds).utc.iso8601 }, prompt]
          when "daily"
            local_time, time_zone, prompt = rest.to_s.split(/\s+/, 3)
            [{ "kind" => "daily", "local_time" => required(local_time), "time_zone" => required(time_zone) }, prompt]
          else
            raise Rho::Error, USAGE
          end
        end

        def summary(row)
          title = row["name"] || row.fetch("prompt").lines.first.to_s.strip
          "#{row.fetch("public_id")} · schedule: #{row.fetch("status")} · #{title} · next: #{row["next_run_at"] || "none"}"
        end
    end
  end
end
