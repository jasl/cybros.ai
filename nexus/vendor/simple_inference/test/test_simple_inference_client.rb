require "json"
require "test_helper"

class TestSimpleInferenceClient < Minitest::Test
  include TestProfiles

  def build_client(**options)
    SimpleInference::Client.new(
      base_url: "http://example.com",
      execution_profile: build_execution_profile,
      **options
    )
  end

  def test_client_exposes_resource_objects_and_not_chat_helpers
    client = build_client(api_key: "secret")

    assert_respond_to client, :responses
    assert_respond_to client, :images
    assert_respond_to client.responses, :create
    assert_respond_to client.responses, :stream
    assert_respond_to client.images, :generate
    refute_respond_to client, :chat
    refute_respond_to client, :chat_stream
  end

  def test_client_requires_an_execution_profile_value
    error =
      assert_raises(ArgumentError) do
        SimpleInference::Client.new(base_url: "http://example.com", api_key: "secret")
      end

    assert_includes error.message, "execution_profile"
  end

  def test_client_rejects_a_profile_id_string_in_place_of_the_value
    error =
      assert_raises(SimpleInference::ConfigurationError) do
        SimpleInference::Client.new(
          base_url: "http://example.com",
          execution_profile: "openai_api.openai_responses.text_generation.v1"
        )
      end

    assert_includes error.message, "compose one from an api_format"
  end

  def test_client_raises_configuration_error_for_invalid_headers_shape
    error =
      assert_raises(SimpleInference::ConfigurationError) do
        build_client(headers: [])
      end

    assert_includes error.message, "headers"
  end

  def test_client_rejects_a_positional_options_bag
    assert_raises(ArgumentError) { SimpleInference::Client.new([]) }
  end

  def test_client_raises_configuration_error_for_invalid_timeout_value
    error =
      assert_raises(SimpleInference::ConfigurationError) do
        build_client(timeout: "oops")
      end

    assert_includes error.message, "timeout"
  end
end
