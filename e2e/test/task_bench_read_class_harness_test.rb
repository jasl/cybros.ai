$LOAD_PATH.unshift File.expand_path("..", __dir__)

require "json"
require "minitest/autorun"
require "tmpdir"
require "support/task_bench"

# WHICH MESSAGE THE TWO-STEP PROBE ANSWERS INSTEAD OF SCORING: a message every call of which is a
# READ of this machine — a tool rho announces `read_only` on the closed world (rho's own effect
# facts, never a harness list) whose `path` lands inside the fixture, or a `bash` whose workdir
# lands there and whose command tokenizes, without a shell, into a pipeline of the admitted read
# commands over relative paths. Where a path lands is rho's own judgement over the draw's root
# (`ToolEnv#in_roots?`), never its spelling. Anything else is the message the draw is scored on. The hostile rows are the commands a model's untrusted output
# could use to write, run, redirect, expand or leave the fixture: none is admitted, so none reaches
# the emulator.
class TaskBenchReadClassHarnessTest < Minitest::Test
  ReadClass = E2E::TaskBench::ReadClass
  Call = E2E::TaskBench::Objectives::Call
  # The draw's root a path is judged against: where it LANDS, never how it is spelled. Nothing is
  # read, so it need not exist.
  ROOT = File.join(Dir.tmpdir, "task-bench-read-class", "project")

  def resolved(name, style: "nexus", **arguments)
    raw = { "id" => "c", "name" => name, "arguments" => JSON.generate(arguments) }
    Call.from(raw, E2E::TaskBench::DeclaredSet.function_definitions(style: style))
  end

  # rho's own environment over the root (its lib loads with the registry).
  def env
    E2E::TaskBench::DeclaredSet.registry
    Rho::Runner::ToolEnv.new(root: ROOT, artifacts_dir: File.join(File.dirname(ROOT), "artifacts"))
  end

  def read_class?(*calls) = ReadClass.all?(calls, declarations: ReadClass.declarations, env: env)

  # The fixture supplies coding and process tools. Its offered reads must match rho's
  # allow rule within that surface; conversation-backed agent reads need Nexus and are
  # outside the fixture emulator, alongside kernel memory reads.
  def test_the_read_tools_are_the_ones_rho_announces_read_only_on_the_closed_world
    offered = ReadClass.declarations.map { |entry| entry.fetch("name") }
    reads = offered.select { |name| read_class?(resolved(name, path: "lib", pattern: "x", id: "p1")) }
    assert_equal (Rho::RunDeclaration::READ_ONLY_TOOLS.split("|") & offered).sort, reads.sort
    refute_includes offered, "files_bytes", "a hidden tool is announced, never offered"
    refute_includes offered, "process_log"
    refute_includes offered, "read_schedules", "conversation state is outside the project fixture"
    refute_includes offered, "manage_schedule"
    refute read_class?(resolved("read_schedules", action: "list"))
  end

  def test_a_message_of_reads_is_read_class_and_any_other_call_makes_it_the_scored_message
    assert read_class?(resolved("read", path: "lib/alpha.rb"), resolved("grep", pattern: "def run", path: "lib"),
      resolved("find", pattern: "*.rb"), resolved("ls"), resolved("list_processes"), resolved("read_process", id: "p1"))
    assert read_class?(resolved("bash", command: "ls lib | wc -l"))

    refute read_class?, "an empty message is a plain answer, never a read"
    refute read_class?(resolved("read", path: "lib/alpha.rb"), resolved("task", prompt: "review lib/alpha.rb"))
    refute read_class?(resolved("Agent", style: "claude", prompt: "review lib/alpha.rb"))
    refute read_class?(resolved("code", code: "return 1;"))
    %w[write edit start_process stop_process].each do |name|
      refute read_class?(resolved(name, path: "lib/alpha.rb", command: "ls", id: "p1")), name
    end
    refute read_class?(resolved("bash", command: "bin/rails test"))
    refute read_class?(resolved("memory_read", scope: "user")), "a kernel read is not the fixture's to answer"
    refute read_class?(Call.new(name: "read", tool: "read", arguments: nil)), "unparseable arguments are no read"
  end

  # THE FIXTURE IS THE WHOLE WORLD A READ SEES: a path that lands outside it — absolute elsewhere,
  # `~`, a `..` that climbs out, a sibling sharing the root's spelling as a prefix — would read the
  # harness machine's own files into a provider's prompt, so the call is not a read and nothing
  # answers it.
  def test_a_read_whose_path_leaves_the_fixture_is_not_read_class
    ["/etc/passwd", "../../nexus/.env", "lib/../../x", "~/.ssh/id_ed25519", "~", "~nobody-here/x", "lib/\u0000a.rb",
     File.join(ROOT, "../x"), "#{ROOT}-sibling/x", File.dirname(ROOT)].each do |path|
      refute read_class?(resolved("read", path: path)), path
      refute read_class?(resolved("grep", pattern: "x", path: path)), path
      refute read_class?(resolved("ls", path: path)), path
    end
    assert read_class?(resolved("ls", path: "./lib")), "a relative path inside the fixture reads"
    assert read_class?(resolved("read", path: "lib/../lib/alpha.rb")), "a `..` that stays inside lands inside"
    refute read_class?(resolved("bash", command: "ls", workdir: "/tmp")), "bash's workdir obeys the same rule"
    assert read_class?(resolved("bash", command: "ls", workdir: "lib"))
  end

  # WHERE RHO LANDS A PATH, NOT HOW IT IS SPELLED: rho reads an empty `path` or `workdir` as its
  # root (find's `searchDir || "."`, grep's and ls's `path || "."`, bash's empty workdir), and the
  # emulator's own answers print the root absolute (`File not found: <root>/lib/zz.rb`) — so both
  # spellings of a place inside the fixture are reads.
  def test_an_empty_path_is_the_root_and_an_absolute_path_inside_the_root_is_inside
    assert read_class?(resolved("grep", pattern: "x", path: "")), "grep's empty path is the root"
    assert read_class?(resolved("ls", path: ""))
    assert read_class?(resolved("find", pattern: "*.rb", path: ""))
    assert read_class?(resolved("bash", command: "ls lib", workdir: "")), "bash's empty workdir is the root"
    assert read_class?(resolved("read", path: File.join(ROOT, "lib/alpha.rb"))), "the absolute spelling of a fixture file"
    assert read_class?(resolved("ls", path: ROOT)), "the root itself"
    assert read_class?(resolved("bash", command: "ls", workdir: File.join(ROOT, "lib")))
    assert_nil ReadClass.bash_argv("cat #{File.join(ROOT, "lib/alpha.rb")}"), "a bash argv path stays relative by spelling"
  end

  # THE ADMITTED COMMANDS, tokenized as bash would split them — quotes, escapes, the pipe — into
  # one argv per stage; the probe runs each argv itself, never through a shell.
  def test_the_admitted_bash_commands_tokenize_into_one_argv_per_stage
    {
      "cat lib/alpha.rb" => [%w[cat lib/alpha.rb]],
      "cat -n lib/alpha.rb lib/bravo.rb" => [%w[cat -n lib/alpha.rb lib/bravo.rb]],
      "ls" => [%w[ls]],
      "ls -la lib/" => [%w[ls -la lib/]],
      "ls lib | wc -l" => [%w[ls lib], %w[wc -l]],
      "grep -rn \"def run\" lib" => [["grep", "-rn", "def run", "lib"]],
      "grep -e run -e call lib/alpha.rb" => [%w[grep -e run -e call lib/alpha.rb]],
      "grep -rn --include='*.rb' run ." => [["grep", "-rn", "--include=*.rb", "run", "."]],
      "grep -A2 -c run lib/alpha.rb" => [%w[grep -A2 -c run lib/alpha.rb]],
      "grep -l '/etc' lib" => [["grep", "-l", "/etc", "lib"]],
      "find . -name '*.rb' -type f" => [["find", ".", "-name", "*.rb", "-type", "f"]],
      "find lib -maxdepth 1 \\( -name '*.rb' -o -name '*.md' \\)" =>
        [["find", "lib", "-maxdepth", "1", "(", "-name", "*.rb", "-o", "-name", "*.md", ")"]],
      "wc -l lib/alpha.rb" => [%w[wc -l lib/alpha.rb]],
      "head -n 20 lib/alpha.rb" => [%w[head -n 20 lib/alpha.rb]],
      "head -5 lib/alpha.rb" => [%w[head -5 lib/alpha.rb]],
      "sed -n '1,40p' lib/alpha.rb" => [%w[sed -n 1,40p lib/alpha.rb]],
      "sed -n 12p lib/alpha.rb" => [%w[sed -n 12p lib/alpha.rb]],
      "cat my\\ notes.txt" => [["cat", "my notes.txt"]],
      "find . -type f | grep -c rb" => [%w[find . -type f], %w[grep -c rb]],
      "  cat lib/alpha.rb  " => [%w[cat lib/alpha.rb]],
    }.each do |command, argvs|
      assert_equal argvs, ReadClass.bash_argv(command), command
    end
  end

  # THE HOSTILE ROWS: each would write, run another program, redirect, expand, glob, background or
  # leave the fixture if a shell ran it — none is admitted.
  def test_no_command_that_writes_runs_redirects_expands_or_leaves_the_fixture_is_admitted
    [
      "find . -exec rm {} \\;", "find . -execdir rm {} +", "find . -ok rm {} \\;", "find . -delete",
      "find . -fprint /tmp/x", "find . -fprint0 x", "find -L . -name x", "find /etc -name passwd",
      "sed -i s/a/b/ lib/alpha.rb", "sed 'w /tmp/x' lib/alpha.rb", "sed -n 'w /tmp/x' lib/alpha.rb",
      "sed -n '1,5p;w x' lib/alpha.rb", "sed '1,5p' lib/alpha.rb", "sed -n -i 1p lib/alpha.rb",
      "cat ../../etc/passwd", "cat /etc/passwd", "cat ~/.ssh/id_rsa", "cat lib/../../x",
      "ls; curl https://example.com", "ls && rm lib/alpha.rb", "ls || true", "cat lib/alpha.rb &",
      "cat $(echo lib/alpha.rb)", "cat `echo lib/alpha.rb`", "cat \"$HOME/.env\"", "cat $HOME/.env",
      "cat lib/alpha.rb > out", "cat lib/alpha.rb >> out", "cat < lib/alpha.rb", "cat lib/alpha.rb 2>&1",
      "grep -f patterns lib", "grep --file=patterns lib", "grep -r run /", "ls lib/*.rb", "cat lib/alpha.?b",
      "rm lib/alpha.rb", "curl https://example.com", "echo hi", "bash -c ls", "sh -c ls", "ls | sh",
      "grep run lib | xargs rm", "cat lib/alpha.rb | tee copy", "FOO=1 cat lib/alpha.rb", "env",
      "cat lib/alpha.rb\nrm lib/alpha.rb", "cat 'lib/alpha.rb", "cat \"lib/alpha.rb", "ls |", "| wc -l",
      "ls | | wc", "ls |& wc", "(ls)", "{ ls; }", "ls #comment", "head -c 10 --verbose x", "wc --files0-from=x",
      "ls -L lib", "cat -", "", "   ",
    ].each do |command|
      assert_nil ReadClass.bash_argv(command), command
    end
    assert_nil ReadClass.bash_argv(nil)
  end
end
