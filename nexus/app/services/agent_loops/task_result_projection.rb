module AgentLoops
  # The stored result has one projection for task reads and pure script inputs.
  module TaskResultProjection
    module_function

    # Successful barriers contribute their frozen winners, not the branches
    # still running under run_out. A failed barrier reports its own failure,
    # and a failed race first what it captured before failing — its partial
    # winners — so the wait tool, detached delivery, a stage and a model
    # step each read one selection. Every tip in finish order: the first
    # finisher first, and a failed race's failure after its winners.
    def tips(agent_loop, sinks, unmailed: false)
      tips = []
      seen = Set.new
      frontier = sinks.dup
      # Each row is visited once; the fixed graph bounds the walk.
      until frontier.empty?
        winners = frontier.select { |node| seen.add?(node.id) }.flat_map do |node|
          if node.join_mode.present? && node.status == "completed"
            node.winning_source_keys
          else
            if (!unmailed || node.mailed_at.nil?) &&
                (Tasks::Append::READABLE_TYPES.include?(node.type) || node.failure?)
              tips << node
            end
            node.race? && node.failure? ? node.winning_source_keys : []
          end
        end
        frontier = agent_loop.agent_loop_nodes.where(node_key: winners.uniq).to_a
      end
      tips.sort_by { |node| [node.completed_at, node.id] }
    end

    # WHAT A READER NAMING `node` READS: a leaf itself; a race what it
    # selected (`tips`) — or its own row when it selected nothing, as a
    # person's resolving cancel leaves it, so a reader never reads an
    # empty slot.
    def referenced(node)
      return [node] unless node.race?

      selection = tips(node.agent_loop, [node])
      selection.empty? ? [node] : selection
    end

    # The rows a reader naming `nodes` reads, in order and once each.
    # `expanded` carries each race's one walk across a batch of readers,
    # so a history of many rounds naming one race reads it once.
    def readings(nodes, expanded = {})
      nodes.flat_map { |node| expanded[node.id] ||= referenced(node) }.uniq(&:id)
    end

    # A STAGE'S `results[i]`: a leaf's envelope; a race's is ENVELOPE-SHAPED
    # — the first envelope it selected at the top level, or its own failure
    # when it failed or selected nothing, so `results[i].status` is never a
    # silent read of a list — and `selected`, every envelope it hands a
    # reader (`referenced`), first finisher first. `selection` is that
    # list when the caller already loaded it.
    def slot(node, selection = referenced(node))
      return call(node) unless node.race?

      selected = selection.map { |tip| call(tip) }
      head = node.status == "completed" ? selected.first : call(node)
      head.merge("selected" => selected)
    end

    def call(node)
      body = node.output_body
      payloads = entry_payloads(body)
      {
        "status" => TaskProjection.public_status(node.status),
        "is_error" => !!node.output_summary.fetch("is_error", false),
        "output" => body&.effective_text,
        "content" => content_blocks(payloads)&.map(&:stringify_keys),
        "structured_content" => structured_content(payloads),
        "error" => (node.error_key && { "key" => node.error_key, "detail" => node.error_detail }),
      }
    end

    def entry_payloads(body)
      body&.entry_payloads || []
    end

    def content_blocks(payloads)
      payloads.filter_map do |payload|
        text = payload[Parks::ResultContent::TEXT]
        link = payload[Parks::ResultContent::RESOURCE_LINK]
        if text then { type: "text", text: text }
        elsif link then resource_link_block(link)
        end
      end.presence
    end

    def resource_link_block(link)
      {
        type: Parks::ResultContent::RESOURCE_LINK,
        uri: link.fetch("uri"), name: link.fetch("name"),
        mimeType: link["mimeType"], title: link["title"], description: link["description"],
        size: link["size"],
      }.compact
    end

    # A returned false or null is data, not an absent entry.
    def structured_content(payloads)
      entry = payloads.reverse.find { |payload| payload.key?(Parks::ResultContent::STRUCTURED) }
      entry&.fetch(Parks::ResultContent::STRUCTURED)
    end
  end
end
