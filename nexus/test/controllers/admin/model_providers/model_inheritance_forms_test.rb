require "test_helper"

class Admin::ModelProviders::ModelInheritanceFormsTest < ActionDispatch::IntegrationTest
  setup do
    @account = accounts(:cybros)
    sign_in_as users(:owner)
    @definitions = {
      "example-window" => { "capabilities" => {
        "limits" => { "combined_input_output_tokens" => 65536, "output_tokens" => 4096 },
        "tool_calls" => false, "streaming" => true, "input_modalities" => ["image"],
      } },
      "example-large" => { "capabilities" => {
        "limits" => { "combined_input_output_tokens" => 131072, "output_tokens" => 8192 },
        "input_modalities" => ["image", "audio"],
      } },
    }
    @snapshot = ModelCatalog.current.with(model_definitions: @definitions)
  end

  test "saving an inherited model keeps defaults absent and retains an explicit empty limits block" do
    with_model("capabilities" => { "limits" => {} }) do
      update_model(display_name: "Deployment name")
      assert_equal({ "limits" => {} }, saved_definition.fetch("capabilities"))
      assert_equal "example-window", saved_definition.fetch("inherit")
    end
  end

  test "restoring model limits clears the whole block while preserving unedited capabilities" do
    with_model("capabilities" => { "limits" => { "input_bytes" => 4096 }, "reasoning" => nil }, "token_counter" => nil) do
      update_model(display_name: "Unchanged limits")
      assert_equal({ "input_bytes" => 4096 }, saved_definition.dig("capabilities", "limits"))

      update_model(reset_limits: "true", limits_edited: "true")
      assert_equal({ "reasoning" => nil }, saved_definition.fetch("capabilities"))
      assert_nil saved_definition.fetch("token_counter")
      assert_equal 65536, effective_capabilities.dig("limits", "combined_input_output_tokens")
    end
  end

  test "an empty limits override survives a failed save until explicitly restored" do
    with_model("capabilities" => { "limits" => {} }) do
      patch model_path, params: { model_definition: fields.merge(model_id: "", reset_limits: "true", limits_edited: "true") }
      assert_response :unprocessable_entity
      assert_select "input[name='model_definition[reset_limits]'][value='true']"
      assert_equal({}, saved_definition.dig("capabilities", "limits"))

      update_model(reset_limits: "true", limits_edited: "true")
      assert_not saved_definition.key?("capabilities")
    end
  end

  test "a text only deployment stores an empty media override and can return to inheritance" do
    with_model do
      update_model(input_modalities_mode: "custom", input_modalities: [""])
      assert_equal [], saved_definition.dig("capabilities", "input_modalities")
      assert_equal [], effective_capabilities.fetch("input_modalities")
      get model_path, params: { model: model_ref }
      assert_response :success
      assert_select "select[name='model_definition[input_modalities_mode]'] option[value='custom'][selected]"

      update_model(input_modalities_mode: "inherit", input_modalities: ["image"])
      assert_not saved_definition.key?("capabilities")
      assert_equal ["image"], effective_capabilities.fetch("input_modalities")
    end
  end

  test "switching definitions preserves explicit overrides including a value equal to its former default" do
    with_model do
      update_model(combined_input_output_tokens: "65536", limits_edited: "true",
        tool_calls: "false", input_modalities_mode: "custom", input_modalities: ["", "image"])
      update_model(inherit: "example-large")
      assert_equal({ "limits" => { "combined_input_output_tokens" => 65536 }, "tool_calls" => false,
        "input_modalities" => ["image"] }, saved_definition.fetch("capabilities"))
      assert_equal "example-large", saved_definition.fetch("inherit")
      assert_equal({ "combined_input_output_tokens" => 65536 }, effective_capabilities.fetch("limits"))
    end
  end

  test "saving without overrides retains only the inheritance reference and request identity" do
    with_model do
      update_model(input_modalities_mode: "inherit", input_modalities: [""])
      assert_equal({ "inherit" => "example-window", "model_id" => "text" }, saved_definition)
    end
  end

  private

    def with_model(extra = {})
      ModelCatalog.stub(:current, @snapshot) do
        post admin_model_providers_path, params: { provider_definition: {
          provider_id: "inherited-form", api_format: "openai_compatible_chat",
          base_url: "http://localhost:11434/v1", credentials: "none", expected_lock_version: "",
        } }
        assert_response :see_other
        result = ModelProviders::UpsertModelOverride.call(account: @account, provider_id: "inherited-form",
          model_ref: model_ref, model: { "inherit" => "example-window", "model_id" => "text" }.merge(extra),
          validate_definition: true, expected_lock_version: policy.lock_version)
        assert_predicate result, :done?
        yield
      end
    end

    def update_model(**changes)
      patch model_path, params: { model_definition: fields.merge(changes) }
      assert_redirected_to admin_model_provider_path("inherited-form")
    end

    def fields
      { model: model_ref, model_id: "text", expected_lock_version: policy.lock_version }
    end

    def model_path
      admin_model_provider_model_definition_path("inherited-form")
    end

    def model_ref
      "inherited-form/text"
    end

    def policy
      ModelProviderConfig.find_by!(account: @account, provider_id: "inherited-form")
    end

    def saved_definition
      policy.override_entries.fetch(model_ref).fetch("model")
    end

    def effective_capabilities
      ModelSelection::Resolver.effective_provider_catalog(@account, @snapshot, "inherited-form")
        .models.fetch(model_ref).fetch("capabilities")
    end
end
