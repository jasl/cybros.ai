class AttentionController < Work::BaseController
  include AgentAPI::KeysetPagination
  include AttentionListing

  def show
    @workspace = selected_workspace
    @workspaces = browsable_workspaces.order(:name, :id)
    @page = attention_page
    @as_of = Time.current
    @maintenance_now = Deployments::Maintenance.effective_now(@as_of)
    question_ids = @page.records.select { |task| task.status == "awaiting_input" }.map(&:id)
    # Read only this authorized page's preview bytes; no body/fragments are
    # materialized merely to truncate a potentially large question afterward.
    questions = ContentBody.where(task_id: question_ids, role: "input")
      .pluck(:task_id, Arel.sql("LEFT(readable_text, 281)")).to_h
    @summaries = @page.records.to_h do |task|
      text = if task.status == "awaiting_input"
        questions[task.id].to_s
      elsif task.held?
        JSON.generate(task.tool_input)
      else
        [task.error_key, task.error_detail].compact.join(": ")
      end
      [task.id, { text: text.first(280), truncated: text.length > 280 }]
    end
  end
end
