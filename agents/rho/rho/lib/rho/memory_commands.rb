require "json"

module Rho
  # Shared human-facing grammar for CLI and chat. The model's six tools remain
  # the kernel's; these commands use the same database doors with version checks.
  module MemoryCommands
    USAGE = 'ls [PATH] | read PATH | write PATH TEXT | edit {"path":"...","old_text":"...","new_text":"..."} | grep PATTERN | delete PATH'.freeze
    Action = Data.define(:verb, :fields) do
      def writing? = %w[write edit delete].include?(verb)
    end

    class << self
      def parse(text)
        verb, argument = text.to_s.split(/\s+/, 2)
        verb ||= "ls"
        fields = case verb
        when "ls" then { path: argument }.compact
        when "read", "delete" then { path: required(argument, "path") }
        when "write"
          path, content = argument.to_s.split(/\s+/, 2)
          { path: required(path, "path"), content: required(content, "content") }
        when "edit"
          value = JSON.parse(required(argument, "JSON containing path, old_text and new_text")).to_h
          { path: required(value.fetch("path"), "path"), old_text: required(value.fetch("old_text"), "old_text"),
            new_text: value.fetch("new_text").to_s }
        when "grep" then { pattern: required(argument, "pattern") }
        else raise Rho::Error, "Use memory #{USAGE}"
        end
        Action.new(verb: verb, fields: fields)
      rescue JSON::ParserError, KeyError, TypeError, NoMethodError
        raise Rho::Error, "Use memory #{USAGE}"
      end

      def execute(core, public_id, action, workspace_public_id: nil)
        fields = action.fields.merge(workspace_public_id: workspace_public_id)
        if action.writing?
          current = existing(core, public_id, fields.fetch(:path), workspace_public_id, create: action.verb == "write")
          fields.merge!(expected_public_id: current&.fetch("public_id"), expected_lock_version: current&.fetch("lock_version"))
        end
        method = action.verb == "ls" ? :memory_list : "memory_#{action.verb}"
        core.public_send(method, public_id, **fields)
      end

      def render(action, result)
        case action.verb
        when "ls"
          result.empty? ? "No memory documents." : result.map { |row| "#{row.fetch("path")} (#{row.fetch("bytesize")} bytes)" }.join("\n")
        when "read" then "#{result.fetch("path")}\n#{result.fetch("content")}"
        when "grep"
          lines = result.fetch("matches").map { |row| "#{row.fetch("path")}:#{row.fetch("line_number")}: #{row.fetch("text")}" }
          lines << "More matches exist; narrow the pattern." if result["truncated"]
          lines.empty? ? "No matches found." : lines.join("\n")
        else "#{action.verb.capitalize} completed: #{action.fields.fetch(:path)}"
        end
      end

      private

        def required(value, name)
          text = value.to_s
          raise Rho::Error, "#{name} is required. Use memory #{USAGE}" if text.empty?

          text
        end

        def existing(core, public_id, path, workspace_public_id, create:)
          core.memory_read(public_id, path: path, workspace_public_id: workspace_public_id)
        rescue Core::Refused => error
          raise unless create && error.status == 404

          nil
        end
    end
  end
end
