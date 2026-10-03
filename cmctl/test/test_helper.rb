require "minitest/autorun"
require "tmpdir"
require "stringio"
require "cybros_control"

class OperatorTest < Minitest::Test
  SESSION = { "public_id" => "session-1", "kind" => "api", "expires_at" => "2026-10-01T00:00:00Z" }.freeze
  TOKEN = "synthetic-session-secret".freeze

  class Transport
    attr_reader :requests

    def initialize
      @requests = []
      @responses = []
    end

    def answer(status, body)
      @responses << CybrosAgent::Response.new(status: status, headers: {}, body: body)
    end

    def call(path, **arguments)
      @requests << arguments.merge(path: path)
      @responses.shift || raise("Unexpected HTTP request to #{path}")
    end
  end

  def setup
    @home = Dir.mktmpdir("cmctl-test-")
    @config = CybrosControl::Config.new(home: @home)
    @transport = Transport.new
  end

  def teardown
    FileUtils.remove_entry(@home)
  end

  def run_cli(*arguments, input: "")
    @output = StringIO.new
    @error = StringIO.new
    cli = CybrosControl::CLI.new(
      input: StringIO.new(input), output: @output, error: @error,
      env: { "CMCTL_HOME" => @home },
      sessions: ->(url) { CybrosAgent::Sessions.new(base_url: url, transport: @transport) },
      clients: ->(url, token) { CybrosAgent::PlatformClient.new(base_url: url, credential: token, transport: @transport) }
    )
    cli.run(arguments)
  end

  def output = JSON.parse(@output.string)

  def saved_session
    @config.write(base_url: "http://localhost:3000", token: TOKEN)
  end

  def profile(role: "owner")
    { "member" => { "public_id" => "human-1", "kind" => "human", "role" => role }, "credential_plane" => nil }
  end

  def lane(version: nil, enabled: false)
    { "id" => "example", "credentials" => "api_key", "enabled" => enabled,
      "lock_version" => version, "configured" => true, "models" => 1, "unavailable_until" => nil }
  end

  def catalog_configuration(definition: { "base_url" => "http://localhost:11434/v1", "api_format" => "openai_compatible_chat", "credentials" => "none" },
                            source: "custom", models: [], version: 3, **fields)
    { "model_provider" => lane(version: version).merge("credentials" => definition&.fetch("credentials"), "models" => models.length)
      .merge(fields.transform_keys(&:to_s)),
      "configuration" => { "definition" => definition, "source" => source, "models" => models } }
  end

  def model_definition_row(definition = {}, removed: false)
    { "model" => "example/vendor/chat", "definition" => definition, "source" => "override", "removed" => removed }
  end
end
