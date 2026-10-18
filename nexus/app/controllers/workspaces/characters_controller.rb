class Workspaces::CharactersController < Workspaces::DataController
  before_action :load_character

  def show
  end

  def edit
    @content = @document&.content || ""
    @role = @document&.role || PromptDocument::DEFAULT_ROLE
  end

  def update
    fields = params.expect(prompt_document: [:content, :role])
    @content = fields[:content]
    @role = fields[:role].presence || PromptDocument::DEFAULT_ROLE
    workspace.with_lock do
      return unless data_write_allowed?(template: :edit, lifecycle_refusal: true)

      result = PromptDocuments::Write.call(anchor: { workspace: workspace }, slot: "character", content: @content, role: @role)
      return render_data_refusal(result.outcome, template: :edit, detail: result.detail) unless result.written?
    end
    redirect_to workspace_character_path(workspace), notice: t("data_console.character.saved"), status: :see_other
  end

  def destroy
    workspace.with_lock do
      return unless data_write_allowed?(template: :show, lifecycle_refusal: true)

      result = PromptDocuments::Delete.call(anchor: { workspace: workspace }, slot: "character")
      return render_data_refusal(result.outcome, template: :show) unless result.deleted?
    end
    redirect_to workspace_character_path(workspace), notice: t("data_console.character.deleted"), status: :see_other
  end

  private

    def load_character
      @document = workspace.prompt_documents.find_by(slot: "character")
    end
end
