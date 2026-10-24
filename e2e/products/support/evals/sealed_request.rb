require "json"

module E2E
  module Evals
    module SealedRequest
      NOT_SEALED = "request_not_sealed".freeze
      OPTIONS_HEADING = "request_options:".freeze
      ENTRIES_HEADING = "entries:".freeze
      # What opens a delivered result's user entry — a task's envelope or a person's answer — and
      # what its opening line says of a task the kernel canceled.
      ENVELOPE_OPENINGS = ["<task_result ", "<answer "].freeze
      CANCELED_STATUS = ' status="canceled"'.freeze
      TASK_ATTRIBUTE = /\btask="([^"]*)"/

      module_function

      def path(loop_path, key) = "#{loop_path}/tasks/#{key}/request"
      def key_for(tasks, mainline_keys: nil)
        last_completed_round(tasks, among: mainline_keys)
      end

      # The last round that COMPLETED, in the loop row's order — among the
      # keys given (the graph's mainline), or the mainline's and a branch's
      # alike without them; nil on a loop no round finished (a `rho do`
      # that never got a first answer).
      def last_completed_round(tasks, among: nil)
        rows = Array(tasks).select { |row| row["kind"] == "model_task" && row["status"] == "completed" }
        rows = rows.select { |row| among.include?(row["key"]) } if among
        rows.last&.fetch("key")
      end

      # The route's document as the trace keeps it: `{task_key, entries,
      # request_options}`; nil when the kernel answered an error (a task
      # with nothing sealed is `request_not_sealed`).
      def from_document(document, key)
        sealed = Hash(document)["request"]
        return nil if sealed.nil?

        { "task_key" => key, "entries" => Array(sealed["entries"]), "request_options" => Hash(sealed["request_options"]) }
      end

      # `bytes`: the entries' JSON, as stored — nil without a sealed request.
      def bytes(sealed)
        return nil if sealed.nil?

        JSON.generate(sealed.fetch("entries")).bytesize
      end

      def tail_envelopes(sealed)
        return nil if sealed.nil?

        entries = sealed.fetch("entries")
        last = entries.rindex { |entry| entry["role"] == "assistant" }
        tail = last.nil? ? entries : entries.drop(last + 1)
        opened = tail.select { |entry| entry["role"] == "user" }.map { |entry| text_of(entry) }
          .select { |text| text.start_with?(*ENVELOPE_OPENINGS) }
        { "envelopes" => opened.size, "tasks" => opened.map { |text| text.lines.first[TASK_ATTRIBUTE, 1] },
          "canceled" => opened.filter_map { |text| canceled_task(text.lines.first) },
          "assistant" => entries.count { |entry| entry["role"] == "assistant" }, "bytes" => JSON.generate(tail).bytesize }
      end

      def text_of(entry) = Array(entry["parts"]).map { |part| part["text"].to_s }.join

      def canceled_task(line) = (line[TASK_ATTRIBUTE, 1] if line.include?(CANCELED_STATUS))
      private_class_method :text_of, :canceled_task

      # The names the round declared, in wire order; empty when the request
      # carried no tools (a text-only round).
      def tool_names(sealed)
        return [] if sealed.nil?

        Array(sealed.dig("request_options", "tools")).filter_map { |tool| tool.dig("function", "name") || tool["name"] }
      end

      # `rho request`'s print, read back: the two headings in order, the
      # entries parsed from the pretty JSON after the second — equal to the
      # route's, or the reason they are not.
      def cli_agrees(printed, sealed)
        text = printed.to_s
        return "rho request printed no #{OPTIONS_HEADING} heading:\n#{text[0, 300]}" unless text.start_with?(OPTIONS_HEADING)

        entries_at = text.index("\n#{ENTRIES_HEADING}\n")
        return "rho request printed no #{ENTRIES_HEADING} heading" if entries_at.nil?

        entries = JSON.parse(text[(entries_at + ENTRIES_HEADING.length + 2)..])
        entries == sealed.fetch("entries") ? true : "rho request printed #{entries.size} entries where the route served #{sealed.fetch("entries").size}"
      rescue JSON::ParserError => error
        "rho request's entries did not parse: #{error.message[0, 120]}"
      end
    end
  end
end
