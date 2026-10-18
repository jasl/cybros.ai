module E2E
  # Shared fixture operations for the executor relay journey. The test owns
  # its three-process world and assertions; these helpers address that world.
  module ExecutorRelayHelpers
    MODEL = "dev/mock-text".freeze
    LOOP_POLL = 1
    AWAIT_SECONDS = 120

    private

      # ---- the conversation's environment ----

      # A directory under the runner-mode rho's own root, where a conversation
      # is bound; the root is spelled as rho spells it, so its subdirectory is.
      def bound_subdirectory
        File.join(runner_root, "sub-#{SecureRandom.hex(4)}").tap { |dir| FileUtils.mkdir_p(dir) }
      end

      # A relative `write`: where it lands is the conversation's root.
      def note(path, text) = [runner_tool("write"), { "path" => path, "content" => "#{text}\n" }]

      # Resolve the selected Runner's actual callable, then assert the frozen
      # route and claimant through the public Run projection.
      def runner_tool(name, runner: @runner_id)
        definitions = @daemon.control(:post, "/e2e/tool-assembly", body: {
          "default_runner_executor_public_id" => runner,
        }).fetch("tool_definitions")
        entry = definitions.find { |tool| tool.dig("route", "runner_executor_public_id") == runner &&
          tool.dig("route", "tool_name") == name }
        refute_nil entry, "Runner #{runner} does not expose #{name}"
        entry.fetch("function").fetch("name")
      end

      # `rho-dev do` naming the runner, binding `dir` when one is given;
      # answers the conversation, the loop and the whole output.
      def open_bound(prompt, dir:, runner:)
        arguments = ["do", prompt, "--model", MODEL, "--runner", runner]
        arguments += ["--dir", dir] if dir
        output, status = @daemon.cli(*arguments)
        assert_predicate status, :success?, "rho do failed:\n#{output}"
        ids = %w[conversation run].map { |line| output[/^#{line}:\s+(\S+)/, 1] }
        refute_includes ids, nil, "rho do printed no conversation or loop:\n#{output}"
        [*ids, output]
      end

      # `rho say` on a followed conversation, and the loop it opened.
      def say_loop(conversation, text)
        said, status = @daemon.cli("say", conversation, text)
        assert_predicate status, :success?, "rho say failed:\n#{said}"
        loop_id = said[/^run:\s+(\S+)/, 1]
        refute_nil loop_id, "rho say printed no loop:\n#{said}"
        loop_id
      end

      # A tool's answer on a loop, whole: the task read's output and its
      # text blocks.
      def tool_answer(row, tool)
        task = row.tasks.find { |candidate| candidate.tool_name == tool }
        refute_nil task, "the mock never called #{tool}: #{row.tasks.map(&:to_h).inspect}"
        detail = loops.run(row.public_id).task(task.key)
        [detail.output, *Array(detail.content).map { |block| block["text"] }].compact.join
      end

      # The structured-log lines of one event naming a conversation or a
      # runner among their fields — the event's own field names stay rho's.
      def environment_lines(daemon, event, naming:)
        daemon.log_lines.select { |line| line["event"] == event && line.values.include?(naming) }
      end

      # THE RUNNER-MODE RHO, BOOTED AGAIN on the same home: the credentials
      # stand and the runner row is the same; a stale announcement would
      # answer the readiness wait for a daemon that is gone, so it is
      # cleared; ready once its runner address announced once more (the log
      # is appended, so the count moves).
      def restart_runner_rho!
        announced = @runner_rho.log_text.scan(E2E::RhoDaemon::ANNOUNCED_RUNNER).length
        @runner_rho.stop
        FileUtils.rm_f(File.join(@world.runner_rho_home, "tmp", "announcement.json"))
        @runner_rho.start
        @runner_rho.await("the restarted runner-mode rho never announced its tools") do
          @runner_rho.log_text.scan(E2E::RhoDaemon::ANNOUNCED_RUNNER).length > announced ? true : nil
        end
        assert_equal @runner_id, @runner_rho.status.dig("identity", "runner_executor_public_id"),
          "the same runner row over the restart"
      end

      # The conversation's store, through the SDK as the steward.
      def store(conversation) = @steward_client.workspace(@workspace_public_id).conversation(conversation).store_entries

      # rho's record in a conversation's store, as the listing names it (no
      # value); nil until the host wrote it.
      def binding_summary(conversation, runner: @runner_id)
        store(conversation).list.items.find { |row| row.namespace == "rho.environment" && row.key == "binding/#{runner}" }
      end

      # `rho call_tool`, the shipped verb, against a runner's own id.
      def relay(runner_id, tool, input_json)
        @daemon.cli("call_tool", runner_id, tool, input_json)
      end

      # `rho do` on the agent-mode rho, naming the runner its tools run on;
      # answers the id of the loop backing the turn.
      def rho_do(prompt, runner:)
        output, status = @daemon.cli("do", prompt, "--model", MODEL, "--dir", project, "--runner", runner)
        assert_predicate status, :success?, "rho do failed:\n#{output}"
        loop_id = output[/^run:\s+(\S+)/, 1]
        refute_nil loop_id, output
        loop_id
      end

      # The fake's script (the `processes` journey's shape): one `!mock` line
      # naming the calls in order, each with its own url-encoded arguments.
      def script(*calls)
        encoded = calls.map { |name, arguments| "#{name}:#{CGI.escape(JSON.generate(arguments))}" }
        "!mock tool_call=#{encoded.join(",")} -- run what the script says"
      end

      # THE PROJECT LIVES BESIDE THE HOME, never under it (the conversation lane's rule): `--dir`
      # BINDS the conversation's root, and a root under `$RHO_HOME` is refused at the door and by
      # the Guard's floor. Once per world; realpath'd, as rho spells a root.
      def project
        @world.project ||= File.realpath(Dir.mktmpdir("rho-executor-relay-project"))
      end

      # The runner-mode rho's own root: where its relative paths resolve, read
      # off its environment door — the file a relay names lives THERE.
      def runner_root
        @runner_root ||= @runner_rho.control(:get, "/environment").dig("environment", "root").tap do |root|
          refute_nil root, "the runner-mode rho has no root: #{@runner_rho.control(:get, "/environment").inspect}"
          FileUtils.mkdir_p(root)
        end
      end

      def loops = @steward_client.workspace(@workspace_public_id).runs

      def await_run_status(loop_id, wanted)
        latest = nil
        await("the loop never reached #{wanted}; last seen #{latest.inspect}") do
          row = loops.fetch(loop_id)
          latest = row.status
          flunk "the loop #{loop_id} halted: #{row.failure_reason.inspect}" if latest == "failed" && wanted != "failed"
          latest == wanted ? row : nil
        end
      end

      def await(message)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + AWAIT_SECONDS
        loop do
          found = yield
          return found if found
          flunk message if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          sleep LOOP_POLL
        end
      end

      def warn_log(path, label)
        warn "#{label}:\n#{E2E::SecretHygiene.redact(File.read(path, encoding: Encoding::UTF_8))}" if path && File.file?(path)
      end
  end
end
