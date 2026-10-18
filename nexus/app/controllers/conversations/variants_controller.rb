class Conversations::VariantsController < Work::BaseController
  def index
    @conversation = find_visible_conversation(:conversation_id)
    @entry = @conversation.timeline.entry(public_id: params.fetch(:turn_id))
    raise ActiveRecord::RecordNotFound unless @entry

    @variants_pagy, variants = pagy(:offset,
      @entry.turn.variants.live.preload(:origin_variant).order(:position, :public_id), limit: 20)
    bodies = ContentBody.preload_for_render(ContentBody.where(variant_id: variants.map(&:id), role: %w[content prompt]))
      .group_by(&:variant_id)
    @variants = variants.map do |variant|
      roles = bodies.fetch(variant.id, []).index_by(&:role)
      Conversations::TurnProjection.variant(variant, body: roles["content"], prompt: roles["prompt"],
        active: variant.id == @entry.turn.active_variant_id)
    end
    @runs = Run.visible_to(acting_user).where(variant_id: variants.map(&:id)).joins(:variant)
      .pluck("variants.public_id", "runs.public_id").to_h
  end

  def show
    @conversation = find_visible_conversation(:conversation_id)
    @result = ::Conversations::Reader.new(@conversation, user: acting_user).variant(
      turn_public_id: params.fetch(:turn_id), variant_public_id: params.fetch(:id))
    @current_model = @result.run ? Runs::CurrentModel.for(@result.run) : @result.variant_record
  end
end
