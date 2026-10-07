# The advisory sizing surface: assembly is server-side, so only the server
# can count what the caller cannot see. Write-free, never a provider call.
# With `render: true` it is THE PREVIEW (one door): the bytes a send would
# seal, compiled under the addressee `answering_user_public_id` names (the
# input door's own word, the same resolver), with the caller as the
# author; `variables` for the template's names and `template` for an
# estimate-only trial of another order.
class AgentAPI::V1::Workspaces::Conversations::ContextEstimatesController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped

  def create
    conversation = find_listable_conversation(@workspace)

    fields = params.expect(context_estimate: [
      :prompt, :answering_user_public_id, { model: %i[model reasoning_effort reasoning_enabled], configuration: {} },
    ])
    provider_id, model_ref, reasoning_effort, reasoning_enabled = split_model(fields[:model])
    # Intent-level history bounds (entries or a share of the window; an agent
    # never knows a position), closed so a typo'd key refuses instead of unbounding.
    intent = history_intent(:context_estimate) || {}
    replay = reasoning_replay_intent(:context_estimate)
    render_requested = render_intent

    result = ::Conversations::ContextEstimate.call(
      ::Conversations::ContextEstimate::Command.new(
        conversation: conversation,
        acting_user: acting_user,
        provider_id: provider_id,
        model_ref: model_ref,
        reasoning_effort: reasoning_effort, reasoning_enabled: reasoning_enabled,
        request_options: fields[:configuration]&.to_h,
        prompt: fields[:prompt],
        history_max_entries: intent["max_entries"],
        history_token_budget_share: intent["token_budget_share"],
        reasoning_replay_mode: replay && replay["mode"],
        inline: inline_intent(:context_estimate).presence,
        render: render_requested,
        answering_user_public_id: fields[:answering_user_public_id],
        variables: object_intent("variables"),
        template: object_intent("template"),
      )
    )

    if result.accepted?
      render json: {
        context_estimate: AgentAPI::ContextEstimatePresenter.full(result.value, render: render_requested),
      }
    elsif result.outcome == :prompt_template_invalid && result.value
      # The trial template's grammar refusal names its JSON-pointer path,
      # as the profile door's does for the column.
      render_error(:prompt_template_invalid,
        "Prompt template is outside the template grammar (#{result.value.detail}) at #{result.value.path}",
        status: :unprocessable_content)
    else
      render_refusal(result.outcome)
    end
  end

  private

    # Body-read like the assembly intents: a JSON boolean or absent —
    # never a string that would silently read as a request for nothing.
    def render_intent
      value = envelope["render"]
      raise APIErrors::ParameterInvalid, :render unless [nil, true, false].include?(value)

      value == true
    end

    # `variables` and `template` are objects whose keys the grammar owns;
    # read from the parsed body (the permit filter would strip or flatten
    # them without a word), the shape admitted here, the words the service's.
    def object_intent(key)
      return nil unless envelope.key?(key)

      value = Hash.try_convert(envelope[key])
      raise APIErrors::ParameterInvalid, key.to_sym if value.nil?

      value
    end

    def envelope = Hash.try_convert(request.request_parameters["context_estimate"]) || {}
end
