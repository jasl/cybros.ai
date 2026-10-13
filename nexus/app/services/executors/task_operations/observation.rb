module Executors
  module TaskOperations
    # Observations seal references to the existing content fragments. A child's
    # later adjudication can replace its output without changing this delivery.
    module Observation
      CANDIDATE_BATCH_SIZE = 32

      Candidate = Data.define(:operation, :nodes) do
        def ready? = Observation.immediate?(operation) || nodes&.all?(&:terminal?)
      end

      module_function

      # The caller holds the Run lock across discovery and consumption. Exclude
      # roots that cannot be ready before loading bounded batches in accepted
      # order; exact standing still decides readiness after any replacement.
      def pending(node)
        return enum_for(:pending, node) unless block_given?

        source = observable_roots(node).order(:position)
        position = 0
        # Position increases across the finite operation set held by the Run lock.
        loop do
          operations = source.where("position > ?", position).limit(CANDIDATE_BATCH_SIZE).to_a
          break if operations.empty?

          candidates(node, operations).each { |candidate| yield candidate }
          break if operations.length < CANDIDATE_BATCH_SIZE

          position = operations.last.position
        end
      end

      def observable_roots(node)
        sql = AgentRunTaskOperation.sanitize_sql_array([<<~SQL, { run: node.agent_run_id, terminal: AgentRunTask::TERMINAL_STATUSES }])
          response ? 'refusal' OR response->'receipt'->'background' = 'true'::jsonb OR NOT EXISTS (
            SELECT 1 FROM jsonb_array_elements_text(response->'receipt'->'result_task_keys') AS result(key)
            LEFT JOIN agent_run_tasks root ON root.agent_run_id = :run AND root.node_key = result.key
            WHERE root.id IS NULL OR (root.status NOT IN (:terminal) AND NOT EXISTS (
              #{AgentRuns::ExpansionOwnership.replacement_query(node_alias: "root")}
            ))
          )
        SQL
        node.task_operations.where(observed_position: nil).where(sql)
      end
      private_class_method :observable_roots

      def candidates(node, operations)
        keys = operations.reject { |operation| immediate?(operation) }.to_h do |operation|
          [operation.id, operation.response.fetch("receipt").fetch("result_task_keys")]
        end
        standing = AgentRuns::ExpansionOwnership.standing(node.agent_run, keys.values.flatten)
        nodes = node.agent_run.agent_run_tasks.where(node_key: standing.values.flatten.uniq).index_by(&:node_key)
        operations.map do |operation|
          requested = keys[operation.id]
          selected = if requested && requested.all? { |key| standing.key?(key) }
            requested.flat_map { |key| standing.fetch(key) }.uniq.map { |key| nodes.fetch(key) }.sort_by(&:id)
          end
          Candidate.new(operation: operation, nodes: selected)
        end
      end
      private_class_method :candidates

      def immediate?(operation)
        operation.response.key?("refusal") || operation.response.dig("receipt", "background")
      end

      def record(candidate, position:)
        operation = candidate.operation
        if operation.response.key?("refusal")
          operation.update!(observed_position: position, observation: operation.response.slice("refusal"))
        elsif operation.response.dig("receipt", "background")
          operation.update!(observed_position: position, observation: {
            "outcome" => { "status" => "completed", "is_error" => false,
              "structured_content" => operation.response.fetch("receipt"), "output_present" => true,
              **operation.response.fetch("receipt").slice("released_operations") },
          })
        else
          capture(operation, nodes: candidate.nodes, position: position)
        end
      end

      def project(operation)
        facts = operation.observation
        return facts if facts.key?("refusal") || facts.key?("outcome")

        payloads = operation.observation_body&.entry_payloads || []
        results = facts.fetch("results").map { |result| envelope(result, payloads) }
        if facts.fetch("batch")
          { "outcome" => { "status" => "completed", "is_error" => results.any? { |result| result["is_error"] },
            "results" => results } }
        else
          head = results.first || { "status" => "completed", "is_error" => false, "output_present" => false }
          head = head.merge("selected" => results) if results.length > 1
          { "outcome" => head }
        end
      end

      def capture(operation, nodes:, position:)
        selected = AgentRuns::TaskResultProjection.readings(nodes)
        ActiveRecord::Associations::Preloader.new(records: selected,
          associations: { output_body: [:content_uploads, { content_body_entries: :content_fragment }] }).call
        entries = []
        uploads = []
        results = selected.map do |node|
          body = node.output_body
          payloads = body&.entry_payloads || []
          metadata = {
            "run_public_id" => node.agent_run.public_id, "task_key" => node.node_key,
            "status" => AgentRuns::TaskProjection.public_status(node.status),
            "is_error" => !!node.output_summary.fetch("is_error", false),
            "error" => (node.error_key && { "key" => node.error_key, "detail" => node.error_detail }),
            "offset" => entries.length, "length" => payloads.length,
            "output_present" => body.present?, "readable_text" => body&.readable_text,
          }
          entries.concat(payloads)
          uploads.concat(body.content_uploads) if body
          metadata
        end
        stored = ContentBodies::Replace.call(owner: operation, role: "observation", entries: entries,
          uploads: uploads.uniq(&:id), seal: true)
        if stored.accepted?
          operation.update!(observed_position: position,
            observation: { "batch" => %w[steps replace join cancel].include?(operation.kind), "results" => results })
        else
          operation.update!(observed_position: position, observation: {
            "refusal" => { "code" => "observation_unstorable", "message" => stored.refusal.to_s },
          })
        end
      end
      private_class_method :capture

      def envelope(facts, payloads)
        entries = payloads.slice(facts.fetch("offset"), facts.fetch("length"))
        output = facts["readable_text"]
        output = entries.map { |entry| Nexus::CanonicalJson.encode(entry) }.join("\n").presence if output.nil?
        facts.except("offset", "length", "readable_text").merge(
          "output" => output,
          "content" => AgentRuns::TaskResultProjection.content_blocks(entries)&.map(&:stringify_keys),
          "structured_content" => AgentRuns::TaskResultProjection.structured_content(entries),
          "structured_content_present" => AgentRuns::TaskResultProjection.structured_content_present?(entries)
        )
      end
      private_class_method :envelope
    end
  end
end
