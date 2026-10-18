require "test_helper"
require "support/evals"
require "evals_drawings"

class EvalsSealedRequestTest < Minitest::Test
  D = E2E::Evals::Drawing
  S = E2E::Evals::SealedRequest
  P = E2E::Evals::Predicates
  W = EvalsDrawings
  ENTRIES = [{ "role" => "user", "content" => [{ "type" => "input_text", "text" => "hello" }] }].freeze
  TOOLS = [{ "type" => "function", "function" => { "name" => "bash", "description" => "d", "parameters" => {} } },
           { "type" => "function", "function" => { "name" => "Workflow", "parameters" => {} } }].freeze
  SEALED = { "task_key" => "r2", "entries" => ENTRIES, "request_options" => { "tools" => TOOLS, "temperature" => 0 } }.freeze

  def test_the_last_completed_round_is_read_in_row_order
    tasks = [D.round("r1"), D.tool("r1t0", "bash", after: ["r1"]), D.round("r2"), D.round("r3", status: "running")]
    assert_equal "r2", S.last_completed_round(tasks)
    assert_equal "r1t0-model-1", S.last_completed_round([D.round("r1"), D.round("r1t0-model-1")]), "a branch's round counts too"
    assert_nil S.last_completed_round([D.round("r1", status: "failed")])
    assert_nil S.last_completed_round([])
    mainline_only = [D.round("r1"), D.round("r1t0-model-1"), D.round("r2"), D.round("r3", status: "running")]
    assert_equal "r2", S.last_completed_round(mainline_only, among: %w[r1 r2 r3]), "the graph's mainline keys, when the caller has them"
    assert_nil S.last_completed_round([D.round("r1t0-model-1")], among: ["r1"])
  end

  def test_the_key_to_seal_is_the_last_completed_round
    plain = [D.round("r1"), D.tool("r1t0", "bash", after: ["r1"]), D.round("r2")]
    assert_equal "r2", S.key_for(plain)
    rows = [D.round("r1"), D.tool("r1t0", "code", after: ["r1"]), D.round("r3"), D.round("r4"), D.round("r5"), D.round("r2")]
    assert_equal "r2", S.key_for(rows)
    later = [D.round("r1"), D.tool("r1t0", "read", after: ["r1"]), D.round("r2"), D.tool("r2t0", "code", after: ["r2"]), D.round("r3")]
    assert_equal "r3", S.key_for(later), "the last completed round supplies the sealed request"
    assert_equal "r2", S.key_for(plain + [D.round("r1t0-model-1")], mainline_keys: %w[r1 r2]), "a branch's round is not sealed when the mainline is marked"
    assert_equal "r1t0-model-1", S.key_for(plain + [D.round("r1t0-model-1")]), "without the marks the last completed round stands"
    assert_nil S.key_for([])
  end

  def test_the_routes_document_becomes_the_traces_sealed_request_or_nil
    assert_equal SEALED, S.from_document({ "request" => { "entries" => ENTRIES, "request_options" => SEALED["request_options"] } }, "r2")
    assert_nil S.from_document({ "error" => { "code" => S::NOT_SEALED } }, "r1t0")
    assert_nil S.from_document(nil, "r1")
  end

  def test_the_bytes_and_the_tool_names
    assert_equal JSON.generate(ENTRIES).bytesize, S.bytes(SEALED)
    assert_nil S.bytes(nil)
    assert_equal %w[bash Workflow], S.tool_names(SEALED)
    assert_equal ["read"], S.tool_names({ "entries" => [], "request_options" => { "tools" => [{ "name" => "read" }] } }), "a bare name reads too"
    assert_equal [], S.tool_names({ "entries" => [], "request_options" => {} })
    assert_equal [], S.tool_names(nil)
  end

  def test_declared_names_read_the_sealed_request_over_the_style
    sealed = D.trace(W::LINEAR_GRAPH, [], [], facts: { "style" => "nexus" }).with(sealed: SEALED)
    assert_equal %w[bash Workflow], P.declared_names(sealed)
    unsealed = D.trace(W::LINEAR_GRAPH, [], [], facts: { "style" => "nexus" })
    assert_includes P.declared_names(unsealed), "code"
    refute_includes P.declared_names(unsealed), "Workflow"
  end

  def test_the_cli_print_is_read_back_against_the_routes_bytes
    printed = "request_options:\n#{JSON.pretty_generate(SEALED["request_options"])}\n\nentries:\n#{JSON.pretty_generate(ENTRIES)}\n"
    assert_equal true, S.cli_agrees(printed, SEALED)
    assert_match(/printed no request_options: heading/, S.cli_agrees("error: no such loop\n", SEALED))
    assert_match(/printed no entries: heading/, S.cli_agrees("request_options:\n{}\n", SEALED))
    fewer = "request_options:\n{}\n\nentries:\n[]\n"
    assert_equal "rho request printed 0 entries where the route served 1", S.cli_agrees(fewer, SEALED)
    assert_match(/did not parse/, S.cli_agrees("request_options:\n{}\n\nentries:\n[oops\n", SEALED))
  end
end
