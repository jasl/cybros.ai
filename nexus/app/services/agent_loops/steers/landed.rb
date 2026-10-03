module AgentLoops
  module Steers
    # Consumed input rows disappear, so retry, history reconstruction and
    # summaries share this durable tail. It keeps rendered speaker envelopes
    # and original pictures; the sealed request records the model's placement.
    module Landed
      ROLE = "steers".freeze

      module_function

      # The composed tail, before the model's attachment placement. A retry
      # replaces this with its combined tail; the original pictures stay bound
      # even when this model reads their index lines instead.
      def record(node, elements, uploads: [])
        return if elements.empty?

        placed = elements.flat_map(&:parts).filter_map do |part|
          part.upload_public_id if part.type == Nexus::InputParts::UPLOAD
        end.to_set
        node.content_bodies.where(role: ROLE).destroy_all
        result = ContentBodies::Replace.call(
          owner: node, role: ROLE, entries: Nexus::InputEntries.for(elements),
          uploads: uploads.select { |upload| placed.include?(upload.public_id) }, seal: true
        )
        raise ArgumentError, "the landed steers could not be kept: #{result.refusal}" unless result.accepted?

        result.body
      end

      def bodies_by_round(rounds)
        return {} if rounds.empty?

        ContentBody.where(agent_loop_node_id: rounds.map(&:id), role: ROLE)
          .includes({ content_uploads: { file_attachment: :blob } }, content_body_entries: :content_fragment)
          .index_by(&:agent_loop_node_id)
      end

      def texts_by_round(rounds)
        bodies_by_round(rounds).transform_values do |body|
          uploads = body.content_uploads.index_by(&:public_id)
          # Only standalone queued follow-ups can land pictures. Their
          # summary keeps the same pointers as an ordinary input's summary.
          messages_of(body).map do |message|
            message.parts.map do |part|
              if part.type == Nexus::InputParts::UPLOAD
                pointer = Conversations::ContextAssembly::AttachmentLine.render(
                  uploads.fetch(part.upload_public_id), Conversations::ContextAssembly::AttachmentLine::NOT_CARRIED
                )
                "\n#{pointer}\n"
              else
                part.text
              end
            end.join
          end
        end
      end

      def messages_of(body)
        Array(Nexus::InputEntries.from(
          entries: body.content_body_entries.map { |entry| entry.content_fragment.payload },
          workload: "text_generation"
        ))
      end
    end
  end
end
