require "test_helper"

class CliMcpReportingTest < Minitest::Test
  include RhoTest::CliHarness

  TARGET = { "kind" => "mcp", "connection_public_id" => "01900000-0000-7000-8000-000000000091",
    "display_name" => "Company notes", "account_label" => "Work account", "tool_name" => "search" }.freeze

  def test_approval_names_the_exact_connection_account_and_callable
    announce(endpoint: routed_endpoint(
      "GET /status" => [[200, { "state" => "active", "authority" => { "signed" => "signed_in" } }]],
      "GET /asks" => [[200, { "asks" => [
        { "kind" => "approval", "run_public_id" => "run-1", "task_key" => "r1t0", "tool_name" => "search",
          "tool_alias" => "work_search", "tool_input" => { "query" => "notes" }, "target" => TARGET },
      ] }]]
    ))

    cli.report_status

    assert_includes @out.string, "work_search [MCP Company notes · Work account · search (#{TARGET.fetch("connection_public_id")})]"
  end

  def test_task_details_keep_remote_target_facts_and_escape_display_text
    cli.print_task("key" => "r1t0", "kind" => "tool_task", "status" => "completed", "tool_name" => "search",
      "tool_alias" => "work_search", "target" => TARGET.merge("account_label" => "Work\naccount"))

    assert_includes @out.string, "tool:      work_search\n"
    assert_includes @out.string, "target:    MCP Company notes · Work\\u000Aaccount · search"
    refute_includes @out.string, "Work\naccount"
  end
end
