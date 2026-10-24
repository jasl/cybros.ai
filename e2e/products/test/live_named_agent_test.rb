require "test_helper"
require "support/live_journey"
require "support/live_turns"
require "fileutils"
require "tmpdir"

# A project file supplies a reviewer Preset, then publishes it as a Subagent role.
# A real model fixes the fixture and delegates its review. The child keeps the
# parent's principal, captures the reviewer configuration, and owns only its
# conversation memory. Import, publication and execution create no standing User.
#
# Paid, local, opt-in: E2E_LIVE=1. A fix, a spawn and one child turn: cents.
class LiveNamedAgentTest < Minitest::Test
  MODEL = ENV.fetch("E2E_LIVE_MODEL") { E2E::LiveJourney.default_model }.freeze
  NAME = "project-reviewer".freeze
  DESCRIPTION = "Reviews a change for defects and reports only what matters; use it after a change lands.".freeze
  REVIEWER_BODY = "Review the change the spawner names and report only what matters.".freeze
  # The person's own definition file: a description, a tools subset, and
  # the same sentence as its body.
  REVIEWER = <<~MD.freeze
    ---
    name: #{NAME}
    description: #{DESCRIPTION}
    tools: read, grep
    model: #{MODEL}
    ---
    #{REVIEWER_BODY}
  MD
  PROJECT = {
    "lib/calc.rb" => <<~RUBY,
      module Calc
        def self.add(a, b) = a + b
        def self.sub(a, b) = a + b
      end
    RUBY
    "test/calc_test.rb" => <<~RUBY,
      require "minitest/autorun"
      require_relative "../lib/calc"

      class CalcTest < Minitest::Test
        def test_adds = assert_equal(3, Calc.add(1, 2))
        def test_subtracts = assert_equal(1, Calc.sub(3, 2))
      end
    RUBY
  }.freeze
  TASK = "lib/calc.rb has a bug in Calc.sub: fix it and run test/calc_test.rb. Then have the #{NAME} role " \
         "check your change and tell me what it found. Reply with the reviewer's verdict.".freeze

  include E2E::LiveJourney
  include E2E::LiveTurns

  # THE ENVIRONMENT ROOT IS OUTSIDE THE HOME (the `named_agents` shape): the
  # definitions live under it, so the floor and the incubation denies —
  # which protect `$RHO_HOME` whole — have no opinion on the project.
  def setup
    start_live_journey!(MODEL, home_prefix: "rho-live-named-agent-e2e")
    @root = Dir.mktmpdir("rho-live-named-agent-root")
    @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home, tools_root: @root, definitions: { NAME => REVIEWER })
  end

  def teardown
    finish_live_journey!
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def test_a_real_model_delegates_to_an_imported_reviewer_role_without_creating_an_identity
    connect_and_open_lane!
    PROJECT.each do |path, contents|
      full = File.join(@root, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, contents, encoding: Encoding::UTF_8)
    end

    identities = principal_ids
    imported, status = @daemon.cli("presets", "import", NAME)
    assert_predicate status, :success?, "rho presets import failed:\n#{imported}"
    assert_match(/^imported: 1  skipped: 0$/, imported, imported)
    reviewer = @daemon.control(:get, "/presets").fetch("presets").find { |row| row.fetch("name") == NAME }
    refute_nil reviewer
    assert_equal MODEL, reviewer.dig("configuration", "model")
    assert_equal %w[grep read], reviewer.dig("configuration", "runner_tool_names").sort
    assert_nil reviewer.fetch("role")
    @daemon.control(:put, "/presets/role", body: { "public_id" => reviewer.fetch("public_id"), "name" => NAME, "description" => DESCRIPTION })
    listed, status = @daemon.cli("presets")
    assert_predicate status, :success?, "rho presets failed:\n#{listed}"
    assert_includes listed, "#{reviewer.fetch("public_id")}  #{NAME}  (role: #{NAME})"
    assert_equal identities, principal_ids

    # THE TURN: the person's ask, watched to its end.
    conversation, _turn, loop_id = rho_do_turn(TASK, model: MODEL, dir: @root)
    watched, status = rho_watch(loop_id, "--timeout", "600")
    assert_predicate status, :success?, watched
    done = await_loop_completion(loop_id)

    spawn = done.fetch("tasks").find { |task| task["tool_name"] == "spawn" }
    spawn_input = spawn ? task_input(loop_id, spawn.fetch("key")) : {}
    waited = spawn_input["wait"] == true
    child = conversation_door(conversation).children.items.first
    answerer = conversation_door(conversation).fetch.answering_user_public_id
    same_principal = !child.nil? && child.answering_user_public_id == answerer
    reply = child && await_reply(conversation_door(child.public_id), after: -1)
    child_loop = reply&.active_variant&.run_public_id
    verdict = child_loop ? @daemon.cli("result", child_loop).first : nil
    # A detached child's reply is mail that wakes the parent's next turn:
    # waited for, so the world settles and the parent's answer carries it.
    woken = spawn && !waited && next_turn_loop(conversation, after: [loop_id], deadline: 120)
    await_loop_completion(woken) if woken
    parent_answer, = @daemon.cli("result", woken || loop_id)
    report(done, waited, child, same_principal, child_loop, verdict, parent_answer)
    report_loop!(done, reached: !spawn.nil?, succeeded: same_principal && !reply.nil?)

    assert_equal "completed", done.fetch("status"), summarize(done)
    flunk "the model never delegated the review (no spawn): #{summarize(done)}" if spawn.nil?
    refute_nil child, "the spawn minted no child: #{spawn.inspect}"
    assert same_principal, "the child must retain the parent's execution principal"
    assert_predicate child, :subagent?
    refute_nil reply, "the reviewer's turn never settled"
    refute_nil child_loop
    assert_equal MODEL, loop_row(child_loop).dig("turn", "model", "model"),
      "the reviewer uses its captured Preset model"
    request = agent_api("#{loop_path(child_loop)}/tasks/r1/request").fetch("request")
    prompts = request.fetch("entries").flat_map { |entry| entry.fetch("parts", []).filter_map { |part| part["text"] } }.join("\n")
    assert_includes prompts, REVIEWER_BODY
    tools = task_detail(child_loop, "r1").fetch("tool_definitions")
    assert_equal %w[grep read], tools.map { |tool| tool.dig("function", "name") }.sort
    document = conversation_door(child.public_id).fetch
    assert document.agent_configuration_present
    assert_equal ["conversation"], document.effective_memory_context.fetch("bindings").map { |binding| binding.fetch("name") }
    assert_equal identities, principal_ids
    assert_match(/^  spawned\s+#{Regexp.escape(child.public_id)} .*answered by #{Regexp.escape(answerer)}/,
      watched, "the watch names the child's retained principal:\n#{watched}")
  end

  private

    def principal_ids = steward_client.workspace(workspace_public_id).principals.map(&:public_id).sort

    def report(row, waited, child, same_principal, child_loop, verdict, parent_answer)
      tools = row.fetch("tasks").select { |task| task.fetch("kind") == "tool_task" }
      puts "\n--- live reviewer role ----------------------------------------"
      puts "model:    #{MODEL}"
      puts "status:   #{row.fetch("status")}"
      puts "calls:    #{tools.map { |task| task["tool_name"] }.tally.map { |name, n| "#{name}x#{n}" }.join(" ")}"
      puts "spawn:    wait=#{waited.inspect}"
      puts "child:    #{child ? "#{child.public_id} answered by #{child.answering_user_public_id} (parent principal: #{same_principal})" : "(none)"}"
      puts "review:   #{child_loop ? "#{child_loop} #{verdict.to_s.strip[0, 200].inspect}" : "(no turn)"}"
      puts "answer:   #{parent_answer.to_s.strip[0, 200].inspect}"
      puts "--------------------------------------------------------------"
    end
end
