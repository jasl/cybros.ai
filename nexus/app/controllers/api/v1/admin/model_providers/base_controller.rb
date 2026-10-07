# Every catalog command sees the same account-effective provider declaration.
class API::V1::Admin::ModelProviders::BaseController < API::V1::Admin::BaseController
  private

    def account = Current.user.account
    def snapshot = @snapshot ||= ModelCatalog.current
    def given_provider_id = (params[:model_provider_id] || params[:id]).to_s

    def provider_metadata
      ModelSelection::ProviderMetadata.read(account: account, snapshot: snapshot, provider_id: given_provider_id)
    end

    def provider_id
      raise ActiveRecord::RecordNotFound unless provider_metadata.providers.key?(given_provider_id)

      given_provider_id
    end

    # A removed custom provider retains its optimistic-lock anchor for recreation.
    def configuration_provider_id
      catalog = provider_metadata
      unless catalog.providers.key?(given_provider_id) || catalog.policies.key?(given_provider_id)
        raise ActiveRecord::RecordNotFound
      end
      given_provider_id
    end

    def expected_version(fields)
      version = fields.fetch(:expected_lock_version)
      bounded_integer(version, :expected_lock_version, range: 0..2_147_483_647) unless version.nil?
    end

    def render_lane(status: :ok)
      render json: { model_provider: lane(provider_id) }, status: status
    end

    def render_configuration(id: configuration_provider_id)
      render json: {
        model_provider: lane(id),
        configuration: API::ModelProviderConfigurationPresenter.one(account: account, provider_id: id, snapshot: snapshot),
      }
    end

    def render_configuration_result(result, id: provider_id)
      return render_configuration(id: id) if result.done?

      case result.outcome
      when :not_found
        render_not_found
      when :stale
        render_error(:stale_object, "The provider changed since you read it", status: :conflict)
      else
        render_error(:validation_failed, "The definition could not be changed", status: :unprocessable_entity)
      end
    end

    def lane(id)
      AgentAPI::ModelProviderPresenter.one(account: account, provider_id: id, snapshot: snapshot, now: DatabaseClock.now)
    end
end
