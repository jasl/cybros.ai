class Conversations::Variants::FieldsController < Work::BaseController
  def show
    @conversation = find_visible_conversation(:conversation_id)
    options = ::Conversations::History::Parameters.field(params.permit(:field, :location, :after).to_h)
    @result = ::Conversations::Reader.new(@conversation, user: acting_user).field(
      turn_public_id: params.fetch(:turn_id), variant_public_id: params.fetch(:variant_id), **options)
  rescue ::Conversations::History::Parameters::Invalid
    render_error(:parameter_invalid, t("conversation_history.invalid_window"), status: :bad_request)
  end
end
