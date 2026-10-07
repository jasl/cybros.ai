module AgentRuns
  module Tasks
    class Append
      # Replaces a queued consumer's logical source as that source grows. Waits,
      # ordinary history/material and selected results keep their separate roles.
      # A waited head reads what no step of the envelope read; a replaced row's
      # readers read the replacement's final waits, routed by kind.
      class Splice
        def self.replace_reads(agent_run:, replaces:, reads:)
          new(agent_run).replace_reads(replaces, reads)
        end

        def initialize(agent_run, command = nil, compiled = nil, created = {})
          @agent_run = agent_run
          @command = command
          @compiled = compiled
          @created = created
        end

        def call
          return [] if @command.head.nil? && @command.replaces.nil?
          raise Refused, :splice_not_permitted if @command.authored

          finish = @compiled.tip
          waits = finish.waits.map(&:key).select { |key| @created.key?(key) }

          heads = []
          if @command.head
            # Append holds the loop throughout; its queued consumers share
            # that lock, including the named head and replaced readers. A
            # kernel head that hands waits alone (a hook's tool, a summarizer)
            # reads nothing of what it waits on.
            head = @agent_run.agent_run_tasks.find_by(node_key: @command.head)
            raise Refused, :unknown_splice_head if head.nil?

            ordinary, results = @command.splice_reads ? routed(unread) : [[], []]
            splice_head(head, waits, ordinary, results, nil)
            heads << head
          end
          return heads if @command.replaces.nil?

          ordinary, results = routed(waits)
          consumers = Array(@command.replaces).flat_map do |key|
            root = @agent_run.agent_run_tasks.find_by!(node_key: key)
            edges = root.outgoing_edges.includes(:to_node).index_by(&:to_node_id)
            readers = (edges.values.map(&:to_node) + readers_of(root.node_key)).uniq(&:id)
              .select { |node| node.status == "queued" && !@created.key?(node.node_key) }
            readers.each do |head|
              edge = edges[head.id]
              splice_head(head, edge ? waits : [], ordinary, results, root.node_key,
                structural: edge&.structural)
            end
            readers
          end
          (heads + consumers).uniq(&:id)
        end

        def replace_reads(replaces, reads)
          readers = readers_of(replaces).where(status: "queued").to_a
          readers.each { |head| rewrite_reads(head, reads, [], replaces, result_tail: reads) }
          # Bulk slot rewrites bypass model callbacks. Enlist the held loop so
          # its commit hook flushes narration after the remaining business locks.
          @agent_run.touch unless readers.empty?
          Transition.spliced(@agent_run, readers)
        end

        private

          # WHAT NO STEP OF THE ENVELOPE READ, in placement order — the one rule
          # over the compiled payloads (`Delivery.compiled`). A step the
          # envelope does not wait for (its own `detached`) is the wake's to
          # deliver, never the waited head's; inside a detached branch every
          # row carries the branch's word, and the head is its own.
          def unread
            payloads = @compiled.nodes
            waited = payloads.select { |payload| @command.tip.detached || !payload["detached"] }
            Delivery.compiled(payloads, waited.map { |payload| payload["node_key"] })
          end

          # A stage's value and a race's selection are results; every other
          # row — a tool, an ask, a wait, a model — is ordinary material.
          def routed(keys)
            keys.partition do |key|
              node = @created.fetch(key)
              !node.race?
            end
          end

          def readers_of(key)
            @agent_run.agent_run_tasks.where(
              "? = ANY (input_from_node_keys) OR ? = ANY (result_from_node_keys)", key, key
            )
          end

          def splice_head(head, waits, ordinary, results, replaces, structural: true)
            raise Refused, :splice_head_not_queued unless head.status == "queued"
            raise Refused, :splice_would_cycle if
              @compiled.edges.any? { |edge| edge["from_key"] == head.node_key } ||
              @compiled.nodes.any? do |payload|
                (Array(payload["input_from_node_keys"]) + Array(payload["result_from_node_keys"]))
                  .include?(head.node_key)
              end

            sources = @agent_run.agent_run_tasks.where(node_key: waits).index_by(&:node_key)
            if head.join_mode.present?
              move_join_edge(head, replaces, waits.map { |key| sources.fetch(key) })
            else
              waits.each { |key| add_edge(sources.fetch(key), head, structural) }
              tail = @compiled.tip.waits.map(&:key).select { |key| @created.key?(key) }
              if Array(head.result_from_node_keys).include?(replaces)
                raise Refused, :result_requires_single_leaf unless
                  tail.one? && READABLE_TYPES.include?(@created.fetch(tail.sole).type)
              end
              rewrite_reads(head, ordinary, results, replaces, result_tail: tail)
            end
            Release.recompute(head.reload)
          end

          # A join counts settlements: moving its source keeps a race from
          # ending on an expansion manifest while its children still run.
          def move_join_edge(head, replaces, sources)
            replaced = head.incoming_edges.joins(:from_node)
              .find_by(agent_run_tasks: { node_key: replaces })
            raise Refused, :unknown_splice_source if replaced.nil?

            replaced.delete
            sources.each { |source| add_edge(source, head, replaced.structural) }
          end

          def add_edge(source, head, structural)
            edge = @agent_run.agent_run_edges.find_by(from_node_id: source.id, to_node_id: head.id)
            if edge
              # Endpoint deduplication preserves authored placement when the
              # same edge was also requested as a wait or selected result.
              AgentRunEdge.where(id: edge.id).update_all(structural: true) if structural && !edge.structural
            else
              @agent_run.agent_run_edges.create!(from_node: source, to_node: head, structural: structural)
            end
          end

          def rewrite_reads(head, ordinary, implicit_results, replaces, result_tail:)
            current = Array(head.input_from_node_keys)
            selected = Array(head.result_from_node_keys)
            inputs = spliced_reads(current, ordinary, replaces)
            results = replaces ? spliced_reads(selected, result_tail, replaces) : selected
            if replaces.nil? || current.include?(replaces)
              results = (implicit_results - results) + results
            end
            return if inputs == current && results == selected
            raise Refused, :too_many_reads if (inputs + results).uniq.length > Compile::KERNEL_MAX_INPUT_FROM

            validate_sources(inputs, result: false)
            validate_sources(results, result: true)
            # These are the only sanctioned rewrites of the immutable authored
            # slots: the same logical work now has a later concrete result.
            AgentRunTask.where(id: head.id).update_all(
              input_from_node_keys: inputs.presence, result_from_node_keys: results.presence,
              updated_at: Time.current
            )
          end

          # The splice is the kernel's own rewrite: a failed race may stand as
          # material, and a race named as a result keeps reading its selection.
          def validate_sources(keys, result:)
            sources = @agent_run.agent_run_tasks.where(node_key: keys).index_by(&:node_key)
            keys.each do |key|
              source = sources[key]
              raise Refused, :unknown_input_source if source.nil?
              raise Refused, :invalid_input_from_source if
                Append.unreadable_source?(source, result: result, authored: false)
            end
          end

          def spliced_reads(current, reads, replaces)
            if replaces
              current.flat_map { |key| key == replaces ? reads : [key] }.uniq
            else
              (current + reads).uniq
            end
          end
      end
    end
  end
end
