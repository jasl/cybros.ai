class Admin::ModelProvidersController < Admin::ModelProviders::BaseController
  skip_before_action :load_provider, only: [:index, :new, :create]

  def index
    @providers = AgentAPI::ModelProviderPresenter.index(account: account, snapshot: snapshot, now: DatabaseClock.now)
    @account = account
  end

  def new
    @form = Admin::ModelProviders::DefinitionForm.new(provider_id: "")
  end

  def create
    fields = definition_fields
    @form = Admin::ModelProviders::DefinitionForm.new(provider_id: fields.fetch(:provider_id).to_s.strip, attributes: fields.except(:provider_id))
    if provider_metadata(@form.provider_id).providers.key?(@form.provider_id)
      @form.errors.add(:provider_id, :already_configured_provider)
      render :new, status: :unprocessable_entity
    elsif @form.valid?
      result = ModelProviders::SetDefinition.call(account: account, provider_id: @form.provider_id,
        definition: @form.definition, expected_lock_version: expected_lock_version(fields))
      if result.done?
        redirect_to admin_model_provider_path(@form.provider_id), notice: t("admin.model_providers.provider_added"), status: :see_other
      else
        configuration_error(@form, result, template: :new)
      end
    else
      render :new, status: :unprocessable_entity
    end
  end

  def show
    return redirect_to admin_model_provider_definition_path(provider_id) if configuration.fetch(:definition).nil?

    @configuration = configuration
    @model_names = @configuration.fetch(:models).to_h { |row| [row.fetch(:model), row.fetch(:definition)&.fetch("display_name", nil)] }
    load_models
    if @provider.fetch(:credentials) == "oauth_tokens"
      @authorization = API::ModelProviderAuthorizationPresenter.current(account: account, provider_id: provider_id, user: Current.user)
    end
  end
end
