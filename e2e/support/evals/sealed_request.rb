require "json"

module E2E
  module Evals
    # THE SEALED REQUEST ON EVERY RUN: the bytes the last completed round was sent, read off the
    # debug door `GET …/tasks/{key}/request` — `{request: {entries, request_options}}`, derived from
    # the sealed body, never re-assembled (`docs/agent-api/v1/agent_loops.md:353-361`) — success or
    # red alike, and written beside the trace. Two columns come off it: the request's BYTES
    # (`bytes`: the entries as the kernel stored them, in JSON) and the tool names the model
    # actually saw (`request_options.tools`, the wire entries `schedule_ready.rb:365` stored) — the
    # compose scorer's `tool_names` since V3, so a script is judged against the set the round
    # declared, never the set a style word implies. `rho request LOOP KEY` prints the same two keys
    # (`extensions/ops/commands.rb:200-218`); the lane runs it once per run so the CLI door is
    # exercised (drive the CLI, not the route).
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
      # The kernel's wire name for the compose verb (`Trace::COMPOSE`; an
      # aliased call resolves to it on the task row).
      COMPOSE = "compose".freeze

      # THE KEY TO SEAL: the round that MADE the compose call — the row's `after` names it
      # (`shapes.rb:343`) — so the compose scorer's "the set the model saw" is literal on the
      # artifact; else the last completed round, over `spine_keys` when the caller has the graph's
      # marks.
      def key_for(tasks, spine_keys: nil)
        calling = Array(tasks).find { |row| row["kind"] == "tool_task" && row["tool_name"] == COMPOSE }&.dig("after", 0)
        calling || last_completed_round(tasks, among: spine_keys)
      end

      # The last round that COMPLETED, in the loop row's order — among the
      # keys given (the graph's spine), or the spine's and a branch's
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

      # THE ENVELOPES A REQUEST'S TAIL DELIVERED: over the entries after the last assistant entry —
      # every entry when there is none — `envelopes` counts the user entries whose text opens a
      # delivered element (`<task_result ` or `<answer `), `tasks` names the task each opening line
      # names and `canceled` the task of each whose opening line says `status="canceled"`, in order,
      # and `bytes` is the tail's entries as JSON; `assistant` counts the assistant entries of the
      # whole request. The tail is what the round itself was handed: a round that continues an
      # earlier one replays its request and reply first, and a composed step, which continues no
      # one, carries no assistant entry at all (`ComposedReads.check`). nil without a sealed request.
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
