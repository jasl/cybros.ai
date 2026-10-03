class Admin::ModelProviders::BaseController < Admin::BaseController
  before_action :no_store
  before_action :load_provider

  private

    def account = Current.account

    def snapshot
      @snapshot ||= ModelCatalog.current
    end

    def provider_metadata(id)
      @provider_metadata ||= ModelSelection::ProviderMetadata.read(account: account, snapshot: snapshot, provider_id: id)
    end

    def configuration
      @configuration ||= API::ModelProviderConfigurationPresenter.one(account: account, provider_id: provider_id, snapshot: snapshot)
    end

    def provider_id
      given = (params[:model_provider_id] || params[:id]).to_s
      metadata = provider_metadata(given)
      raise ActiveRecord::RecordNotFound unless metadata.providers.key?(given) || metadata.policies.key?(given)

      given
    end

    def load_provider
      @provider = AgentAPI::ModelProviderPresenter.one(
        account: account, provider_id: provider_id, snapshot: snapshot, now: DatabaseClock.now
      )
    end

    def load_models
      catalog = ModelSelection::Resolver.effective_provider_catalog(account, snapshot, provider_id)
      own_models = catalog.models.select { |ref, _| Nexus::ModelRef.parse(ref).provider_id == provider_id }
      @models = AgentAPI::ModelPresenter.index(account: account, catalog: catalog.with(models: own_models))
    end

    def expected_lock_version(fields)
      value = fields.fetch(:expected_lock_version).presence
      return nil if value.nil?

      version = Integer(value.to_s, 10)
      raise ArgumentError unless (0..2_147_483_647).cover?(version)

      version
    rescue ArgumentError
      raise ActionController::BadRequest, "expected_lock_version must be a nonnegative integer"
    end

    def definition_fields
      params.expect(provider_definition: [:provider_id, :display_name, :api_format, :base_url, :credentials,
        :concurrency_limit, :expected_lock_version])
    end

    def configuration_error(form, result, template: :show)
      stale = result.outcome == :stale
      form.errors.add(:base, stale ? "These settings changed in another session. Reload the page before saving again." :
        "The definition could not be saved. Check the protocol, URL, capabilities and any pricing formula.")
      render template, status: stale ? :conflict : :unprocessable_entity
    end

    def form_error(key, status: :unprocessable_entity)
      flash.now[:alert] = t("admin.model_providers.#{key}")
      render :show, status: status
    end
end
