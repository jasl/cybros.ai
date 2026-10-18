module AgentAPI
  class RunExport < ExecutionExport
    include Models

    def initialize(run:, user:)
      @run = run
      @user = user
    end

    private

      def records
        header = read do
          envelope("export", format: "nexus.run.diagnostic", version: 1,
            exported_at: Time.current.iso8601, scope: "retained_run", consistency: CONSISTENCY,
            workspace_public_id: @run.workspace.public_id,
            retention: { execution_details_retention_days: (@run.account.execution_details_retention_days unless @run.standalone?),
              applies_to: (@run.standalone? ? "no_conversation_retention" : "completed_conversation_execution"),
              details_pruned_at: @run.details_pruned_at, attachment_bytes: "separate_authenticated_download" })
        end
        yield header
        projection = read { RunPresenter.basic_many([@run]).first }
        yield envelope("run", run: projection)
        execution(@run, {}, task_steers: true) { |record| yield record }
        if retained_run?
          models { |record| yield record }
          inputs { |record| yield record } if @run.standalone?
        end
        # Retention may finish after a Task page but before graph/model reads.
        unless @run.details_pruned_at || retained_run?
          yield envelope("execution_unavailable", reason: "unavailable_or_pruned_during_export")
        end
      end

      def envelope(type, **fields)
        { type: type, run_public_id: @run.public_id, **fields }
      end

      def retained_run?
        read { Run.visible_to(@user).where(id: @run.id, details_pruned_at: nil).exists? }
      end

      def inputs
        ceiling = read { @run.inputs.maximum(:id) }
        cursor = 0
        while ceiling && cursor < ceiling
          page = read do
            rows = @run.inputs.where(id: (cursor + 1)..ceiling).order(:id).limit(PAGE_SIZE)
              .preload(:answering_user, { speaker: :user }, :content_bodies).to_a
            ContentBody.preload_for_render(rows.flat_map(&:content_bodies))
            rows.map do |input|
                input.association(:host).target = @run
                [input.id, ConversationPresenter.input(input)]
              end
          end
          break if page.empty?

          cursor = page.last.first
          page.each { |_, projection| yield envelope("input", input: projection) }
        end
      end
  end
end
