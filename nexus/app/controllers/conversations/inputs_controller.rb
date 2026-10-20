class Conversations::InputsController < Conversations::BaseController
  def index
    @inputs_pagy, @inputs = pagy(:offset,
      @conversation.inputs.where(state: ::Conversations::Inputs::Update::EDITABLE_STATES)
        .includes(:authoring_user, :answering_user, content_bodies: { content_body_entries: :content_fragment })
        .in_read_order.order(:public_id), limit: 20)
  end

  def show
    @input = @conversation.inputs.includes(:content_bodies, :answering_user).find_by(public_id: params.fetch(:id))
    if @input
      ContentBody.preload_for_render(@input.content_bodies)
      @input_attachments = ::Conversations::TurnProjection.attachments(@input.content_body) || []
      @configuration_answerer = @input.answering_user
    else
      @entry = @conversation.timeline.materialized_entry(input_public_id: params.fetch(:id))
      raise ActiveRecord::RecordNotFound unless @entry

      @configuration_answerer = @entry.turn.answering_user
      variant = @entry.turn.variants.live.find_by!(position: 0)
      bodies = ContentBody.preload_for_render(variant.content_bodies.where(role: %w[content prompt])).index_by(&:role)
      @variant = ::Conversations::TurnProjection.variant(variant, body: bodies["content"],
        prompt: bodies["prompt"], active: variant.id == @entry.turn.active_variant_id)
      @run = Run.visible_to(acting_user).find_by(variant_id: variant.id)
    end
  end
end
