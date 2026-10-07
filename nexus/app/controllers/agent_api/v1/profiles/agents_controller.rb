# THE NAMED DEFINITIONS DOOR: the caller's OWN definitions — profiles it
# minted under `<its identifier>/<name>`, no credential, no address —
# listed, declared whole and removed by their name; the steward's OTHER
# published rows ride the listing read-only. Every row is rendered as the
# principals listing renders it plus its scope, description, declarer and
# configuration block. The segment is constrained to the handle grammar in
# the routes, so a name outside it never reaches here.
class AgentAPI::V1::Profiles::AgentsController < AgentAPI::V1::BaseController
  serves_plane :member

  before_action :require_agent

  def index
    render json: { agents: listing.map { |row| named_agent(row) } }
  end

  def update
    outcome = Users::DeclareNamedDefinition.call(caller: acting_user, name: params[:name], **declaration)

    if outcome.accepted?
      render json: { agent: named_agent(outcome.user) }, status: outcome.outcome == :declared ? :created : :ok
    elsif outcome.outcome == :invalid
      render_error(:validation_failed, outcome.user.errors.full_messages.to_sentence,
        status: :unprocessable_content)
    else
      render_refusal(outcome.outcome, detail: outcome.detail)
    end
  end

  def destroy
    row = own_definitions.find_by(agent_identifier: composed_identifier)
    return render_refusal(:not_found) if row.nil?

    Users::Remove.call(user: row)
    head :no_content
  end

  private

    def acting_user = current_credential.user

    def require_agent
      render_refusal(:not_agent) unless acting_user.agent_member?
    end

    def composed_identifier = "#{acting_user.agent_identifier}#{User::NamedDefinition::DEFINITION_SEPARATOR}#{params[:name]}"

    # The caller's own active rows of either scope.
    def own_definitions
      User.where(derived_from_id: acting_user.id, status: :active).where.not(definition_scope: nil)
    end

    # Own rows of both scopes, then the steward's other published rows,
    # by display name; the declarer and the steward preloaded for the row.
    def listing
      published_by_others = User.where(steward_id: acting_user.steward_id, definition_scope: "steward", status: :active)
        .where.not(derived_from_id: acting_user.id)
      User.where(status: :active).and(own_definitions.or(published_by_others))
        .includes(:derived_from, :steward).order_by_display_name
    end

    def named_agent(row) = AgentAPI::ProfilePresenter.named_definition(row)

    # `scope`, `description` and `configuration` are the body's three
    # required roots (400 `parameter_missing` when absent); `display_name`
    # and `system_prompt` optional — a nil or absent body deletes the
    # slot. The configuration's four JSON fields are opaque by the
    # configuration door's contract and read from the body as sent.
    def declaration
      typed = params.permit(:scope, :description, :display_name,
        configuration: [:approval_mode, :prompt_mechanism, :default_model, :fallback_model])
      body = request.request_parameters
      configuration = typed.fetch(:configuration)
      {
        scope: required_word(:scope),
        description: required_word(:description),
        display_name: typed[:display_name]&.to_s,
        system_prompt: body["system_prompt"],
        configuration: {
          tool_definitions: body.dig("configuration", "tool_definitions"),
          kernel_tools: body.dig("configuration", "kernel_tools"),
          runner_executor_public_ids: body.dig("configuration", "runner_executor_public_ids"),
          runner_tool_names: body.dig("configuration", "runner_tool_names"),
          approval_mode: configuration[:approval_mode]&.to_s,
          approval_rules: body.dig("configuration", "approval_rules"),
          prompt_mechanism: configuration[:prompt_mechanism]&.to_s,
          prompt_template: body.dig("configuration", "prompt_template"),
          compaction_policy: body.dig("configuration", "compaction_policy"),
          lifecycle_hooks: body.dig("configuration", "lifecycle_hooks"),
          default_model: configuration[:default_model]&.to_s,
          fallback_model: configuration[:fallback_model]&.to_s,
        },
      }
    end

    # Absent is the caller's 400; present and blank is the model's 422 —
    # `require` would read a blank description as missing.
    def required_word(name)
      raise ActionController::ParameterMissing.new(name) unless request.request_parameters.key?(name.to_s)

      params[name].to_s
    end
end
