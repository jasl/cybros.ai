module WorkReports
  class Export < DiagnosticExport
    def initialize(user:, report:, workspace: nil, agent: nil, filters: {})
      @user = user
      @report = report
      @workspace = workspace
      @agent = agent
      @filters = filters
    end

    private

      def records
        yield envelope("export", format: "nexus.work.usage", version: 1,
          exported_at: Time.current.iso8601, consistency: CONSISTENCY,
          scope: "readable_conversation_usage_and_run_summary", filters: @filters,
          retention: { usage: "retained_receipts_for_currently_readable_conversations",
            execution: "current_retained_rows_only", attachment_bytes: "not_included" })
        yield envelope("summary", report: AgentAPI::WorkAnalysisPresenter.full(@report))
        scope = read do
          UsageRecord.for_conversations(account: @user.account,
            conversations: Conversation.visible_to(@user, workspace: @workspace), consumer: @agent)
            .where(recorded_at: @report.from...@report.to).where(@filters)
        end
        ceiling = read { scope.maximum(:id) }
        cursor = nil
        while ceiling
          page = read do
            bounded = scope.where(id: ..ceiling)
            bounded = bounded.where("(recorded_at, id) > (?, ?)", *cursor) if cursor
            bounded.order(:recorded_at, :id).limit(PAGE_SIZE).map do |receipt|
              [[receipt.recorded_at, receipt.id], UsageRecords::PublicUsage.diagnostic(receipt).merge(
                "conversation_public_id" => receipt.conversation_public_id,
                "workspace_public_id" => receipt.workspace_public_id)]
            end
          end
          break if page.empty?

          cursor = page.last.first
          page.each { |_, receipt| yield envelope("usage", usage: receipt) }
        end
      end

      def envelope(type, **fields)
        { type: type, workspace_public_id: @workspace&.public_id, agent_public_id: @agent&.public_id, **fields }
      end
  end
end
