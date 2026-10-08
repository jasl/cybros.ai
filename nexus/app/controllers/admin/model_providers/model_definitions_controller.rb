class Admin::ModelProviders::ModelDefinitionsController < Admin::ModelProviders::BaseController
  before_action :require_provider_definition

  def new
    @form = build_form(attributes: params.permit(:model_id, :display_name))
  end

  def show
    @model = find_model(params.fetch(:model).to_s)
    @form = build_form(row: @model)
  end

  def create
    save_model
  end

  def update
    fields = model_fields
    @model = find_model(fields.fetch(:model).to_s)
    save_model(row: @model, fields: fields)
  end

  def destroy
    fields = params.expect(model_definition: [:model, :expected_lock_version])
    @model = find_model(fields.fetch(:model).to_s)
    result = ModelProviders::RemoveModelOverride.call(account: account, provider_id: provider_id,
      model_ref: @model.fetch(:model), validate_definition: true, expected_lock_version: expected_lock_version(fields))
    if result.done?
      redirect_to admin_model_provider_path(provider_id), notice: t("admin.model_providers.model_removed"), status: :see_other
    else
      @form = build_form(row: @model)
      configuration_error(@form, result)
    end
  end

  private

    def require_provider_definition
      # Removing a custom connection retains its identity and model settings.
      # Old model URLs resume at the connection form before model authoring.
      if configuration.fetch(:definition).nil?
        redirect_to admin_model_provider_definition_path(provider_id), status: :see_other
      end
    end

    def find_model(ref)
      configuration.fetch(:models).find { |row| row.fetch(:model) == ref } || raise(ActiveRecord::RecordNotFound)
    end

    def model_fields
      params.expect(model_definition: [:model, :model_id, :display_name, :expected_lock_version, :pricing_mode,
        :pricing_unit, *Admin::ModelProviders::ModelForm::LIMIT_FIELDS, *Admin::ModelProviders::ModelForm::BOOLEAN_FIELDS,
        *Admin::ModelProviders::ModelForm::RATE_FIELDS])
    end

    def build_form(row: nil, attributes: {})
      @installation_model = row && snapshot.models.key?(row.fetch(:model))
      Admin::ModelProviders::ModelForm.new(provider_id: provider_id, provider_definition: configuration.fetch(:definition),
        definition: row ? row.fetch(:definition) || {} : {}, model: row&.fetch(:model), lock_version: @provider.fetch(:lock_version),
        cost_unit: account.cost_unit, attributes: attributes)
    end

    def save_model(row: nil, fields: model_fields)
      @form = build_form(row: row, attributes: fields)
      template = row ? :show : :new
      if @form.valid?
        if row.nil? && configuration.fetch(:models).any? { |entry| entry.fetch(:model) == @form.model_ref }
          @form.errors.add(:model_id, :already_configured_model)
          return render template, status: :unprocessable_entity
        end
        result = ModelProviders::UpsertModelOverride.call(account: account, provider_id: provider_id,
          model_ref: @form.model_ref, model: @form.definition, validate_definition: true, expected_lock_version: expected_lock_version(fields))
        if result.done?
          redirect_to admin_model_provider_path(provider_id), notice: t("admin.model_providers.model_saved"), status: :see_other
        else
          configuration_error(@form, result, template: template)
        end
      else
        render template, status: :unprocessable_entity
      end
    end
end
