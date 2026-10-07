module Conversations
  # A side's immutable reading of unfinished work, owned by its ordinary fork
  # variant. Entries store messages or complete round facts, not executable rows
  # or already chosen native replay. Every later target uses the ordinary history
  # placement, replay and funding rules over this sealed content.
  module ReferenceSnapshot
    ROLE = "reference".freeze
    Capture = Data.define(:segments, :carries_preface, :uploads)
    Segment = ContextAssembly::Segment
    AttachmentLine = ContextAssembly::AttachmentLine

    module_function

    # The source conversation and, when present, its run are locked by Fork.
    # Stream deltas are not durable content; only stored bodies and task states
    # appear here. Nothing remains linked to the source's mutable graph.
    def capture(turn:, source:, target:)
      captured = ContextAssembly::ChatHistory.reference(turn: turn, variant: source)
      progress = progress_segment(turn, source.agent_run)
      segments = captured.segments + [progress]
      entries = [{ "kind" => "context", "carries_preface" => captured.carries_preface,
                   "summary_entries" => capture_summary(turn, source, target, captured) }] +
        segments.map { |segment| encode(segment) }
      uploads = (captured.uploads + segments.flat_map(&:attachments).map(&:upload)).uniq(&:id)
      ContentBodies::Replace.archive(owner: target, role: ROLE, entries: entries, uploads: uploads)
      # The existing turn read exposes a text projection of the same frozen
      # material, so a later summary can point back to a readable reference.
      text = [progress.text, *captured.segments.map { |segment| display(segment) }].compact.join("\n\n")
      ContentBodies::Replace.archive(owner: target, role: "content",
        entries: [{ "text" => text }], readable_text: text)
      target.update_content_preview(text)
    end

    def read(body, carries: nil)
      entries = body.entry_payloads
      uploads = body.content_uploads.index_by(&:public_id)
      Capture.new(
        carries_preface: entries.first.fetch("carries_preface"),
        segments: entries.drop(1).filter_map { |entry| decode(entry, uploads, carries) },
        uploads: uploads.values
      )
    end

    # Another answerer receives the parent's prose and progress in its speaker
    # envelope, as it does for any peer turn. Its preface and tool work remain
    # available in the human read without becoming that peer's model history.
    def peer_text(body)
      entries = body.entry_payloads.drop(1)
      entries.filter_map do |entry|
        case entry.fetch("kind")
        when "round" then entry["text"].presence
        when "message"
          message = Nexus::TextInputMessage.from_h(entry.fetch("message"))
          if message.role == "assistant" || entry.equal?(entries.last)
            Nexus::ModelRequestInput.text_segments([message]).join("\n").presence
          end
        else raise ArgumentError, "unknown reference entry kind: #{entry.fetch("kind")}"
        end
      end.join("\n\n")
    end

    # The source-aware serializer distinguished selected tool results from
    # ask answers and model words before their ordinary history messages were
    # frozen. Read that same immutable projection after source retention.
    def summary_entries(body)
      body.entry_payloads.first.fetch("summary_entries")
    end

    def capture_summary(turn, source, target, captured)
      pointers = captured.segments.flat_map(&:picture_parts).map(&:upload).uniq(&:id).map do |upload|
        AttachmentLine.render(upload, AttachmentLine::NOT_CARRIED)
      end
      ["For original tool values, re-read conversation turn #{target.conversation_turn.public_id} " \
        "in this conversation; it retains this frozen parent work.",
       *Compaction::Serialize.reference_entries(turn: turn, variant: source),
       *pointers, progress_segment(turn, source.agent_run, detail: false).text]
    end

    def display(segment)
      text = Nexus::ModelRequestInput.text_segments(segment.elements).join("\n")
      "#{segment.role.capitalize}:\n#{text}" if text.present?
    end

    def progress_segment(turn, agent_run, detail: true)
      lines = ["[Parent turn reference snapshot: turn status #{turn.status}" \
        "#{"; run status #{agent_run.status}" if agent_run}. " \
        "This records persisted work at the fork; the parent keeps its execution.]"]
      if agent_run
        agent_run.agent_run_tasks.where.not(transcript_visibility: "hidden")
          .where(status: AgentRunTask::LIVE_STATUSES + AgentRunTask::FAILURE_STATUSES)
          .order(:id).each do |node|
            next if node.terminal? && !node.unresolved_failure?

            label = node.tool_call? ? node.called_name : node.task_kind
            error = [node.error_key, (node.error_detail if detail)].compact_blank.join(": ")
            lines << "Task #{node.node_key} (#{label}): #{AgentRuns::TaskProjection.public_status(node.status)}" \
              "#{" — #{error}" if node.error_key.present?}."
          end
      end
      Segment.plain("user", lines.join("\n"), alone: true)
    end

    def encode(segment)
      if round?(segment)
        {
          "kind" => "round",
          "role" => segment.role,
          "text" => round_text(segment),
          "calls" => Nexus::InputEntries.for(segment.call_items),
          "results" => Nexus::InputEntries.for(segment.result_items),
          "trace" => segment.trace&.envelope,
          "pictures" => segment.picture_parts.map { |part| part.upload.public_id },
          "pairs_only" => !segment.words? && placed_messages(segment).empty?,
        }
      else
        message = Nexus::TextInputMessage.new(role: segment.role, parts: encoded_parts(segment.parts),
          phase: segment.phase, native_origin: (segment.trace.native_origin if segment.phase))
        { "kind" => "message", "message" => message.to_h,
          "trace" => segment.trace&.envelope, "alone" => segment.alone }
      end
    end

    def round?(segment)
      segment.call_items.any? || segment.result_items.any? || segment.trailing.any? || !segment.first_slot.nil?
    end

    def encoded_parts(parts)
      parts.map { |part| part.type == Nexus::InputParts::UPLOAD ? part.to_part : part }
    end

    # Placement keeps a phased answer in its own messages. A single marker
    # reads the output body's whole text; several markers carry their own words.
    def round_text(segment)
      segment.text.presence || Nexus::ModelRequestInput.text_segments(placed_messages(segment)).join.presence
    end

    def placed_messages(segment)
      segment.trailing.filter_map do |_ordinal, element|
        element if element in Nexus::TextInputMessage
      end
    end

    def decode(entry, uploads, carries)
      trace = entry["trace"] && ModelReasoning::Trace.new(envelope: entry.fetch("trace"))
      case entry.fetch("kind")
      when "message"
        message = Nexus::TextInputMessage.from_h(entry.fetch("message"))
        Segment.plain(message.role, nil, parts: placed_parts(message.parts, uploads, carries),
          trace: trace, phase: message.phase, alone: entry.fetch("alone"))
      when "round"
        calls = entry.fetch("calls").map { |call| Nexus::ToolCallInputItem.from_h(call) }
        placed = AgentRuns::RoundReplay::Placement.call(trace: trace, natives: [], calls: calls,
          text: entry["text"], messages: !entry.fetch("pairs_only"))
        text = entry["text"] unless placed.phased || entry.fetch("pairs_only")
        pictures = entry.fetch("pictures").map { |id| uploads.fetch(id) }
        Segment.round(entry.fetch("role"), text, calls: placed.call_items,
          trailing: placed.trailing, first_slot: placed.first_slot,
          results: entry.fetch("results").map { |result| Nexus::ToolResultInputItem.from_h(result) },
          trace: trace, picture_parts: AttachmentLine.parts(pictures, carries: carries))
      else raise ArgumentError, "unknown reference entry kind: #{entry.fetch("kind")}"
      end
    end

    def placed_parts(parts, uploads, carries)
      parts.map do |part|
        if part.type == Nexus::InputParts::UPLOAD
          AttachmentLine.parts([uploads.fetch(part.upload_public_id)], carries: carries).sole
        else
          part
        end
      end
    end
  end
end
