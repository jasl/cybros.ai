module AgentAPI
  class ExecutionExport < DiagnosticExport
    include Tasks

    private

      def steers(body_id, correlations)
        scope = ContentBodyEntry.where(content_body_id: body_id)
        ceiling = read { scope.maximum(:position) }
        cursor = -1
        while ceiling && cursor < ceiling
          page = read do
            scope.where(position: (cursor + 1)..ceiling).order(:position).limit(PAGE_SIZE)
              .preload(:content_fragment).map do |entry|
                [entry.position, entry.content_fragment.payload]
              end
          end
          break if page.empty?

          cursor = page.last.first
          page.each do |position, payload|
            yield envelope("steer", **correlations, position: position, steer: payload)
          end
        end
      end

      # Sealed semantic bodies use the inspection presenter's exact shape.
      # This batch is bounded by a candidate or task page, never a whole Run.
      def request_projections(invocation_ids)
        invocations = ModelInvocation.where(id: invocation_ids).to_a
        bodies = ContentBody.where(model_invocation_id: invocation_ids, role: "request")
          .preload(content_body_entries: :content_fragment).index_by(&:model_invocation_id)
        invocations.to_h do |invocation|
          entries = bodies[invocation.id]&.entry_payloads || []
          [invocation.id, { model_invocation_public_id: invocation.public_id,
            request: AgentAPI::SealedRequestPresenter.call(invocation, entries: entries).fetch(:request) }]
        end
      end
  end
end
