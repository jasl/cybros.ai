# A bridge registers voices it controls, never authentication principals.
class AgentAPI::V1::Profiles::IngressActorsController < AgentAPI::V1::BaseController
  serves_plane :member

  def create
    user = current_credential.user
    return render_refusal(:not_agent_profile) unless user.agent_member?

    fields = params.expect(ingress_actor: [:channel_key, :external_id, :display_name])
    actor = Actor.register_ingress(user: user,
      channel_key: fields.fetch(:channel_key).to_s,
      external_id: fields.fetch(:external_id).to_s,
      display_name: fields.fetch(:display_name).to_s)
    if actor.errors.any?
      render_error(:validation_failed, actor.errors.full_messages.to_sentence, status: :unprocessable_content)
    elsif !actor.ingress_controlled_by?(user)
      render_refusal(:not_authorized)
    else
      render json: { ingress_actor: AgentAPI::IngressActorPresenter.detail(actor) },
        status: actor.previously_new_record? ? :created : :ok
    end
  end
end
