module Conversations
  # A reply's accepted follow-ups are user content, not disposable tool
  # evidence. Keep the same immutable fragments on its variant before the
  # graph expires. The aggregate has no cumulative admission ceiling;
  # consumers page its entries instead of rendering the entire body.
  module RetainedSteers
    ROLE = "steers".freeze
    PAGE_SIZE = 100

    module_function

    # Called under the conversation and loop locks when the reply settles,
    # or before retention removes a replaced candidate that did not settle again.
    def archive(agent_run)
      variant = agent_run.conversation_turn_variant
      return if variant.nil? || variant.content_bodies.exists?(role: ROLE)

      body = nil
      position = 0
      bytes = 0
      bodies = 0
      rounds = agent_run.agent_run_tasks.where(type: AgentRunTasks::ModelTask.sti_name)
        .where("continuation_source IS DISTINCT FROM ?", AgentRunTasks::ModelTask::BRANCH)
      rounds.includes(:content_bodies).find_each(batch_size: PAGE_SIZE) do |round|
        source = round.content_bodies.find { |candidate| candidate.role == ROLE }
        next unless source

        body ||= variant.content_bodies.create!(role: ROLE)
        source.content_body_entries.reorder(:position).in_batches(of: PAGE_SIZE) do |entries|
          rows = entries.order(:position).pluck(:content_fragment_id).map do |fragment_id|
            row = { account_id: body.account_id, content_body_id: body.id,
              content_fragment_id: fragment_id, position: position }
            position += 1
            row
          end
          ContentBodyEntry.insert_all!(rows)
        end
        source.content_body_uploads.pluck(:content_upload_id).each_slice(PAGE_SIZE) do |ids|
          rows = ids.map { |upload_id| { content_body_id: body.id, content_upload_id: upload_id } }
          ContentBodyUpload.insert_all(rows)
        end
        bytes += source.byte_size.to_i
        bodies += 1
      end
      return unless body

      body.update!(byte_size: bytes + bodies - 1)
      body.seal
      body
    end

    # Only the newest bounded entry window is needed for prompt assembly.
    # The originals remain pageable/searchable without loading a giant body.
    def messages(variant_id, limit: PAGE_SIZE)
      messages_by_variant([variant_id], limit: limit).fetch(variant_id, [])
    end

    def messages_by_variant(variant_ids, limit: PAGE_SIZE)
      owners = ContentBody.where(conversation_turn_variant_id: variant_ids, role: ROLE)
        .pluck(:id, :conversation_turn_variant_id).to_h
      return {} if owners.empty?

      window = ContentBodyEntry.where(content_body_id: owners.keys).select(
        "content_body_entries.*",
        "ROW_NUMBER() OVER (PARTITION BY content_body_id ORDER BY position DESC) AS entry_rank"
      )
      entries = ContentBodyEntry.from(window, :ranked).select("ranked.*")
        .where("ranked.entry_rank <= ?", limit).order(:content_body_id, :position)
        .includes(:content_fragment).group_by(&:content_body_id)
      entries.to_h do |body_id, rows|
        [owners.fetch(body_id), Array(Nexus::InputEntries.from(
          entries: rows.map { |entry| entry.content_fragment.payload }, workload: "text_generation"
        ))]
      end
    end
  end
end
