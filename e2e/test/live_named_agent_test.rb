require "test_helper"
require "support/live_journey"
require "support/live_turns"
require "fileutils"
require "tmpdir"

# A FILE-DEFINED AGENT ON A REAL MODEL (the mock lane `named_agents` pins every row and byte; this
# paid lane exercises the flow with the floor model): `.agents/agents/reviewer.md` at the project
# root — a description and a tools subset — is read by the boot's declare edge and again by `rho
# agents sync`, registered as a DERIVED INSTANCE PROFILE of this rho (`@reviewer`), and rostered in
# rho's own slot. The person asks for a fix and then the reviewer's look at it; the model's reach —
# a spawn naming `@reviewer` rather than a bare subagent — is RECORDED; the pins are on the flow:
# the child's answerer is the reviewer's row, its turn ran and its reply settled (the reviewer's
# words recorded), and the parent's `rho watch` named the reviewer as the child's answerer.
#
# Paid, local, opt-in: E2E_LIVE=1. A fix, a spawn and one child turn: cents.
class LiveNamedAgentTest < Minitest::Test
  MODEL = ENV.fetch("E2E_LIVE_MODEL") { E2E::LiveJourney.default_model }.freeze
  NAME = "reviewer".freeze
  DESCRIPTION = "Reviews a change for defects and reports only what matters; use it after a change lands.".freeze
  # The person's own definition file: a description, a tools subset, and
  # the same sentence as its body.
  REVIEWER = <<~MD.freeze
    ---
    name: #{NAME}
    description: #{DESCRIPTION}
    tools: read, grep
    ---
    Review the change the spawner names and report only what matters.
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
  TASK = "lib/calc.rb has a bug in Calc.sub: fix it and run test/calc_test.rb. Then have the reviewer " \
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

  def test_a_file_defined_reviewer_answers_the_childs_turn_a_real_model_spawned_by_name
    connect_and_open_lane!
    PROJECT.each do |path, contents|
      full = File.join(@root, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, contents, encoding: Encoding::UTF_8)
    end

    # THE DEFINITION: the boot's declare edge (after adoption, its own
    # fiber), the sync verb, the listing.
    reviewer = await_instance_row(NAME)
    synced, status = @daemon.cli("agents", "sync")
    assert_predicate status, :success?, "rho agents sync failed:\n#{synced}"
    assert_match(/^declared: 1 \(#{NAME}\)   removed: 0   skipped: 0$/, synced, synced)
    listed, status = @daemon.cli("agents")
    assert_predicate status, :success?, "rho agents failed:\n#{listed}"
    assert_match(/^  @#{NAME}   #{NAME}   #{Regexp.escape(DESCRIPTION)}   model: —   tools: grep, read$/, listed, listed)
    assert_equal "instance", reviewer["scope"], reviewer.inspect

    # THE TURN: the person's ask, watched to its end.
    conversation, _turn, loop_id = rho_do_turn(TASK, model: MODEL, dir: @root)
    watched, status = rho_watch(loop_id, "--timeout", "600")
    assert_predicate status, :success?, watched
    done = await_loop_completion(loop_id)

    spawn = done.fetch("tasks").find { |task| task["tool_name"] == "spawn" }
    spawn_input = spawn ? task_input(loop_id, spawn.fetch("key")) : {}
    agent = spawn_input["agent"].to_s
    named = !spawn.nil? && (agent.delete_prefix("@") == NAME || agent == reviewer.fetch("public_id"))
    waited = spawn_input["wait"] == true
    child = conversation_door(conversation).children.items.first
    answered_by_reviewer = !child.nil? && child.answering_user_public_id == reviewer.fetch("public_id")
    reply = child && await_reply(conversation_door(child.public_id), after: -1)
    child_loop = reply&.active_variant&.agent_loop_public_id
    verdict = child_loop ? @daemon.cli("result", child_loop).first : nil
    # A detached child's reply is mail that wakes the parent's next turn:
    # waited for, so the world settles and the parent's answer carries it.
    woken = spawn && !waited && next_turn_loop(conversation, after: [loop_id], deadline: 120)
    await_loop_completion(woken) if woken
    parent_answer, = @daemon.cli("result", woken || loop_id)
    report(done, agent, waited, child, answered_by_reviewer, child_loop, verdict, parent_answer)
    report_loop!(done, reached: named, succeeded: answered_by_reviewer && !reply.nil?)

    assert_equal "completed", done.fetch("status"), summarize(done)
    flunk "the model never handed the review to an agent (no spawn): #{summarize(done)}" if spawn.nil?
    refute_nil child, "the spawn minted no child: #{spawn.inspect}"
    assert answered_by_reviewer,
      "the child's answerer is not the reviewer's row (agent=#{agent.inspect}): #{child.answering_user_public_id.inspect}"
    refute_nil reply, "the reviewer's turn never settled"
    assert_equal MODEL, loop_row(child_loop).dig("turn", "model", "model"),
      "F-3 step 3: a row without a model answers on the initiator's"
    assert_match(/^  spawned\s+#{Regexp.escape(child.public_id)} .*answered by #{Regexp.escape(reviewer.fetch("public_id"))}/,
      watched, "the watch names the reviewer's row as the child's answerer:\n#{watched}")
  end

  private

    # THE DAEMON'S LISTING (`GET /agents`): the kernel's rows as the door
    # answers them. The boot declares the files' rows on the bind edge
    # AFTER adoption, in its own fiber, so the row is awaited.
    def await_instance_row(name)
      @daemon.await("the boot never declared #{name}'s row") do
        @daemon.control(:get, "/agents").fetch("agents").fetch("instance").find { |row| row["name"] == name }
      end
    end

    def report(row, agent, waited, child, answered_by_reviewer, child_loop, verdict, parent_answer)
      tools = row.fetch("tasks").select { |task| task.fetch("kind") == "tool_task" }
      puts "\n--- live named agent ------------------------------------------"
      puts "model:    #{MODEL}"
      puts "status:   #{row.fetch("status")}"
      puts "calls:    #{tools.map { |task| task["tool_name"] }.tally.map { |name, n| "#{name}x#{n}" }.join(" ")}"
      puts "spawn:    agent=#{agent.inspect} wait=#{waited.inspect}"
      puts "child:    #{child ? "#{child.public_id} answered by #{child.answering_user_public_id} (reviewer: #{answered_by_reviewer})" : "(none)"}"
      puts "review:   #{child_loop ? "#{child_loop} #{verdict.to_s.strip[0, 200].inspect}" : "(no turn)"}"
      puts "answer:   #{parent_answer.to_s.strip[0, 200].inspect}"
      puts "--------------------------------------------------------------"
    end
end
