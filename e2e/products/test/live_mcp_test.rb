require "test_helper"
require "support/live_journey"
require "fileutils"
require "json"
require "securerandom"
require "tmpdir"

# A REAL MODEL REACHES A THIRD PARTY'S TOOL, announced by rho-mcp under its prefix beside rho's own
# reads, and proves it by what it copied — not by what it says.
#
# The server is the reference filesystem server deepseek itself tests
# against, at deepseek's own floor (`@modelcontextprotocol/server-filesystem
# @2026.7.4`), spawned by the daemon as a stdio child in its own scrubbed
# process group; the allowlist names two of its fourteen tools, so the
# model reads `mcp__fs__read_file` and `mcp__fs__list_directory` — the
# server's own descriptions, byte for byte — beside `read`, `write` and
# the rest of the coding seven.
#
# THE TASK NAMES THE FILE AND THE GOAL, NEVER THE TOOL (the browser lane's
# form): "use mcp__fs__read_file" would turn REACH into
# instruction-following. A model that reads NOTES.txt through rho's own
# `read` has answered the task and NOT reached the tool — that is the
# finding, this lane is red for it, and red is what it exists to measure:
# a floor model's reach for a third-party-described, prefixed tool when a
# native one would do. Nothing else in the tree asks that question; the
# mock journey (`mcp_tools`) proves the plumbing and never a model.
#
# WHAT THIS PROVES that the unit suites and the mock journey cannot: the extension loads under the
# daemon from settings.json against a REAL public server, `npx` resolves inside the REPLACED child
# environment, the two verbatim declarations reach a real provider beside the coding seven, and a
# flash-tier model can choose them at all.
#
# Paid, local, opt-in: E2E_LIVE=1, plus Node — the journey pins the server with npx so the machine's
# global install can drift, as the browser lane pins its Playwright driver. ONE loop of 2–4 rounds
# on the floor, ≈ $0.02–0.10; the cost stop rides `E2E_LIVE_COST_STOP_USD`
# (`LiveJourney::COST_STOP_ENV`, else the bench's default row), polled under
# `await_loop_completion`. Run once before the sweep; the sweep glob carries it after (`rake
# live_sweep`).
class LiveMcpTest < Minitest::Test
  MODEL = ENV.fetch("E2E_LIVE_MODEL") { E2E::LiveJourney.default_model }.freeze
  # THE SERVER, PINNED: deepseek's floor (`mcp-client/package.json`
  # `^2026.7.4`); at this version the listing carries both allowlisted
  # names (`read_file` is listed DEPRECATED in favour of `read_text_file`
  # — the server's own words, announced verbatim, and part of what the
  # lane measures).
  SERVER = ENV.fetch("E2E_MCP_FILESYSTEM", "@modelcontextprotocol/server-filesystem@2026.7.4").freeze
  # The two tools the operator named; nothing else of the fourteen is
  # announced (curation is explicit).
  ALLOWLIST = %w[read_file list_directory].freeze
  # A cold `npx -y` fetch is the slow legitimate case (the browser Driver's 60 s timeout): the row
  # names its own bound above the 30 s default so a first run on a fresh machine is not `down` for a
  # network reason.
  STARTUP_TIMEOUT_MS = 90_000

  include E2E::LiveJourney

  def setup
    start_live_journey!(MODEL, home_prefix: "rho-live-mcp-e2e")
    # THE PROJECT IS OUTSIDE THE HOME. rho's incubation denies bind on every
    # `mcp__` text argument that names a protected root — the home among
    # them — so a project under RHO_HOME would have the fs server's `path`
    # refused by rho's own rule, and the lane would measure the rule, not
    # the reach. (The browser lane's home-nested project survives only by
    # the tmpdir's symlink spelling on macOS; this lane does not lean on it.)
    @project = Dir.mktmpdir("rho-live-mcp-project")
    # THE EXTENSION IS WANTED, NOT MERELY INSTALLED, and the server is the
    # operator's row: stdio (the runner address by default), the filesystem
    # server rooted at the project, the allowlist, the startup bound.
    File.write(File.join(@home, "settings.json"), JSON.generate(E2E::RhoDaemon.dev_settings(plugins: {
      "rho.mcp" => { "enabled" => true, "configuration" => { "servers" => {
        "fs" => {
          "transport" => "stdio",
          "command" => "npx",
          "args" => ["-y", SERVER, @project],
          "tools" => ALLOWLIST,
          "startup_timeout_ms" => STARTUP_TIMEOUT_MS,
        },
      } } },
    })), perm: 0o600)
  end

  def teardown
    finish_live_journey!
    FileUtils.remove_entry(@project) if @project && File.directory?(@project)
  end

  def test_a_real_model_reads_a_file_through_a_public_mcp_server
    connect_and_open_lane!

    # THE DAEMON SAYS WHAT IT LOADED, before a model is asked anything — a
    # failed extension, or a server down at boot, is a product fact and
    # reads here: `rho runner` lists the extension with its announced names,
    # `rho mcp` the server connected in its own group with the two tools
    # and nothing of the other twelve.
    listed, status = @daemon.cli("runner")
    assert_predicate status, :success?, "rho runner failed:\n#{listed}"
    assert_match(/extension:\s+rho\.mcp\b/, listed, "the mcp extension did not load:\n#{listed}")
    refute_match(/FAILED:/, listed, "an extension failed to load:\n#{listed}")

    servers, status = @daemon.cli("mcp")
    assert_predicate status, :success?, "rho mcp failed:\n#{servers}"
    assert_match(/^server:\s+fs\s+stdio\b.*\bconnected \(pid \d+, pgid \d+\)/, servers,
      "the filesystem server is not connected:\n#{servers}")
    # Two of the server's list (fourteen at the pinned version; the count
    # is the server's, so a re-pinned `E2E_MCP_FILESYSTEM` keeps the pin).
    assert_match(/^\s+tools:\s+2 announced of \d+ listed/, servers, "the allowlist did not curate:\n#{servers}")
    ALLOWLIST.each do |raw|
      assert_match(/^\s+mcp__fs__#{raw}\s+[\d,]+ bytes/, servers, "#{raw} is not announced:\n#{servers}")
    end
    refute_match(/mcp__fs__write_file/, servers, "an un-allowlisted tool was announced:\n#{servers}")

    # THE FILE THE MODEL MUST READ: three lines it cannot guess, so a
    # matching answer.txt is a read and never a paraphrase.
    notes = <<~TEXT
      release token: #{SecureRandom.hex(8)}
      owner: #{SecureRandom.alphanumeric(10)}
      the third line is #{SecureRandom.random_number(100_000)}
    TEXT
    File.write(File.join(@project, "NOTES.txt"), notes)
    @daemon.control(:post, "/environment", body: { root: @project })

    task = <<~TEXT.strip
      Tell me the exact contents of NOTES.txt in the project, write them to
      answer.txt, and reply DONE.
    TEXT

    output, status = @daemon.cli("do", task, "--model", MODEL, "--dir", @project)
    assert_predicate status, :success?, "rho do failed:\n#{output}"
    run_public_id = output[/^run:\s+(\S+)/, 1]
    # That the two MCP tools were offered is proved by the completed prefixed call below: the 201
    # names no tools (the declaration is the profile's).

    completed = await_loop_completion(run_public_id)
    reached = completed_non_error_calls(completed, "mcp__fs__read_file")
    answer_path = File.join(@project, "answer.txt")
    answer = File.read(answer_path, encoding: Encoding::UTF_8) if File.file?(answer_path)
    report(completed)
    # the one report line every paid lane prints (`LiveJourney#report_loop!`, through the evals
    # scorer's reader: spend, the sealed request's bytes). `reached` is the lane's one question —
    # the prefixed read completed.
    report_loop!(completed, reached: !reached.empty?, succeeded: completed.fetch("status") == "completed",
      task_pass: !answer.nil? && answer.chomp == notes.chomp)

    assert_equal "completed", completed.fetch("status"),
      "the loop did not finish: #{summarize(completed)}"

    # IT REACHED. A model that read the file through rho's own `read`
    # answered the task and never touched the server; a call the server
    # refused (a path outside its root, say) answers an ERROR RESULT —
    # which the runner submits and the kernel settles as `completed`, with
    # `is_error` in its summary — so status alone would let a refused MCP
    # read followed by a native one pass. The call that counts completed
    # AND was not an error.
    refute_empty reached,
      "it never read through the MCP server (rho's own read, or a refused call): #{summarize(completed)}"

    # THE PROOF IS ON DISK, and it is the file's own bytes. The one
    # difference tolerated is the trailing newline a `write` appends or
    # drops: the three lines are the reach's evidence, the newline the
    # write tool's habit.
    assert_path_exists answer_path, "it never wrote answer.txt"
    assert_equal notes.chomp, answer.chomp, "answer.txt is not the contents of NOTES.txt"
  end

  private

    def completed_non_error_calls(row, tool_name)
      row.fetch("tasks").select do |t|
        t.fetch("kind") == "tool_task" && t.fetch("tool_name") == tool_name &&
          t.fetch("status") == "completed" && t.dig("result", "is_error") != true
      end
    end

    def report(row)
      tools = row.fetch("tasks").select { |t| t.fetch("kind") == "tool_task" }
      puts "\n--- live mcp -------------------------------------------------"
      puts "model:  #{MODEL}"
      puts "server: #{SERVER}"
      puts "status: #{row.fetch("status")}"
      puts "rounds: #{row.fetch("tasks").count { |t| t.fetch("kind") == "model_task" }}"
      puts "calls:  #{tools.size} (#{tools.map { |t| t["tool_name"] }.tally.map { |n, c| "#{n}x#{c}" }.join(" ")})"
      puts "--------------------------------------------------------------"
    end
end
