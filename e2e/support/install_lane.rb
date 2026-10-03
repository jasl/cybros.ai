require "cgi/escape"
require "fileutils"
require "json"
require "net/http"
require "securerandom"
require "tmpdir"
require_relative "actor_provisioning"
require_relative "ceremony"
require_relative "rho_daemon"
require_relative "steward_session"
require_relative "secret_hygiene"
require_relative "evals/docker"

module E2E
  # Shared setup for the installed container, Compose, and host journeys. Each pairs an installed
  # rho as a runner and proves a mock-model tool call reads a marker only that runner can see.
  # Docker images must be prebuilt; unavailable prerequisites produce an explicit skip. The
  # host-side agent has no tools of its own, so a successful read must cross the runner binding and
  # appear in that runner's claim log.
  #
  # A SKIP IS NEVER A PASS: a lane that cannot run says why — the gate on a docker-less host, or on
  # a host whose image was not pre-built, is NOT the gate for this group. The image is
  # `rho-install-test:rho` (`RHO_INSTALL_TEST_IMAGE` names another), what
  # `install/test/docker_test.sh` builds under RHO_INSTALL_TEST_DOCKER=1.
  module InstallLane
    IMAGE_ENV = "RHO_INSTALL_TEST_IMAGE".freeze
    DEFAULT_IMAGE = "rho-install-test:rho".freeze
    MODEL = "dev/mock-text".freeze
    EMPTY_PRELUDE = File.expand_path("empty_extensions_prelude.rb", __dir__)
    ANNOUNCED_AGENT_NOTHING = /event=executor\.announced tools=0 address=agent\b/
    TROUBLE = /runner_task_failed|runner_submit_refused/
    AWAIT_SECONDS = 120
    LOOP_POLL = 1
    BUILD_HINT = "the image is PRE-BUILT outside the gate: RHO_INSTALL_TEST_DOCKER=1 install/test/run.sh (or " \
                 "docker build -f install/docker/Dockerfile --target rho -t %s .); a SKIP here is never a pass".freeze

    class << self
      def image = ENV.fetch(IMAGE_ENV, DEFAULT_IMAGE)

      def docker_reason
        return "docker is not on PATH" unless command?("docker")
        return "docker is not running" unless system("docker", "info", out: File::NULL, err: File::NULL)

        nil
      end

      def compose_reason
        docker_reason || (system("docker", "compose", "version", out: File::NULL, err: File::NULL) ? nil : "docker compose is not available")
      end

      def image_reason(image = self.image)
        return nil if system("docker", "image", "inspect", image, out: File::NULL, err: File::NULL)

        "#{image} is not built — #{format(BUILD_HINT, image)}"
      end

      def command?(name) = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, name)) }
    end

    # The world, the steward's shared browser, two homes (the agent's on the
    # host, the runner's — bind-mounted into a container or an installed
    # rho's own) and a tests dir carrying the marker file.
    def install_lane_setup!(home_prefix:, container_image: nil)
      @container_image = container_image
      @base_url = E2E.base_url
      @world = E2E::ActorProvisioning.world(@base_url)
      @steward = @world.rho_steward
      @actor = E2E::StewardSession.actor(base_url: @base_url, human: @steward)
      @page = @actor.page
      @home = Dir.mktmpdir("#{home_prefix}-agent")
      @runner_home = Dir.mktmpdir("#{home_prefix}-runner")
      if container_image
        # Native Linux preserves the host uid on a bind mount. The image's
        # uid must own the private home; write permission alone cannot let
        # rho narrow its mode or satisfy StateFile's owner check.
        docker = E2E::Evals::Docker
        output, status = docker.run!(docker.one_shot_argv(tag: container_image, home: @runner_home,
          command: ["chown", "1000:1000", docker::HOME]))
        raise "could not prepare the installed runner's home:\n#{output}" unless status.success?
      end
      @tests = Dir.mktmpdir("#{home_prefix}-tests")
      File.chmod(0o755, @tests)
      @marker = "read-by-the-installed-runner-#{SecureRandom.hex(4)}"
      File.write(File.join(@tests, "note.txt"), "#{@marker}\n")
      File.chmod(0o644, File.join(@tests, "note.txt"))
      @actor.visit("/")
      assert @page.has_text?("Dashboard"), "the steward's session did not reach the dashboard"
      E2E.enable_dev_lane!
      E2E.hosts.start
    end

    # The stops come FIRST: a container's stdout reaches `daemon.log` only
    # when `Docker::Daemon#stop` saves it, so a dump before the stop would
    # show nothing of the one process that failed (the first world's lesson).
    def install_lane_teardown!
      stop_quietly("the installed runner") { @runner&.stop }
      stop_quietly("the agent-mode rho") { @daemon&.stop }
      unless passed? || skipped?
        warn_log(@daemon&.log_path, "agent rho stdout")
        warn_log(@daemon&.rho_log_path, "agent rho structured log")
        warn_log(@runner&.log_path, "installed runner stdout")
        warn_log(@runner&.rho_log_path, "installed runner structured log")
      end
    ensure
      # A doctor or setup failure may happen before a runner object exists.
      # Return the directory even then, so the host can remove its fixture.
      if @container_image && @runner_home && File.directory?(@runner_home)
        stop_quietly("the container home ownership") do
          docker = E2E::Evals::Docker
          output, status = docker.run!(docker.release_home_one_shot_argv(tag: @container_image, home: @runner_home))
          raise "could not release the installed runner's home:\n#{output}" unless status.success?
        end
      end
      [@home, @runner_home, @tests].each { |dir| remove_quietly(dir) }
    end

    # The AGENT half on the host: the empty prelude under `RHO_MODE=agent`
    # pairs branch A, adopts a workspace, announces `[]` and registers no
    # runner row — so the one tool call can only land on the installed runner.
    def boot_agent_rho!
      File.write(File.join(@home, "settings.json"), JSON.generate({ "extensions" => [], "extension_paths" => [] }))
      @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home, env: { "RUBYOPT" => "-r#{EMPTY_PRELUDE}", "RHO_MODE" => "agent" })
      @daemon.start
      started = @daemon.start_ceremony
      assert_equal "agent", started["branch"], "an agent-mode rho pairs branch A alone: #{started.inspect}"
      E2E::Ceremony.confirm(actor: @actor, started: started, status: -> { @daemon.status })
      adopted = await_workspace_state("adopted")
      @daemon.await("the agent address never announced its empty set") { @daemon.log_text.match?(ANNOUNCED_AGENT_NOTHING) ? true : nil }
      assert_nil adopted.dig("identity", "runner_executor_public_id"), "an agent-mode rho registers no runner row"
      adopted.dig("workspace", "public_id")
    end

    # The RUNNER half — the installed rho, wherever it runs: started,
    # paired on branch B (the machine page), its runner address announced,
    # its id off `status`. `daemon` is any `RhoDaemon`.
    def pair_runner!(daemon)
      @runner = daemon
      @runner.start
      started = @runner.start_ceremony
      assert_equal "runner", started["branch"], "an installed rho in runner mode pairs branch B alone: #{started.inspect}"
      E2E::Ceremony.confirm(actor: @actor, started: started, status: -> { @runner.status })
      @runner.await_announced(address: "runner")
      document = @runner.status
      runner_id = document.dig("identity", "runner_executor_public_id")
      refute_nil runner_id, "the runner's identity is its runner row: #{document.inspect}"
      assert_equal "runner", document["mode"]
      runner_id
    end

    # THE ONE TOOL CALL: the mock is told to `read` the marker's path; the
    # row is addressed to the installed runner, claimed in ITS log, and
    # answers the marker. The agent's log claims nothing.
    def read_through_runner!(workspace_public_id, runner_id, path)
      project = File.join(@home, "project")
      FileUtils.mkdir_p(project)
      output, status = @daemon.cli("run", "!mock tool_call=read tool_args=#{CGI.escape(JSON.generate({ "path" => path }))} -- say what you read",
        "--model", MODEL, "--dir", project, "--runner", runner_id)
      assert_predicate status, :success?, "rho run failed:\n#{output}"
      loop_id = output[/^loop:\s+(\S+)/, 1]
      refute_nil loop_id, output
      completed = await_loop_completion(workspace_public_id, loop_id)
      tool_task = completed.fetch("tasks").find { |task| task.fetch("kind") == "tool_task" }
      refute_nil tool_task, "the model never called a tool: #{summarize(completed)}"
      assert_equal %w[read completed], [tool_task.fetch("tool_name"), tool_task.fetch("status")], tool_task.inspect
      assert_equal runner_id, tool_task.dig("addressed_to", "executor_public_id"), "the row was addressed to the installed runner"
      answer = task_output(workspace_public_id, loop_id, tool_task.fetch("key"))
      assert_includes answer, @marker, "the installed runner's real `read` answered with the marker: #{answer.inspect}"
      assert_includes @runner.claimed_keys, tool_task.fetch("key"), "the runner's own log says it took the row: #{@runner.claims.inspect}"
      assert_empty @daemon.claimed_keys, "the agent-mode rho claimed a row it could not serve"
      refute_match TROUBLE, @runner.log_text, "the installed runner met a refusal or a failure"
      answer
    end

    # `docker run --rm IMAGE doctor --strict` through the image's one door:
    # green, the profile the image was built with, and the trust store
    # readable in the image (`test -r` past the door: the door hands every
    # argument to rho).
    def assert_doctor_green_in!(image)
      output, status = E2E::Evals::Docker.run!(["docker", "run", "--rm", image, "doctor", "--strict"])
      assert_predicate status, :success?, "rho doctor --strict inside #{image}:\n#{output}"
      assert_includes output, "0 failures", output
      assert_includes output, "profile full", "the image is the full profile: #{output.lines.first}"
      assert_tls_store_ok!(output) do |path|
        E2E::Evals::Docker.run!(["docker", "run", "--rm", "--entrypoint", "/bin/bash", image, "-c", 'test -r "$1"', "_", path]).last.success?
      end
      output
    end

    # The installed doctor must report a readable trust store containing roots accepted by OpenSSL,
    # and use the portable Ruby's own OpenSSL extension. Read the path from the doctor result so the
    # same assertion works on host and container installs. This verification stays offline.
    TLS_ROW = /^\s*ok\s+tls\s+(\S+) \((?:SSL_CERT_FILE|OpenSSL's compiled (?:path|dir)|SSL_CERT_DIR), \d+ roots?, the store trusts them\); openssl \S+ \(the Ruby's own\)/

    def assert_tls_store_ok!(doctor_output, &readable)
      match = doctor_output.match(TLS_ROW)
      refute_nil match, "rho doctor has no green tls row naming a trusted store and the Ruby's own openssl:\n#{doctor_output}"
      path = match[1]
      assert readable.call(path), "#{path} (the doctor's trust store) is not readable where the installed rho runs"
      path
    end

    # Count orphans before stopping the container: afterward its process namespace is gone and a
    # zero count proves nothing. A double-forked sleep whose group leader exits reparents to PID 1
    # and must be reaped. `init` names the expected PID 1 for this launcher: tini for the image,
    # Docker's init for Compose's `init: true`.
    def assert_no_orphans_before_stop!(container, init: "tini")
      probe = 'setsid bash -c "sleep 300 & exec sleep 0.2" >/dev/null 2>&1 & sleep 2; ps -eo pid,ppid,stat,comm'
      output, status = E2E::Evals::Docker.run!(E2E::Evals::Docker.exec_argv(container, "bash", "-c", probe))
      assert_predicate status, :success?, "the orphan probe:\n#{output}"
      zombies = output.lines.count { |line| line.match?(/ Z/) }
      assert_equal 0, zombies, "zombies under #{init} after a killed group leader:\n#{output}"
      assert_match(/^\s*\d+\s+1\s+\S+\s+sleep$/, output, "the orphan's sleep is live under PID 1:\n#{output}")
      assert_match(/^\s*1\s+0\s+\S+\s+#{Regexp.escape(init)}$/, output, "#{init} is PID 1:\n#{output}")
      output
    end

    private

      def await_loop_completion(workspace_public_id, loop_id)
        latest = nil
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + AWAIT_SECONDS
        loop do
          latest = agent_api("/agent_api/v1/workspaces/#{workspace_public_id}/agent_loops/#{loop_id}")
          found = latest["agent_loop"]
          return found if found && found["status"] == "completed"
          flunk "the loop never completed; last seen #{latest.inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          sleep LOOP_POLL
        end
      end

      def task_output(workspace_public_id, loop_id, key)
        agent_api("/agent_api/v1/workspaces/#{workspace_public_id}/agent_loops/#{loop_id}/tasks/#{key}").dig("task", "output").to_s
      end

      def summarize(row)
        row.fetch("tasks").map { |task| "#{task.fetch("key")}(#{task.fetch("kind")}/#{task.fetch("status")}#{task["tool_name"] ? ":#{task["tool_name"]}" : ""})" }.join(" ")
      end

      # The MEMBER plane, as the person who owns the work. UTF-8 by name:
      # the test process inherits the machine's empty locale.
      def agent_api(path)
        uri = URI.join(@base_url, path)
        request = Net::HTTP::Get.new(uri)
        request["Authorization"] = "Bearer #{@steward.member_token}"
        response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
        JSON.parse(response.body.force_encoding(Encoding::UTF_8))
      end

      def await_workspace_state(state)
        @daemon.await("the daemon never reported workspace #{state}") do
          document = @daemon.status
          workspace = document["workspace"]
          flunk "the daemon reported a workspace error: #{workspace["code"]}" if workspace&.fetch("state") == "error"

          workspace&.fetch("state") == state ? document : nil
        end
      end

      def stop_quietly(label)
        yield
      rescue StandardError => error
        warn "Could not stop #{label}: #{error.class}: #{error.message}"
      end

      def remove_quietly(dir)
        FileUtils.remove_entry(dir) if dir && File.directory?(dir)
      rescue StandardError => error
        warn "Could not remove #{dir}: #{error.class}: #{error.message}"
      end

      def warn_log(path, label)
        warn "#{label}:\n#{E2E::SecretHygiene.redact(File.read(path, encoding: Encoding::UTF_8))}" if path && File.file?(path)
      end
  end
end
