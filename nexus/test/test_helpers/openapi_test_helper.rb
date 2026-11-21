require "json_schemer"

module OpenapiTestHelper
  def self.document
    @document ||= JSON.parse(JSON.generate(Nexus::Openapi.build))
  end

  def self.validator(schema)
    @validators ||= {}
    @validators[schema] ||= JSONSchemer.schema(document.merge("allOf" => [schema]))
  end

  def openapi_document
    OpenapiTestHelper.document
  end

  def openapi_resolve(value)
    if value.key?("$ref")
      value.fetch("$ref").delete_prefix("#/").split("/").reduce(openapi_document) do |node, key|
        node.fetch(key.gsub("~1", "/").gsub("~0", "~"))
      end
    else
      value
    end
  end

  def assert_openapi_schema(schema, value)
    validator = OpenapiTestHelper.validator(schema)
    assert_empty validator.validate(value).map { |error| error.slice("data_pointer", "type", "error") }, "OpenAPI schema drift: #{schema}"
  end

  def assert_openapi_request(value, path:, method:, media_type: "application/json")
    operation = openapi_document.fetch("paths").fetch(path).fetch(method)
    body = openapi_resolve(operation.fetch("requestBody"))
    schema = body.fetch("content").fetch(media_type).fetch("schema")
    assert_openapi_schema(schema, value)
  end

  def assert_openapi_response(path: nil)
    path ||= openapi_request_path
    operation = openapi_document.fetch("paths").fetch(path).fetch(request.request_method.downcase)
    declaration = openapi_resolve(operation.fetch("responses").fetch(response.status.to_s))
    if response.body.empty?
      assert_not declaration.key?("content"), "Document the empty #{response.status} response"
    else
      media = declaration.fetch("content").fetch(response.media_type)
      schema = media.fetch("schema")
      validator = OpenapiTestHelper.validator(schema)
      assert_empty validator.validate(response.parsed_body).map { |error| error.slice("data_pointer", "type", "error") },
        "OpenAPI response drift: #{request.request_method} #{path} (#{response.status})"
    end
  end

  def openapi_request_path
    Rails.application.routes.router.recognize(request) do |route, _parameters|
      return route.path.spec.to_s.delete_suffix("(.:format)").gsub(/:(\w+)/, '{\1}')
    end
    nil
  end
end

# The existing behavior assertions remain authoritative. Add schema validation
# at their assertion boundary so each exercised response, including refusals,
# is checked without changing the request or installing runtime middleware.
module OpenapiResponseAssertions
  include OpenapiTestHelper

  def assert_response(...)
    super
    if response.media_type == "application/json" || response.body.empty?
      path = openapi_request_path
      assert_openapi_response(path: path) if openapi_document.fetch("paths").key?(path)
    end
  end
end
