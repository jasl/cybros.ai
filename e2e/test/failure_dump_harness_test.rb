require "test_helper"
require "support/failure_dump"
require "support/nexus_server"
require "support/secret_hygiene"
require "tmpdir"

# A RED WORLD'S DUMP, FORCED: the dump a world writes when it goes red carries the world's logs
# WHOLE (never a 400-line tail, never a window — each world process's Rails log is its own file
# under the run root), redacted, and `sealed_requests.json` — the sealed request of the failed turn
# with the loop and task key that sealed it and the host's event items. Driven over a tmpdir with
# documents of the test's own (the world's read is `NexusServer::SEALED_REQUESTS`, a `bin/rails
# runner` script that needs the world's database) — once through `FailureDump.write` and once
# through `NexusServer#failure_dump!`, the world's own composition, on a server that never booted.
class FailureDumpHarnessTest < Minitest::Test
  SEALED = {
    "invocation" => "inv-1", "model" => "dev/mock-text", "status" => "failed", "loop" => "loop-7", "task_key" => "r2",
    "host" => "Conversation conv-3",
    "request" => { "entries" => [{ "role" => "user", "parts" => [{ "type" => "text", "text" => "port the codec" }] }],
                   "request_options" => { "tools" => [{ "type" => "function", "function" => { "name" => "bash" } }] } },
    "events" => [{ "type" => "turn_status", "payload" => { "status" => "failed" } }],
  }.freeze

  def test_the_dump_keeps_the_logs_whole_and_the_sealed_request_of_the_failed_turn
    Dir.mktmpdir("failure-dump") do |root|
      secret = E2E::SecretHygiene.register("dump-secret-#{SecureRandom.hex(6)}")
      server_log = File.join(root, "world", "server.log")
      FileUtils.mkdir_p(File.dirname(server_log))
      File.write(server_log, (1..600).map { |n| "line #{n} bearer #{secret}\n" }.join)
      rails_log = File.join(root, "world", "rails.log")
      File.write(rails_log, "before the turn\nthe world's own line sk-cybros-api-v1-abcdef\n")

      into = File.join(root, "dump")
      written = E2E::FailureDump.write(into: into, sources: { "server.log" => server_log, "rails.log" => rails_log },
        sealed: [SEALED], redact: ->(text) { E2E::SecretHygiene.redact(text).gsub(E2E::NexusServer::SECRET_PATTERN, '\1-[REDACTED]') })

      copied = File.read(File.join(into, "server.log"), encoding: Encoding::UTF_8)
      assert_equal 600, copied.lines.size, "the log is copied whole, never a tail"
      refute_includes copied, secret, "redacted"
      assert_includes copied, "line 1 bearer"
      assert_equal "before the turn\nthe world's own line [REDACTED]\n", File.read(File.join(into, "rails.log"), encoding: Encoding::UTF_8),
        "the world's Rails log whole from its first line, redacted"
      sealed = JSON.parse(File.read(File.join(into, E2E::FailureDump::SEALED_FILE), encoding: Encoding::UTF_8))
      assert_equal [SEALED], sealed, "the sealed request of the failed turn, with its loop, key, host and events"
      manifest = File.read(File.join(into, "MANIFEST"), encoding: Encoding::UTF_8)
      assert_includes manifest, "server.log: "
      assert_includes manifest, "rails.log: "
      refute_match(/window|development\.log/, manifest, "no window of a shared file is taken any more")
      assert_equal %w[MANIFEST rails.log sealed_requests.json server.log], Dir.children(into).sort
      assert_equal written.sort, [File.join(into, "server.log"), File.join(into, "rails.log"), File.join(into, "sealed_requests.json")].sort
    end
  end

  # The world's own composition: every `*.log` under its run root — the
  # boot and host logs and the three per-process Rails logs the world's
  # env names (`RAILS_LOG_FILE`; `NexusHosts#host_env`) — and the
  # documents handed in. No `nexus.development.log` window: the shared
  # checkout file is not the world's any more.
  def test_the_servers_composition_dumps_its_run_root_logs_and_the_documents_it_read
    server = E2E::NexusServer.new(nexus_root: E2E::NEXUS_ROOT)
    Dir.mktmpdir("failure-dump-world") do |root|
      File.write(server.send(:run_path, "rails_db_prepare.log"), "prepared\n")
      File.write(server.send(:run_path, "server.log"), "booted\n")
      File.write(server.send(:env).fetch("RAILS_LOG_FILE"), "web rails\n")
      hosts = E2E::NexusHosts.new(nexus_root: E2E::NEXUS_ROOT, env: server.send(:env), log_dir: server.send(:run_path))
      File.write(hosts.rails_log_path(:jobs), "jobs rails\n")
      File.write(hosts.rails_log_path(:runner), "runner rails\n")
      into = File.join(root, "dump")

      server.send(:failure_dump!, into, sealed: [SEALED])

      assert_equal "booted\n", File.read(File.join(into, "server.log"), encoding: Encoding::UTF_8)
      assert_equal "prepared\n", File.read(File.join(into, "rails_db_prepare.log"), encoding: Encoding::UTF_8)
      assert_equal "web rails\n", File.read(File.join(into, "rails.log"), encoding: Encoding::UTF_8)
      assert_equal "jobs rails\n", File.read(File.join(into, "jobs.rails.log"), encoding: Encoding::UTF_8)
      assert_equal "runner rails\n", File.read(File.join(into, "model_runner.rails.log"), encoding: Encoding::UTF_8)
      assert_equal "r2", JSON.parse(File.read(File.join(into, "sealed_requests.json"), encoding: Encoding::UTF_8)).first.fetch("task_key")
      assert_equal %w[MANIFEST jobs.rails.log model_runner.rails.log rails.log rails_db_prepare.log sealed_requests.json server.log],
        Dir.children(into).sort, "the run root's logs and the documents, nothing windowed from the checkout"
      refute_match(/window|development\.log/, File.read(File.join(into, "MANIFEST"), encoding: Encoding::UTF_8))
    end
  ensure
    server&.stop
  end

  def test_a_world_that_read_no_documents_still_writes_the_file
    Dir.mktmpdir("failure-dump-empty") do |root|
      into = File.join(root, "dump")
      E2E::FailureDump.write(into: into, sources: {}, sealed: [])
      assert_equal "[]\n", File.read(File.join(into, "sealed_requests.json"), encoding: Encoding::UTF_8)
    end
  end
end
