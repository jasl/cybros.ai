# A bridge registers voices it controls, never authentication principals.
# @auth [MemberBearer]
class AgentAPI::V1::Profiles::IngressSpeakersController < AgentAPI::V1::BaseController
  serves_plane :member

  # @oas_include
  # @summary Create ingress speakers
  # @tags Member, ingress speakers
  # @request_body_ref #/components/requestBodies/AgentApiV1ProfilesIngressSpeakersCreate
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1ProfilesIngressSpeakersCreate
  # @response_ref (201) #/components/responses/AgentApiV1ProfilesIngressSpeakersCreate
  def create
    user = current_credential.user
    return render_refusal(:not_agent) unless user.agent_member?

    fields = params.expect(ingress_speaker: [:channel_key, :external_id, :display_name])
    actor = Speaker.register_ingress(user: user,
      channel_key: fields.fetch(:channel_key).to_s,
      external_id: fields.fetch(:external_id).to_s,
      display_name: fields.fetch(:display_name).to_s)
    if actor.errors.any?
      render_error(:validation_failed, actor.errors.full_messages.to_sentence, status: :unprocessable_content)
    elsif !actor.ingress_controlled_by?(user)
      render_refusal(:not_authorized)
    else
      render json: { ingress_speaker: AgentAPI::IngressSpeakerPresenter.detail(actor) },
        status: actor.previously_new_record? ? :created : :ok
    end
  end
end
