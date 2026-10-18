$LOAD_PATH.unshift File.expand_path("..", __dir__)

require "json"
require "minitest/autorun"
require "support/task_bench"

# THE READS ARE ANSWERED FROM THE FIXTURE, BY RHO'S OWN TOOLS: the fixture's bytes written into a
# directory the draw owns, `read`/`grep`/`find`/`ls` answered by rho-runner's own handlers over
# it (schema refusals included, as the runner answers them), the process tools by rho's own
# handlers over an empty table, and an admitted `bash` run as argv — no shell — inside the copy
# under a wall clock and an output cap, its answer held equal to rho's own `bash` on the same
# commands. A model's U+0000 where no path check reads it is answered as rho and its runner answer
# it, never raised as the harness's fault. A call that is not read-class is never answered, and the
# copy is gone when the draw's block returns.
class TaskBenchEmulatorHarnessTest < Minitest::Test
  Emulator = E2E::TaskBench::Emulator
  Call = E2E::TaskBench::Objectives::Call

  FIXTURE = {
    "lib/alpha.rb" => "class Alpha\n  def run\n    :alpha\n  end\nend\n",
    "lib/bravo.rb" => "class Bravo\n  def call\n    :bravo\n  end\nend\n",
    "README.md" => "# Fixture\n",
  }.freeze

  def resolved(name, **arguments)
    raw = { "id" => "c", "name" => name, "arguments" => JSON.generate(arguments) }
    Call.from(raw, E2E::TaskBench::DeclaredSet.function_definitions)
  end

  # rho-runner's own `bash` over `root`, from the registry the declared set is built from; its
  # captures land beside the root, never in it.
  def rho_bash(root, timeout_seconds:)
    env = Rho::Runner::ToolEnv.new(root: root, artifacts_dir: File.join(File.dirname(root), "rho-artifacts"),
      bash_timeout_seconds: timeout_seconds)
    E2E::TaskBench::DeclaredSet.registry.toolset(env: env).fetch(Rho::Runner::Tools::Bash::NAME)
  end

  def test_rhos_read_tools_answer_from_the_fixture_bytes
    Emulator.open(fixture: FIXTURE) do |emulator|
      read = emulator.answer(resolved("read", path: "lib/alpha.rb"))
      refute read.is_error
      assert_includes read.content, "def run"

      assert_includes emulator.answer(resolved("grep", pattern: "def (run|call)", path: "lib")).content, "bravo.rb:2:   def call"
      assert_includes emulator.answer(resolved("find", pattern: "*.rb")).content, "lib/alpha.rb"
      assert_includes emulator.answer(resolved("ls")).content, "README.md"

      missing = emulator.answer(resolved("read", path: "lib/charlie.rb"))
      assert missing.is_error, "a read of a file the fixture lacks is the tool's own error, as data"
      assert_includes missing.content, "File not found"

      refused = emulator.answer(resolved("read", offset: 2))
      assert refused.is_error
      assert_equal "invalid_tool_arguments: object at root is missing required properties: path", refused.content,
        "the runner's own schema refusal, before the handler"
    end
  end

  # NOTHING WAS STARTED: the process tools answer rho's own empty-table sentences.
  def test_the_process_tools_answer_the_empty_listing
    Emulator.open(fixture: FIXTURE) do |emulator|
      assert_equal "(no processes)", emulator.answer(resolved("list_processes")).content
      nothing = emulator.answer(resolved("read_process", id: "p1"))
      assert nothing.is_error
      assert_equal "no process p1; nothing has been started", nothing.content
    end
  end

  def test_an_admitted_bash_runs_as_argv_inside_the_copy
    Emulator.open(fixture: FIXTURE) do |emulator|
      counted = emulator.answer(resolved("bash", command: "ls lib | wc -l"))
      refute counted.is_error, counted.content
      assert_equal "2", counted.content.strip

      grepped = emulator.answer(resolved("bash", command: "grep -rn 'def run' lib"))
      assert_includes grepped.content, "lib/alpha.rb:2:"

      assert_includes emulator.answer(resolved("bash", command: "sed -n '2,3p' lib/bravo.rb")).content, "def call"
      assert_includes emulator.answer(resolved("bash", command: "cat alpha.rb", workdir: "lib")).content, "class Alpha",
        "a workdir inside the fixture is the command's directory"

      empty = emulator.answer(resolved("bash", command: "grep -rn nothing-here lib"))
      assert empty.is_error, "grep's exit 1 is the command's own failure, as data"
      assert_equal "(no output)\n\nCommand exited with code 1", empty.content

      missing = emulator.answer(resolved("bash", command: "cat lib/charlie.rb"))
      assert missing.is_error
      assert_includes missing.content, "lib/charlie.rb", "stderr is the command's output too"
    end
  end

  # THE EMULATOR'S BASH ANSWERS AS RHO'S OWN: the same harness-authored commands, run by
  # rho-runner's `bash` (through a shell, as the runner runs one) and by the emulator (as argv) in
  # the same copy, answer the same text and the same `is_error` — silence under either exit, a
  # failing exit with its output, an output's trailing newline, a missing and an empty workdir, the
  # clock. A change to rho's wording fails here, never silently in a draw.
  def test_the_emulators_bash_answers_as_rhos_own_bash
    Emulator.open(fixture: FIXTURE, timeout_seconds: 0.5) do |emulator|
      File.mkfifo(File.join(emulator.root, "pipe"))
      rho = rho_bash(emulator.root, timeout_seconds: 0.5)
      [
        { command: "find lib -name '*.py'" }, { command: "grep -rn nothing-here lib" },
        { command: "cat lib/charlie.rb" }, { command: "ls lib" }, { command: "cat alpha.rb", workdir: "lib" },
        { command: "ls", workdir: "nope" }, { command: "cat README.md", workdir: "" }, { command: "cat pipe" },
        { command: "grep a\u0000b lib/alpha.rb" },
      ].each do |arguments|
        ours = emulator.answer(resolved("bash", **arguments))
        theirs = rho.handler.call(arguments.transform_keys(&:to_s), nil)
        assert_equal [theirs.content, theirs.is_error], [ours.content, ours.is_error], arguments.inspect
      end
    end
  end

  # WHERE RHO LANDS A PATH: an empty `path` or `workdir` is the root, and the absolute spelling of
  # a fixture file — the one the emulator's own answers print — reads it.
  def test_an_empty_path_and_the_absolute_spelling_inside_the_root_are_answered
    Emulator.open(fixture: FIXTURE) do |emulator|
      assert_includes emulator.answer(resolved("ls", path: "")).content, "lib/"
      assert_includes emulator.answer(resolved("grep", pattern: "def run", path: "")).content, "alpha.rb:2:"
      assert_includes emulator.answer(resolved("read", path: File.join(emulator.root, "lib/alpha.rb"))).content, "def run"
      assert_equal "alpha.rb\nbravo.rb", emulator.answer(resolved("bash", command: "ls lib", workdir: "")).content
      assert emulator.read_class?([resolved("read", path: File.join(emulator.root, "lib/alpha.rb")), resolved("ls", path: "")])
      refute emulator.read_class?([resolved("read", path: File.join(File.dirname(emulator.root), "x"))])
    end
  end

  # A MODEL'S U+0000 in an argument no path check reads — a bash stage's pattern, a later stage's, a
  # rho tool's pattern or glob — reaches a spawn that cannot take it: the emulator's bash answers as
  # rho's `bash` answers a shell that cannot start, rho's own handlers as the runner answers a
  # handler that raised; each a failure the model reads.
  def test_a_nul_the_model_wrote_is_answered_as_rho_answers_it
    Emulator.open(fixture: FIXTURE) do |emulator|
      ["grep a\u0000b lib/alpha.rb", "cat lib/alpha.rb | grep 'a\u0000'"].each do |command|
        call = resolved("bash", command: command)
        assert emulator.read_class?([call]), command.inspect
        answered = emulator.answer(call)
        assert_equal [true, "Failed to start bash: string contains null byte"], [answered.is_error, answered.content], command.inspect
      end
      [resolved("grep", pattern: "a\u0000b"), resolved("find", pattern: "*\u0000.rb"), resolved("grep", pattern: "a", glob: "*\u0000")].each do |call|
        answered = emulator.answer(call)
        assert_equal [true, "The tool could not run: ArgumentError: string contains null byte"], [answered.is_error, answered.content],
          call.inspect
      end
    end
  end

  # A bash call the runner's schema refuses is refused as the runner refuses it, before any argv.
  def test_a_bash_call_the_schema_refuses_is_answered_with_the_runners_refusal
    Emulator.open(fixture: FIXTURE) do |emulator|
      refused = emulator.answer(resolved("bash", command: "ls", timeout: 0))
      assert refused.is_error
      assert refused.content.start_with?("invalid_tool_arguments: "), refused.content
    end
  end

  # THE WALL CLOCK AND THE CAP ARE THE EMULATOR'S: a command that never ends is killed with its
  # group and answered as timed out; an output past the cap is cut at it and says so.
  def test_a_command_is_bounded_by_the_wall_clock_and_the_output_cap
    Emulator.open(fixture: FIXTURE.merge("big.txt" => "#{"a" * 99}\n" * 1_000), timeout_seconds: 0.5) do |emulator|
      File.mkfifo(File.join(emulator.root, "pipe"))
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      stuck = emulator.answer(resolved("bash", command: "cat pipe"))
      assert stuck.is_error
      assert_equal "Command timed out after 0.5 seconds", stuck.content
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5

      big = emulator.answer(resolved("bash", command: "cat big.txt"))
      refute big.is_error
      kept, note = big.content.split("\n\n")
      assert_equal Emulator::OUTPUT_CAP_BYTES, kept.bytesize, "cut at the cap"
      assert_equal "[output cut at 64 KiB]", note
    end
  end

  # ONLY A READ IS ANSWERED: a call the probe would have scored reaching the emulator is the
  # harness's own fault, loud — never an answer a model reads.
  def test_a_call_that_is_not_read_class_is_never_answered
    Emulator.open(fixture: FIXTURE) do |emulator|
      [resolved("write", path: "lib/alpha.rb", content: "x"), resolved("bash", command: "rm lib/alpha.rb"),
       resolved("read", path: "/etc/passwd"), resolved("task", prompt: "review lib/alpha.rb")].each do |call|
        assert_raises(ArgumentError, call.inspect) { emulator.answer(call) }
      end
      assert File.file?(File.join(emulator.root, "lib/alpha.rb"))
    end
  end

  def test_the_copy_lives_for_the_block_and_an_empty_fixture_is_an_empty_project
    root = Emulator.open(fixture: {}) do |emulator|
      assert File.directory?(emulator.root)
      assert emulator.answer(resolved("ls")).content.start_with?("(empty directory")
      emulator.root
    end
    refute File.exist?(root), "the draw's copy is removed with its block"
  end
end
