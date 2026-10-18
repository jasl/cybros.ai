module AgentAPI
  class ConversationExport
    module Timeline
      VariantRecord = Data.define(:cursor, :correlations, :projection, :steer_body_id, :request,
        :unavailable, :run, :run_projection)

      private

        def timeline
          ceiling = read { Conversation.where(id: @conversation.id).pick(:timeline_position_head) - 1 }
          cursor = -1
          while cursor < ceiling
            entries, projections = read do
              rows = Conversation::Timeline.new(@conversation).entries(surface: :timeline,
                after_position: cursor, limit: DiagnosticExport::PAGE_SIZE, include_hidden: true)
                .take_while { |entry| entry.position <= ceiling }
              [rows, AgentAPI::ConversationPresenter.turn_entries(rows)]
            end
            break if entries.empty?

            cursor = entries.last.position
            projections.each { |projection| yield envelope("turn", turn: projection) }
            variants(entries) { |record| yield record }
          end
        end

        def variants(entries)
          turns = entries.to_h { |entry| [entry.turn.id, entry.turn] }
          scope = Variant.live.where(turn_id: turns.keys)
          ceiling = read { scope.maximum(:id) }
          cursor = nil
          while ceiling
            page = read do
              bounded = scope.where(id: ..ceiling)
              bounded = bounded.where("(turn_id, position) > (?, ?)", *cursor) if cursor
              rows = bounded.order(:turn_id, :position).limit(DiagnosticExport::PAGE_SIZE)
                .preload(:origin_variant).to_a
              variant_page(rows, turns)
            end
            break if page.empty?

            cursor = page.last.cursor
            page.each do |item|
              correlations = item.correlations
              yield envelope("variant", **correlations, variant: item.projection)
              if item.steer_body_id
                steers(item.steer_body_id, correlations) { |record| yield record }
              end
              if item.request
                yield envelope("request", **correlations, **item.request)
              end
              if item.run_projection
                yield envelope("run", **correlations, run_public_id: item.run.public_id,
                  run: item.run_projection)
              end
              if item.unavailable
                yield envelope("execution_unavailable", **correlations, reason: item.unavailable)
              elsif item.run
                execution(item.run, correlations, task_steers: item.steer_body_id.nil?) { |record| yield record }
              end
            end
          end
        end

        def variant_page(rows, turns)
          ids = rows.map(&:id)
          bodies = ContentBody.preload_for_render(ContentBody.where(variant_id: ids, role: %w[content prompt]))
            .group_by(&:variant_id)
          steer_bodies = ContentBody.where(variant_id: ids, role: "steers").pluck(:variant_id, :id).to_h
          loops = AgentAPI::ConversationPresenter.loop_blocks(ids)
          runs = Run.where(variant_id: ids).index_by(&:variant_id)
          readable = Run.listable.readable_by(@user).where(id: runs.values.map(&:id)).to_a
          projections = AgentAPI::RunPresenter.basic_many(readable).index_by { |projection| projection.fetch(:public_id) }
          seeds = Task.where(run_id: runs.values.map(&:id), node_key: ::Conversations::Inputs::ApplyNext::SEED_ROUND_KEY)
            .pluck(:run_id, :selected_model_invocation_id).to_h
          invocation_ids = rows.to_h do |variant|
            [variant.id, variant.model_invocation_id || seeds[runs[variant.id]&.id]]
          end
          requests = request_projections(invocation_ids.values.compact)
          rows.map do |variant|
            turn = turns.fetch(variant.turn_id)
            owned_bodies = bodies.fetch(variant.id, []).index_by(&:role)
            run = runs[variant.id]
            unavailable = execution_unavailable(variant, run, projections)
            VariantRecord.new(
              cursor: [variant.turn_id, variant.position],
              correlations: { turn_public_id: turn.public_id, variant_public_id: variant.public_id },
              projection: AgentAPI::ConversationPresenter.variant(variant, body: owned_bodies["content"],
                active: turn.active_variant_id == variant.id, loop: loops[variant.id], prompt: owned_bodies["prompt"]),
              steer_body_id: steer_bodies[variant.id],
              request: (requests[invocation_ids[variant.id]] unless variant.details_pruned_at || run&.details_pruned_at),
              unavailable: unavailable,
              run: run,
              run_projection: run && projections[run.public_id],
            )
          end
        end

        def execution_unavailable(variant, run, projections)
          if variant.details_pruned_at || run&.details_pruned_at
            "execution_details_pruned"
          elsif run && !projections.key?(run.public_id)
            "unavailable"
          elsif variant.source == "run" && run.nil?
            "unavailable"
          end
        end
    end
  end
end
