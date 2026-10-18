class Settings::PersonasController < Settings::BaseController
  before_action :load_document

  def show
    @content = @document&.content || ""
    @role = @document&.role || PromptDocument::DEFAULT_ROLE
  end

  def update
    fields = params.expect(prompt_document: [:content, :role])
    @content = fields[:content]
    @role = fields[:role].presence || PromptDocument::DEFAULT_ROLE
    # The Human is the existing serialization owner for both persona API doors.
    result = Current.user.with_lock do
      PromptDocuments::Write.call(anchor: { user: Current.user }, slot: "persona",
        content: @content, role: @role)
    end
    if result.written?
      redirect_to settings_persona_path, notice: t("personas.saved"), status: :see_other
    else
      @error = t("personas.errors.#{result.outcome}", detail: result.detail)
      render :show, status: :unprocessable_entity
    end
  end

  def destroy
    result = Current.user.with_lock do
      PromptDocuments::Delete.call(anchor: { user: Current.user }, slot: "persona")
    end
    if result.deleted?
      redirect_to settings_persona_path, notice: t("personas.deleted"), status: :see_other
    else
      redirect_to settings_persona_path, alert: t("personas.errors.#{result.outcome}"), status: :see_other
    end
  end

  private

    def load_document
      @document = Current.user.prompt_documents.find_by(slot: "persona")
    end
end
