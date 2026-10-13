require "test_helper"
require "tmpdir"

# Mounted providers all use the same catalog contract. Environment-specific
# filenames decide which fragments load; a provider identifier does not add a
# second, hidden environment policy.
class ModelCatalog::MountedProviderTest < ActiveSupport::TestCase
  def dev_fragment
    {
      "schema_version" => ModelCatalog::FileBase::SCHEMA_VERSION,
      "providers" => {
        "dev" => {
          "base_url" => "http://127.0.0.1:3000/mock_llm",
          "api_format" => "openai_responses",
          "concurrency_limit" => 8,
        },
      },
      "models" => {
        "dev/mock-text" => {
          "capabilities" => {
            "input_modalities" => ["image"],
            "output_modalities" => ["text"],
            "limits" => { "input_tokens" => 8_192, "output_tokens" => 2_048 },
          },
        },
      },
      "selectors" => {},
    }.to_yaml
  end

  test "a deliberately mounted provider compiles in every environment" do
    Dir.mktmpdir("mounted-provider") do |root|
      File.write(File.join(root, "90_dev.yml"), dev_fragment)

      %w[development test production].each do |env|
        assert ModelCatalog::FileBase.compile(root: root, env: env),
          "a valid mounted provider must compile in #{env}"
      end
    end
  end

  test "no shipped fragment mounts the development provider" do
    shipped = ModelCatalog::FileBase.compile(
      root: Rails.root.join("config/model_catalog"), override_dir: nil
    )

    assert_not shipped.providers.key?("dev")
    assert_empty shipped.models.keys.grep(%r{\Adev/})
  end
end
