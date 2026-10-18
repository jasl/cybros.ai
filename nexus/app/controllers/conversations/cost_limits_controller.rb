class Conversations::CostLimitsController < Conversations::BaseController
  before_action :require_writable_conversation

  def edit
    @current_limit = @conversation.cost_limit
    @submitted_amount = @current_limit&.to_s("F")
    @submitted_lock_version = @conversation.lock_version
    prepare_usage
  end

  def update
    @current_limit = @conversation.cost_limit
    fields = params.expect(cost_limit: [:amount, :lock_version])
    @submitted_amount = fields[:amount].to_s
    @submitted_lock_version = bounded_integer(fields[:lock_version], :lock_version, range: 0..2_147_483_647)
    result = ::Conversations::Update.call(conversation: @conversation,
      lock_version: @submitted_lock_version, changes: { cost_limit: @submitted_amount.presence })
    if result.accepted?
      redirect_to work_return_path(conversation_path(@conversation)), status: :see_other,
        notice: t("work_recovery.cost_limit.saved")
    else
      if result.outcome == :stale_object
        @current_conversation = find_visible_conversation(:conversation_id)
        @current_limit = @current_conversation.cost_limit
        @form_errors = [t("work_recovery.cost_limit.conflict")]
      else
        @form_errors = result.errors.full_messages
      end
      prepare_usage
      render :edit, status: result.outcome == :stale_object ? :conflict : :unprocessable_entity
    end
  end

  private

    def prepare_usage
      @usage = ModelUsageSummary.public_projection(subject_kind: "conversation", subject_id: @conversation.id)
    end
end
