module AgentLoops
  class RoundReplay
    # The pairing law's rendering half: no crash can put an unanswered call on
    # the wire (codex, claude-code and opencode all guarantee it here). Results
    # ride in call order, and the walk is driven by the calls, so no orphan
    # enters — and a call whose fan never answered (a held or canceled turn's
    # dangling call) closes with the kernel's envelope.
    module Pairing
      # Reason-typed, so the model can tell "cut off" from "never run".
      REASONS = {
        "canceled" => "The tool call was aborted before it completed.",
        "skipped" => "The tool call was not executed.",
        "failed" => "The tool call could not run.",
        "timed_out" => "The tool call exceeded its deadline.",
        # The flat-call twin of the envelope's sentence: what a weak model
        # reads is the whole product of `uncertain`.
        "uncertain" => "The tool call's executor expired without a result; " \
          "its effect may have happened. Check before calling it again.",
      }.freeze
      # Layered above the status sentence by `error_key`: every reference
      # says WHO refused — "could not run" makes a weak model retry
      # unchanged. Model-facing names are load-bearing.
      ERROR_KEY_REASONS = {
        "approval_denied" => "This tool call was declined by the approver; do not run it again unchanged.",
        "approval_expired" => "Nobody approved this tool call before it expired.",
        # The tool RAN: "could not run" would make the model retry it unchanged.
        "result_unstorable" => "This tool call ran, but its result could not be stored and is lost; " \
          "its effect may have happened.",
      }.freeze
      UNANSWERED = "The tool call did not complete before the round ended.".freeze
      # The prune arm's placeholder: a result outside the keep-recent tail,
      # cleared to fit — the call stays, so the model can make it again;
      # claude-code's microcompact says the same.
      CLEARED = "[Older tool result cleared to fit the context window; call the tool again if you need it]".freeze
      # An error is BOTH marked in the content and flagged on the payload
      # (claude-code toolExecution.ts sends both): the marker is the
      # signal on wires without a field, the `is_error` flag is what the
      # Anthropic wire's `tool_result.is_error` reads; the fixed-key
      # Responses and Gemini builders drop the flag.
      ERROR_OPEN = "<tool_use_error>".freeze
      ERROR_CLOSE = "</tool_use_error>".freeze

      # The round's results in call order, and THE RIDER: the pictures
      # its completed results captured, as ONE picture-only user message
      # (nil when there are none) the reader places AFTER the round's
      # last result. Once per round, never per result: the Anthropic
      # lowering merges adjacent user content into one message, whose
      # `tool_result` blocks must lead — a picture between two results is
      # a shape that wire refuses. Wire-agnostic: the same next-turn
      # message shape, placed per part at assembly (the catalog admits
      # `image` → the part stays; else the ruled index line) and bound by
      # the seal like any placed row.
      Rendered = Data.define(:items, :picture)

      module_function

      # nodes_by_call_id is scoped by the caller to this round's own fan: a
      # reused call id must never resurrect a stale result. A blocking
      # `task` call whose branch tip the reader holds answers with the tip's
      # envelope — the branch's last word IS the call's result. A CLEARED
      # round answers every call that has a result with the placeholder:
      # calls and words stay, results go — and so do its pictures.
      def call(calls:, nodes_by_call_id:, tips_by_call_key: {}, cleared: false)
        paired = calls.map do |entry|
          call_id = entry["id"].to_s
          node = nodes_by_call_id[call_id]
          tip = node && tips_by_call_key[[node.agent_loop_id, node.node_key]]
          output, errored = paired_output(node, tip, cleared)
          [item(call_id: call_id, name: entry["name"], output: output, is_error: errored),
           (node if pictured?(node, tip, cleared))]
        end
        Rendered.new(items: paired.map(&:first), picture: picture_message(paired.filter_map(&:last)))
      end

      # A result whose own words the model reads: settled, not answered by
      # a branch tip, not cleared. Only such a result's captures are shown.
      def pictured?(node, tip, cleared) = !cleared && tip.nil? && node&.status == "completed"

      # The completed results' bound captures whose bytes are a PICTURE —
      # the attachment door's own word (`AttachedMessage.image?`: the
      # row's detected type, never the link's `mimeType`) — in result
      # order, each once; a non-media capture is the client's alone and
      # renders nothing here.
      def picture_message(nodes)
        uploads = nodes.filter_map { |node| output_body(node) }
          .flat_map { |body| ordered_pictures(body) }.uniq(&:public_id)
        return nil if uploads.empty?

        Nexus::TextInputMessage.new(role: "user", parts: uploads.map do |upload|
          Nexus::UploadInputPart.new(type: Nexus::InputParts::UPLOAD, upload_public_id: upload.public_id)
        end)
      end

      def pictures(body)
        body.content_uploads.select { |upload| ContentBodies::AttachedMessage.image?(upload) }
      end

      # The join is liveness, not order. A tool can name captures in a
      # different order from their upload ids; the sealed result blocks
      # remain the authority for "first picture" on the next model round.
      def ordered_pictures(body)
        uploads = pictures(body).index_by(&:public_id)
        return [] if uploads.empty?

        entries = body.content_body_entries.to_a
        ActiveRecord::Associations::Preloader.new(records: entries, associations: :content_fragment).call
        Parks::ResultContent::Parsed.link_ids(entries.map { |entry| entry.content_fragment.payload })
          .filter_map { |id| uploads[id] }
      end

      # The text and whether it is an error: a cleared placeholder and a
      # branch tip's envelope are data the model reads, never errors; an
      # unanswered call and every non-completed status are (claude-code
      # marks the same set).
      def paired_output(node, tip, cleared)
        return [CLEARED, false] if cleared && clears?(node)
        return [TaskResultEnvelope.for(tip), false] if tip

        output_and_error_for(node)
      end

      # A prune clears RESULTS. A call that settled without one answers
      # with the kernel's small error envelope, so clearing it frees
      # nothing, and the placeholder would tell the model a result existed —
      # a failure read as a success. The prune arm's arithmetic asks the
      # same question (`Compaction::Serialize::LoopHistory`).
      def clears?(node) = node.nil? || node.status == "completed"

      # The sentence alone, for the readers that quote it (the tests of the
      # approval and status sentences); the flag rides beside it above.
      def output_for(node) = output_and_error_for(node).first

      def output_and_error_for(node)
        return [marked(UNANSWERED), true] if node.nil?

        case node.status
        when "completed" then completed_output(node)
        else [failure_output(node), true]
        end
      end

      # WHY, in the model's own reading order: the reason it can act on,
      # then the kernel's typed key for anyone reading the transcript,
      # then the detail the failing write left for the model — the task
      # read's own public field, so the envelope says what the trace says.
      # `detail: false` leaves the detail out, for a reader that must carry
      # no value (the compaction pointer, for a runner's own words).
      def failure_output(node, detail: true)
        reason = ERROR_KEY_REASONS[node.error_key] || REASONS.fetch(node.status, UNANSWERED)
        key = node.error_key.presence
        marked([reason, key && "(#{key})", (node.error_detail.presence if detail)].compact.join(" "))
      end

      def marked(text) = "#{ERROR_OPEN}#{text}#{ERROR_CLOSE}"

      # A completed task carries its own envelope, is_error included (data,
      # never control); one with no body still answers an empty string.
      def completed_output(node)
        text = output_body(node)&.effective_text.to_s
        # A tool that RAN and errored is completed — its envelope is data
        # the model reacts to, and the marker is what makes it legible.
        node.output_summary["is_error"] ? [marked(text), true] : [text, false]
      end

      def output_body(node) = node.output_body

      # The NAME rides beside the id because one wire resolves a result
      # by name and RAISES when it cannot find one (Gemini's
      # functionResponse); the families that pair by id simply ignore it.
      # `is_error` rides only when true — absent is the clean result.
      def item(call_id:, name:, output:, is_error: false)
        Nexus::ToolResultInputItem.new(
          type: "tool_result_item",
          payload: {
            "type" => "function_call_output",
            "call_id" => call_id,
            "name" => name,
            "output" => output,
            "is_error" => (true if is_error),
          }.compact
        )
      end
    end
  end
end
