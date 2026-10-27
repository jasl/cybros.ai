module Admin::ModelDefaultsHelper
  def model_definition_defaults(form)
    form.model_definitions.to_h do |name, definition|
      [name, model_definition_default(definition, prompt_cache: model_prompt_cache_options(form, inherited: name))]
    end
  end

  # The browser and the first render consume the same localized projection;
  # neither resolves or copies these defaults into the authored declaration.
  def model_definition_default(definition, prompt_cache:)
    capabilities = definition.fetch("capabilities", {})
    limits = capabilities.fetch("limits", {})
    {
      "facts" => capabilities.empty? ? [] : model_default_fact_rows(capabilities),
      "limits" => Admin::ModelProviders::ModelForm::LIMIT_FIELDS.to_h do |key|
        value = model_default_value(limits[key])
        defaults = if limits.key?(key)
          { "placeholder" => limits.fetch(key).to_s,
            "inherited" => model_default_copy("inherited_default", value: value),
            "overridden" => model_default_copy("model_default_not_inherited", value: value) }
        else
          { "placeholder" => "", "inherited" => model_default_copy("protocol_default_unspecified"),
            "overridden" => model_default_copy("protocol_default_unspecified") }
        end
        [key, defaults]
      end,
      "booleans" => Admin::ModelProviders::ModelForm::BOOLEAN_FIELDS.to_h do |key|
        defaults = if capabilities.key?(key)
          value = model_default_copy(capabilities.fetch(key) ? "supported" : "disabled")
          { "label" => model_default_copy("use_model_default", value: value),
            "hint" => model_default_copy("model_default", value: value) }
        else
          { "label" => model_default_copy("use_protocol_default_unspecified"),
            "hint" => model_default_copy("protocol_default_unspecified") }
        end
        [key, defaults]
      end,
      "media" => model_default_media(capabilities),
      "promptCache" => prompt_cache,
    }
  end

  def model_prompt_cache_options(form, inherited:)
    parameter = form.prompt_cache_parameter(inherited: inherited)
    values = parameter ? parameter.fetch("allowed_values") : []
    {
      "options" => [[model_default_copy("prompt_cache_default"), ""], *values.map { |value|
        [model_default_copy("prompt_cache_durations.#{value}"), value]
      }],
      "default" => parameter&.fetch("default").to_s,
      "supported" => values.any?,
    }
  end

  def model_form_limits_overridden?(form)
    Admin::ModelProviders::ModelForm::LIMIT_FIELDS.any? { |key| form.public_send(key).present? } ||
      (!form.reset_limits && (form.original_limits.except(*Admin::ModelProviders::ModelForm::LIMIT_FIELDS).any? ||
        (form.empty_limits_override? && !form.limits_edited)))
  end

  def model_default_copy(key, **values)
    t("admin.model_providers.model_definitions.form.#{key}", **values)
  end

  private

    def model_default_fact_rows(value, path = [])
      # Capabilities are a validated JSON tree: mappings recurse and every
      # other JSON value remains one visible fact, including false and empty.
      case value
      when Hash
        if value.empty?
          [model_default_fact(value, path)]
        else
          value.flat_map { |key, nested| model_default_fact_rows(nested, [*path, key]) }
        end
      when Array, String, Numeric, TrueClass, FalseClass, NilClass
        [model_default_fact(value, path)]
      else
        raise ArgumentError, "unsupported capability value"
      end
    end

    def model_default_fact(value, path)
      labels = t("admin.model_providers.model_definitions.form.facts")
      { "label" => path.map { |key| labels.fetch(key.to_sym) { key.humanize } }.join(" / "),
        "value" => model_default_value(value, path.last) }
    end

    def model_default_value(value, key = nil)
      case value
      when NilClass then model_default_copy("default_null")
      when TrueClass then model_default_copy(key == "disable_supported" ? "default_yes" : "default_enabled")
      when FalseClass then model_default_copy(key == "disable_supported" ? "default_no" : "disabled")
      when Numeric then number_with_delimiter(value)
      when String then value
      when Array
        if value.empty?
          model_default_copy(key == "input_modalities" ? "media_text_only" : "default_empty_list")
        elsif key == "input_modalities"
          labels = t("admin.model_providers.model_definitions.form.media_types")
          value.map { |item| labels.fetch(item.to_sym, item) }.join(", ")
        else
          value.map { |item| model_default_value(item) }.join(", ")
        end
      when Hash then value.empty? ? model_default_copy("default_empty_object") : value.to_json
      else raise ArgumentError, "unsupported capability value"
      end
    end

    def model_default_media(capabilities)
      media = capabilities.fetch("input_modalities", [])
      if capabilities.key?("input_modalities")
        value = model_default_value(media, "input_modalities")
        { "values" => media, "inherited" => model_default_copy("inherited_default", value: value),
          "custom" => model_default_copy("model_default", value: value) }
      else
        { "values" => media, "inherited" => model_default_copy("protocol_default_unspecified"),
          "custom" => model_default_copy("protocol_default_unspecified") }
      end
    end
end
