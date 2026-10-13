module ModelCatalog::ValidationTestSupport
  SCHEMA = ModelCatalog::FileBase::SCHEMA_VERSION

  def write_fragment(root, models:, providers: { "openai_api" => { "base_url" => "https://api.openai.com", "api_format" => "openai_responses", "concurrency_limit" => 8 } }, selectors: {})
    File.write(File.join(root, "10_base.yml"),
      {
        "schema_version" => SCHEMA,
        "providers" => providers,
        "models" => models,
        "selectors" => selectors,
      }.to_yaml)
  end

  def text_entry(overrides = {})
    {
      "capabilities" => {
        "input_modalities" => ["image"],
        "output_modalities" => ["text"],
        "limits" => { "combined_input_output_tokens" => 400_000, "output_tokens" => 128_000 },
      },
    }.deep_merge(overrides)
  end

  def compile(root)
    ModelCatalog::FileBase.compile(root: root, override_dir: nil)
  end

  private

    def closed_capabilities(output_modalities:, limits: {})
      {
        "input_modalities" => [],
        "output_modalities" => output_modalities,
        "limits" => limits,
      }
    end
end
