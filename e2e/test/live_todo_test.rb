require "test_helper"
require "support/live_journey"
require "support/live_turns"
require "fileutils"
require "timeout"

# Ask a real model for a checklist while it performs a small coding task. A tracker call must write
# `conversation/todo.md` through the member plane, or clear it when every item is complete; the
# steward reads that same state and `rho watch` prints the checklist. Record whether the model chose
# the tool separately from whether the resulting flow worked.
#
# Paid, local, opt-in: E2E_LIVE=1. Cents on the floor.
class LiveTodoTest < Minitest::Test
  MODEL = ENV.fetch("E2E_LIVE_MODEL") { E2E::LiveJourney.default_model }.freeze
  DOCUMENT = "conversation/todo.md".freeze

  TASK = <<~TEXT.strip.freeze
    Write lib/wordcount.rb defining WordCount.count(text), the number of
    words in a string. Write test/wordcount_test.rb with minitest covering
    an empty string, one word, and several words split by spaces and
    newlines. Run the tests and fix whatever fails. This is several steps —
    keep a checklist of them as you go. Reply DONE when the tests pass.
  TEXT

  # The watch block and the clear, as `todo_test` pins them.
  CHECKLIST_LINE = /^  todo       - \[[ x>]\] /
  CLEARED_LINE = "  todo       (cleared)".freeze
  CLEARED_RECEIPT = "Todo list cleared.".freeze
  MARKER = /\A- \[[ x>]\] /
  TEST_FILE = "test/wordcount_test.rb".freeze
  TEST_COMMAND = ["ruby", "-Ilib", TEST_FILE].freeze
  TEST_SECONDS = 60

  include E2E::LiveJourney
  include E2E::LiveTurns

  # THE PROJECT IS OUTSIDE THE HOME (the `live_web_fetch` shape): the runner floor vetoes an
  # absolute `write` under `$RHO_HOME` whole, and this lane's flow is two files the model writes.
  def setup
    start_live_journey!(MODEL, home_prefix: "rho-live-todo-e2e")
    @project = Dir.mktmpdir("rho-live-todo-project")
  end

  def teardown
    finish_live_journey!
    FileUtils.remove_entry(@project) if @project && File.directory?(@project)
  end

  def test_a_real_model_keeps_the_conversations_checklist_through_a_multi_step_task
    connect_and_open_lane!
    project = @project
    @daemon.control(:post, "/environment", body: { root: project })

    conversation, _turn, loop_id = rho_do_turn(TASK, model: MODEL, dir: project)
    watched, status = rho_watch(loop_id, "--timeout", "600")
    assert_predicate status, :success?, watched
    done = await_loop_completion(loop_id)

    writes = done.fetch("tasks").select { |task| task["tool_name"] == "todo_write" }
    receipts = writes.map { |task| task_output(loop_id, task.fetch("key")) }
    document = read_document(conversation)
    checklist_lines = watched.lines.count { |line| line.match?(CHECKLIST_LINE) }
    cleared_lines = watched.lines.map(&:chomp).count(CLEARED_LINE)
    task_pass = tests_pass?(project)
    flow = flow_held?(document, receipts, checklist_lines, cleared_lines)
    report(done, writes, receipts, document, checklist_lines, cleared_lines, task_pass)
    # the one report line every paid lane prints; `reached` is the model's use of the tracker,
    # `succeeded` the flow.
    report_loop!(done, reached: !writes.empty?, succeeded: flow, task_pass: task_pass)

    assert_equal "completed", done.fetch("status"), summarize(done)
    flunk "the model kept no checklist (todo_write was never called): #{summarize(done)}" if writes.empty?
    assert(writes.all? { |task| task.fetch("status") == "completed" && task.dig("result", "is_error") != true },
      "a tracker write did not land: #{writes.inspect}")
    assert flow, "the flow: document=#{document.inspect} receipts=#{receipts.inspect} " \
                 "checklist lines on watch=#{checklist_lines} cleared lines=#{cleared_lines}"
  end

  private

    # THE FLOW PIN. The design's own two ends: a list stands as the
    # document (the door reads it, the watch printed it); a list the model
    # finished — every item completed — is a clear (the door answers
    # NotFound, the receipt says so, the watch printed `(cleared)`).
    def flow_held?(document, receipts, checklist_lines, cleared_lines)
      return false if receipts.empty?

      if receipts.last == CLEARED_RECEIPT
        document.nil? && cleared_lines >= 1
      else
        !document.nil? && document.match?(MARKER) && checklist_lines >= 1
      end
    end

    # The document through the STEWARD's door; nil once the kernel deleted it.
    def read_document(conversation)
      conversation_door(conversation).memory.read(DOCUMENT).content
    rescue CybrosAgent::Api::NotFound
      nil
    end

    # THE CODING OUTCOME, recorded (`task_pass`), never gated: the model's
    # own test file run once, bounded; nil when it wrote none.
    def tests_pass?(project)
      return nil unless File.file?(File.join(project, TEST_FILE))

      pid = Process.spawn(*TEST_COMMAND, chdir: project, out: File::NULL, err: File::NULL, pgroup: true)
      Timeout.timeout(TEST_SECONDS) { Process.wait(pid) }
      $?.success?
    rescue Timeout::Error
      Process.kill("KILL", -pid) rescue nil # rubocop:disable Style/RescueModifier
      Process.wait(pid) rescue nil # rubocop:disable Style/RescueModifier
      false
    end

    def report(row, writes, receipts, document, checklist_lines, cleared_lines, task_pass)
      tools = row.fetch("tasks").select { |task| task.fetch("kind") == "tool_task" }
      puts "\n--- live todo ------------------------------------------------"
      puts "model:     #{MODEL}"
      puts "status:    #{row.fetch("status")}"
      puts "rounds:    #{row.fetch("tasks").count { |task| task.fetch("kind") == "model_task" }}"
      puts "calls:     #{tools.map { |task| task["tool_name"] }.tally.map { |name, n| "#{name}x#{n}" }.join(" ")}"
      puts "writes:    #{writes.size}"
      receipts.each { |receipt| puts "           #{receipt}" }
      puts "document:  #{document.nil? ? "(absent)" : document.lines.map(&:chomp).join(" | ")}"
      puts "watch:     #{checklist_lines} checklist lines, #{cleared_lines} cleared lines"
      puts "tests:     #{task_pass.nil? ? "(no test file)" : (task_pass ? "pass" : "FAIL")}"
      puts "--------------------------------------------------------------"
    end
end
