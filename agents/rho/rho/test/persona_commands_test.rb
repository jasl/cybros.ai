require "test_helper"

class PersonaCommandsTest < Minitest::Test
  include RhoTest::CliHarness

  def persona_row(content)
    { "slot" => "persona", "role" => "system", "content" => content,
      "bytesize" => content.bytesize, "version" => 1, "written_at" => "2026-10-07T01:00:00Z" }
  end

  def test_set_show_and_reset_use_the_human_platform_proxy_and_preserve_the_authored_text
    seen = []
    content = "Prefer concise replies.\nCall me {{user}}.\n"
    row = persona_row(content)
    announce(endpoint: recording_routed_endpoint(seen, {
      "POST /nexus/request" => [
        [200, { "status" => 200, "headers" => {}, "body" => { "prompt_document" => row } }],
        [200, { "status" => 200, "headers" => {}, "body" => { "prompt_document" => row } }],
        [200, { "status" => 204, "headers" => {}, "body" => nil }],
      ],
    }))
    path = File.join(@root, "persona.md")
    File.write(path, content)
    command = Rho::Extensions::Ops::Persona.method(:command)
    command.call(cli, ["set", path], {})
    assert_includes @out.string, "Persona saved in Nexus"
    @out.truncate(0)
    @out.rewind
    # A fresh terminal/Core reads Nexus again; it has no local persona cache.
    result = command.call(cli, ["show"], {})
    assert_equal content, result.fetch(:content)
    assert_equal content, @out.string
    command.call(cli, ["reset"], {})
    assert_includes @out.string, "Persona reset."

    requests = seen.grep(%r{\APOST /nexus/request}).map { |request| JSON.parse(request.partition("\r\n\r\n").last) }
    assert_equal ["/api/v1/persona"] * 3, requests.map { |request| request.fetch("path") }
    assert_equal %w[PUT GET DELETE], requests.map { |request| request.fetch("method") }
    assert_equal({ "prompt_document" => { "content" => content } }, requests.first.fetch("body"))
  end

  def test_stdin_and_json_work_without_a_local_persona_file
    seen = []
    content = "请用中文回复。\n"
    announce(endpoint: recording_routed_endpoint(seen, {
      "POST /nexus/request" => [[200, { "status" => 200, "headers" => {}, "body" => { "prompt_document" => persona_row(content) } }]],
    }))
    Rho::Extensions::Ops::Persona.command(cli, ["set", "-"], { json: true }, input: StringIO.new(content))
    assert_equal content, JSON.parse(@out.string).fetch("content")
    assert_equal 1, seen.grep(%r{\APOST /nexus/request}).length
  end

  def test_a_persona_over_the_document_bound_is_refused_before_sending
    error = assert_raises(Rho::Error) do
      Rho::Extensions::Ops::Persona.command(cli, ["set", "-"], {}, input: StringIO.new("x" * (64 * 1024 + 1)))
    end
    assert_equal "A persona must fit within 64 KiB", error.message
  end

  def test_missing_human_login_does_not_fall_back_to_the_agent_credential
    announce(endpoint: routed_endpoint("POST /nexus/request" => [[401, { "error" => { "code" => "unauthorized", "message" => "Sign in" } }]]))
    assert_raises(CybrosAgent::Api::Unauthorized) { Rho::Extensions::Ops::Persona.command(cli, ["show"], {}) }
    assert_empty @out.string
  end

  def test_show_and_reset_report_an_absent_persona_without_creating_one
    seen = []
    announce(endpoint: recording_routed_endpoint(seen, {
      "POST /nexus/request" => [[200, { "status" => 404, "headers" => {},
        "body" => { "error" => { "code" => "prompt_document_not_found", "message" => "No such prompt document" } } }]],
    }))
    assert_nil Rho::Extensions::Ops::Persona.command(cli, ["show"], {})
    assert_equal "No persona is set.\n", @out.string
    assert_nil Rho::Extensions::Ops::Persona.command(cli, ["reset"], {})
    assert_equal %w[GET DELETE], seen.grep(%r{\APOST /nexus/request}).map { |request| JSON.parse(request.partition("\r\n\r\n").last).fetch("method") }
  end

  def test_invalid_text_and_wrong_grammar_are_refused_before_transport
    assert_raises(Rho::Error) do
      Rho::Extensions::Ops::Persona.command(cli, ["set", "-"], {}, input: StringIO.new("\xFF".b))
    end
    assert_raises(Rho::Error) { Rho::Extensions::Ops::Persona.command(cli, ["set"], {}) }
    assert_empty @out.string
  end
end
