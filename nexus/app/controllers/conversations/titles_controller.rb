class Conversations::TitlesController < Conversations::BaseController
  before_action :require_writable_conversation
  before_action :require_open_conversation

  def edit
    @submitted_title = @conversation.title.to_s
    @submitted_lock_version = @conversation.lock_version
  end

  def update
    fields = params.expect(conversation: [:title, :lock_version, :reviewed_lock_version])
    @submitted_title = fields[:title].to_s
    @submitted_lock_version = bounded_integer(fields[:lock_version], :lock_version, range: 0..2_147_483_647)
    expected_version = fields[:reviewed_lock_version].present? ?
      bounded_integer(fields[:reviewed_lock_version], :reviewed_lock_version, range: 0..2_147_483_647) : @submitted_lock_version
    result = ::Conversations::Update.call(conversation: @conversation,
      lock_version: expected_version, changes: { title: @submitted_title.strip.presence })
    if result.accepted?
      redirect_to conversation_path(@conversation, return_to: work_return_path(workspace_conversations_path(@conversation.workspace))),
        status: :see_other, notice: t("conversation_management.title.saved")
    else
      if result.outcome == :stale_object
        @current_conversation = find_visible_conversation(:conversation_id)
        @form_errors = [t("conversation_management.title.conflict")]
      else
        @form_errors = result.errors.full_messages
      end
      render :edit, status: result.outcome == :stale_object ? :conflict : :unprocessable_entity
    end
  end

  private

    def require_open_conversation
      if @conversation.archived?
        render_error(:conversation_archived, t("conversation_management.title.archived"), status: :conflict)
      end
    end
end
