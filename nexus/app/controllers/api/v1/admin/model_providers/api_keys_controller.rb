# PUT/DELETE /api/v1/admin/model_providers/{id}/api_key. The key is write-only in every shape — a
# caller learns only that one is installed. Rotation is the same verb: identical material is a
# no-op, so a retried install cannot invalidate a working key. A lane that authenticates some
# other way answers `409 material_kind_conflict` — the service's own word, the one the pack's
# `models.json` table lists; a bare HTTP status name is not a code.
class API::V1::Admin::ModelProviders::APIKeysController < API::V1::Admin::ModelProviders::BaseController
  before_action :require_api_key_lane

  def update
    fields = params.expect(command: [:api_key])
    result = ModelProviders::ConfigureAPIKey.call(
      account: account, provider_id: provider_id, api_key: fields[:api_key]
    )
    return render_lane if result.done?

    case result.outcome
    when :material_kind_conflict
      render_refusal(result.outcome)
    else
      # `parameter_invalid` is a family code and the family owns its
      # status (400); the argument here is the fallback the signature
      # demands, not a second opinion.
      render_error(:parameter_invalid, "api_key must not be blank", status: :bad_request)
    end
  end

  def destroy
    result = ModelProviders::RemoveAPIKey.call(account: account, provider_id: provider_id)
    return render_lane if result.done?

    case result.outcome
    when :material_kind_conflict
      render_refusal(result.outcome)
    else
      render_error(:not_found, "This lane holds no api key", status: :not_found)
    end
  end

  private

    def require_api_key_lane
      lane = ModelCatalog::ProfileBuilder.credential_lane(provider_metadata.providers.fetch(provider_id))
      render_refusal(:material_kind_conflict) unless lane == "api_key"
    end
end
