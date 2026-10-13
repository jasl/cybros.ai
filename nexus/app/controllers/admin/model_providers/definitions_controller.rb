class Admin::ModelProviders::DefinitionsController < Admin::ModelProviders::BaseController
  def show
    @form = build_form
  end

  def update
    fields = definition_fields
    @form = build_form(fields)
    if @form.valid?
      result = ModelProviders::SetDefinition.call(account: account, provider_id: provider_id,
        definition: @form.definition, expected_lock_version: expected_lock_version(fields))
      if result.done?
        redirect_to admin_model_provider_path(provider_id), notice: t("admin.model_providers.connection_saved"), status: :see_other
      else
        configuration_error(@form, result)
      end
    else
      render :show, status: :unprocessable_entity
    end
  end

  def destroy
    fields = params.expect(provider_definition: [:expected_lock_version])
    result = ModelProviders::ResetDefinition.call(account: account, provider_id: provider_id,
      expected_lock_version: expected_lock_version(fields))
    if result.done?
      redirect_to admin_model_providers_path, notice: t("admin.model_providers.connection_reset"), status: :see_other
    else
      @form = build_form
      configuration_error(@form, result)
    end
  end

  private

    def build_form(attributes = {})
      Admin::ModelProviders::DefinitionForm.new(provider_id: provider_id,
        definition: configuration.fetch(:definition) || {}, lock_version: @provider.fetch(:lock_version), attributes: attributes.except(:provider_id))
    end
end
