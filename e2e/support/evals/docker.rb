require "json"
require "open3"
require "securerandom"
require "socket"
require "timeout"
require "uri"
require_relative "../rho_daemon"
require_relative "../secret_hygiene"
require_relative "docker_bases"

module E2E
  module Evals
    # THE DOCKER HOOKS FOR THE CONTAINER FAMILIES: a task's own image (the Agents-on-Rails app
    # images `ghcr.io/evilmartians/lemans-{writebook,fizzy}`, TAGGED — `:latest` does not exist on
    # ghcr; terminal-bench's `alexgshaw/<name>:20251031` on Docker Hub) with rho in RUNNER MODE
    # inside — a derived image (`e2e/evals/docker/Dockerfile`: `ARG BASE`, FROM the task's base
    # pinned to linux/amd64 (every base is single-arch), then THE SAME install.sh the host runs,
    # profile runner, into /opt/rho), the container started as `RHO_MODE=runner rho server` with its
    # RHO_HOME bind-mounted to a host dir — so `E2E::RhoDaemon`'s `control` works through `Daemon`,
    # a subclass that reads the announcement and the structured log THROUGH the container, rewrites
    # the announced endpoint's host to loopback and runs `cli` through `docker exec`; pairing =
    # `start_runner_rho!(daemon: …)` over it; the agent side is the host's full-mode rho with `rho
    # do --runner <runner_id>` (`live_rho_runner`'s shape) and Nexus reached from the container at
    # `host.docker.internal:<port>` (a bridge; Docker Desktop) or on the host's own loopback
    # (`--network host`; Linux, where the harness Nexus binds 127.0.0.1 and no bridge reaches it).
    #
    # ONE DEGREE OF GENERALITY (3.7 (2)): the base is a parameter (`build_argv(base:)`; the rails
    # family's map is `base_for(profile)`) and so is the app tree's OWNER (`app_owner:`, the
    # recipe's second build arg — `app_owner_for(container_user:)` derives it from the task: the
    # image's uid 1000 when the container runs as it, the base's own owner when it runs as root; the
    # tag names the owner when it is not the default, so one base never shares a tag across two
    # recipes), the run takes an optional `/tests:ro` mount (the rails family's patch and hidden
    # test), an optional host dir at `/logs/verifier` (harbor's convention: the reward lands on the
    # host), an optional user (terminal- bench runs as root, harbor's parity) and the network; TWO
    # verifier shapes — the rails family's three execs whose last exit status is the verdict
    # (`verify!`), and `verify_reward!`: the tests copied in AFTER the turn, `bash /tests/test.sh`
    # as root in the image's WorkingDir, then `/logs/verifier/reward.txt` read off the host, pass =
    # a Float ≥ 1. A PRE-FLIGHT before the build (`preflight_argv`: the base has apt-get — the
    # derived image installs build-essential itself from the manifest's row) and the base's
    # WorkingDir read off the image (`workdir_argv`) are the lane's first two steps; a base that
    # fails either is a `build_failed` record, never a silent skip. A THIRD pre-flight stands after
    # the run's container does and before the model is asked (`Daemon# preflight_git_tree!`): a
    # WorkingDir holding a `.git` must answer `git rev-parse --git-dir` AS THE CONTAINER'S USER,
    # else the run is a lane error (`TreeRefused`) — git's "dubious ownership" of a tree another uid
    # owns can never again be scored as the model's conduct.
    #
    # EVERY HOOK IS AN ARGV, spawned through one injectable runner (`Docker.run!` by default; the
    # unit test records instead). What the RUN half proves first, in order: the image builds, the
    # container pairs, one task.
    module Docker
      # The rails family's bases (`DockerBases`); every base — theirs and
      # terminal-bench's — is linux/amd64 only, hence PLATFORM on the build.
      IMAGES = DockerBases::IMAGES
      PLATFORM = "linux/amd64".freeze
      DOCKERFILE = File.expand_path("../../evals/docker/Dockerfile", __dir__)
      # The build context is the REPO ROOT: the eight trees and install/ are what the
      # root.dockerignore lets through.
      CONTEXT = File.expand_path("../../..", __dir__)
      HOME = "/var/lib/rho".freeze
      # The two files of the home the harness reads while a container lives
      # (`Rho::Home#announcement_path`, `#log_path`) — THROUGH the container
      # (`cat_argv`), never the host path: a family that runs as root
      # (terminal-bench) on a native-Linux host leaves them root's 0600 in
      # root's 0700 dirs, unreadable to the harness's uid until the release
      # (Docker Desktop maps a bind mount's owner to the container's user,
      # which is why the Mac never showed it).
      ANNOUNCEMENT = File.join(HOME, "tmp", "announcement.json").freeze
      RHO_LOG = File.join(HOME, "log", "rho.log").freeze
      APP = "/app".freeze
      TESTS = "/tests".freeze
      VERIFIER_LOGS = "/logs/verifier".freeze
      REWARD = "reward.txt".freeze
      HOST_FROM_CONTAINER = "host.docker.internal".freeze
      LOOPBACK = "127.0.0.1".freeze
      ANY = "0.0.0.0".freeze
      HOST_NETWORK = "host".freeze
      # A verb inside the container: the prefix is on the image's PATH, so
      # `rho` itself is the door for `docker exec` (the ENTRYPOINT — tini
      # then libexec/docker-entrypoint — is the CMD's).
      RHO = "rho".freeze
      TAG_PREFIX = "rho-evals-".freeze
      # THE APP TREE'S OWNER (the recipe's `APP_OWNER` build arg): the
      # image's own uid — the rails family's `git apply` runs as it — or
      # the word that leaves the tree the base's (terminal-bench runs as
      # root over harbor's root-owned tree; git refuses a repository
      # another uid owns).
      APP_OWNER_RHO = "1000:1000".freeze
      APP_OWNER_BASE = "base".freeze
      APP_OWNER_ARG = "APP_OWNER".freeze
      TAG_OWNER_INFIX = "-app-owner-".freeze
      GIT_DIR = ".git".freeze
      # The tests' verifier runs as root with root's HOME: `test.sh` sources
      # `$HOME/.local/bin/env` after installing uv there.
      ROOT = "0".freeze
      ROOT_HOME = "/root".freeze
      # A tree git refuses as the container's user, before the model was
      # asked: the LANE's error (the record's `error`, the scorecard's
      # lane bug), never the run's conduct.
      class TreeRefused < StandardError; end

      module_function

      def base_for(profile) = DockerBases.base_for(profile)

      def tag_for(profile) = "#{TAG_PREFIX}#{profile}"

      # WHO OWNS THE TREE, from the user the family runs the container as:
      # nil is the image's own user (uid 1000 — the rails family), whose
      # tree it must be; any other uid (root — terminal-bench) works the
      # tree as the base made it, so the base's owner stands.
      def app_owner_for(container_user:) = container_user.nil? ? APP_OWNER_RHO : APP_OWNER_BASE

      # A base's derived tag: docker allows `[A-Za-z0-9_][A-Za-z0-9_.-]*`, so
      # the registry's `/` and `:` become `-`. The RECIPE's owner rides
      # the tag when it is not the default: two derivations of one base
      # never share a tag, and an image cached under the old recipe is
      # missed by name, never reused.
      def tag_for_base(base, app_owner: APP_OWNER_RHO)
        tag = TAG_PREFIX + slug(base)
        app_owner == APP_OWNER_RHO ? tag : tag + TAG_OWNER_INFIX + slug(app_owner)
      end

      def slug(text) = text.to_s.downcase.gsub(/[^a-z0-9._-]+/, "-")

      def build_argv(base:, app_owner: APP_OWNER_RHO, tag: tag_for_base(base, app_owner: app_owner))
        ["docker", "build", "--platform", PLATFORM, "-f", DOCKERFILE, "--build-arg", "BASE=#{base}",
         "--build-arg", "#{APP_OWNER_ARG}=#{app_owner}", "-t", tag, CONTEXT]
      end

      def pull_argv(base) = ["docker", "pull", "--platform", PLATFORM, base]

      # THE PRE-FLIGHT: apt-get alone — the derived image installs the
      # compiler and the rest from the manifest's prerequisites row; `cc` is
      # not a base requirement (the slim Debian bases have none).
      def preflight_argv(base) = ["docker", "run", "--rm", "--platform", PLATFORM, base, "sh", "-c", "command -v apt-get"]

      # The tree the agent works in is the IMAGE's WorkingDir (20 of the 21
      # `/app`, sanitize-git-repo `/app/dclm`; their test.sh refuses `/`).
      def workdir_argv(base) = ["docker", "image", "inspect", "--format", "{{.Config.WorkingDir}}", base]

      def image_exists_argv(tag) = ["docker", "image", "inspect", tag]

      # THE GIT-TREE PRE-FLIGHT'S TWO ARGVS, as the container's user (nil:
      # the image's own, no `-u`): is the WorkingDir a repository, and does
      # git answer for it.
      def git_tree_argv(name, workdir:, user:) = exec_argv(name, "test", "-e", File.join(workdir, GIT_DIR), user: user)

      def git_dir_argv(name, workdir:, user:) = exec_argv(name, "git", "-C", workdir, "rev-parse", "--git-dir", user: user)

      # The WorkingDir off the pulled base, through the spawner; a base
      # naming none is refused by name.
      def workdir_of(base, docker: method(:run!))
        output, status = docker.call(workdir_argv(base))
        raise "docker image inspect #{base} failed:\n#{output}" unless status.success?

        workdir = output.to_s.strip
        raise "#{base} names no WorkingDir (their test.sh refuses to run at /)" if workdir.empty? || workdir == "/"

        workdir
      end

      # Nexus as the container sees it: the harness binds 127.0.0.1, which
      # inside a bridge container is the container itself; on the host's
      # own network it is the host.
      def nexus_url_from_container(base_url, network: nil)
        return base_url if network == HOST_NETWORK

        uri = URI(base_url)
        uri.host = HOST_FROM_CONTAINER if [LOOPBACK, "localhost", ANY].include?(uri.host)
        uri.to_s
      end

      # THE PAIRING URL, BACK FROM THE CONTAINER'S VIEW: Nexus builds
      # `verification_uri_complete` from the Host header it was asked with,
      # so a bridge container's `/device/start` answers `host.docker.internal:
      # <port>` — a name the steward's browser ON THE HOST does not resolve
      # (the install GROUP's third world: `net::ERR_NAME_NOT_RESOLVED`). The
      # two URL keys are rewritten to the harness's own host; on the host's
      # network the answer is already the host's. A new document, never the
      # answer mutated.
      PAIRING_URL_KEYS = %w[verification_uri verification_uri_complete].freeze

      def pairing_from_container(document, base_url:, network: nil)
        return document if network == HOST_NETWORK

        host = URI(base_url).host
        rewritten = PAIRING_URL_KEYS.filter_map do |key|
          value = document[key]
          next if value.nil?

          uri = URI(value)
          next unless uri.host == HOST_FROM_CONTAINER

          uri.host = host
          [key, uri.to_s]
        end
        document.merge(rewritten.to_h)
      end

      # The network the host needs: a bridge reaches a 127.0.0.1-bound Nexus
      # through Docker Desktop's `host.docker.internal` on macOS; on Linux
      # nothing on the bridge reaches the host's loopback, so the container
      # shares the host's network.
      def network_for(platform = RUBY_PLATFORM) = platform.include?("linux") ? HOST_NETWORK : nil

      # `docker run`: detached; on a bridge the port published on the host's
      # loopback for `control` and the host reachable by name, with
      # plaintext acknowledged on the non-loopback bind; on the host's
      # network the daemon binds loopback itself; the home bind-mounted
      # (the announcement, the log and the pairing live there); the task
      # dir read-only at /tests when a family mounts one for the turn; the
      # verifier's host dir at /logs/verifier when a family reads a reward;
      # the user when a family runs as root. Nexus OAuth owns browser login;
      # the private announcement bearer still owns harness control.
      def run_argv(name:, tag:, port:, home:, nexus_url:, task_dir: nil, logs_dir: nil, user: nil, network: nil)
        host = network == HOST_NETWORK
        ["docker", "run", "-d", "--name", name,
         *(host ? ["--network", HOST_NETWORK] : ["-p", "#{LOOPBACK}:#{port}:#{port}"]),
         "-v", "#{home}:#{HOME}",
         *(task_dir ? ["-v", "#{task_dir}:#{TESTS}:ro"] : []),
         *(logs_dir ? ["-v", "#{logs_dir}:#{VERIFIER_LOGS}"] : []),
         *(host ? [] : ["--add-host", "#{HOST_FROM_CONTAINER}:host-gateway"]),
         *(user ? ["--user", user.to_s] : []),
         "-e", "RHO_MODE=runner",
         tag, "server", "--bind", (host ? LOOPBACK : ANY), "--port", port.to_s,
         "--nexus-url", nexus_url_from_container(nexus_url, network: network),
         *(host ? [] : ["--unsafe-plaintext"])]
      end

      def exec_argv(name, *command, workdir: nil, user: nil, env: {})
        ["docker", "exec", *(workdir ? ["-w", workdir] : []), *(user ? ["-u", user.to_s] : []),
         *env.flat_map { |key, value| ["-e", "#{key}=#{value}"] }, name, *command]
      end

      # A rho verb inside the container.
      def cli_argv(name, *arguments, nexus_url:, network: nil)
        exec_argv(name, RHO, *arguments, "--nexus-url", nexus_url_from_container(nexus_url, network: network))
      end

      def apply_argv(name) = exec_argv(name, "git", "apply", File.join(TESTS, "environment.patch"), workdir: APP)

      # Their verifier's three steps, each an exec in the app: restore the
      # graded surfaces, the shipped suite, the hidden test.
      def verify_argvs(name, bench)
        [bench.restore_argv, bench.preverify_argv, bench.verifier_argv].compact.map { |argv| exec_argv(name, *argv, workdir: APP) }
      end

      # The hidden check copied in AFTER the turn (harbor's shape): the
      # task's `tests/` dir becomes the container's `/tests`.
      def copy_tests_argv(name, tests_dir) = ["docker", "cp", tests_dir, "#{name}:#{TESTS}"]

      # terminal-bench's verifier: `tests/test.sh` as root, in the image's
      # WorkingDir, with root's HOME — it writes `/logs/verifier/reward.txt`.
      def reward_argv(name, workdir:) = exec_argv(name, "bash", File.join(TESTS, "test.sh"), workdir: workdir, user: ROOT, env: { "HOME" => ROOT_HOME })

      def reward_path(logs_dir) = File.join(logs_dir, REWARD)

      # harbor's reward is a float; `1` passes, `0` fails, anything else is
      # red by name (nil).
      def reward_of(text)
        Float(text.to_s.strip)
      rescue ArgumentError, TypeError
        nil
      end

      def logs_argv(name) = ["docker", "logs", name]

      # `true`/`false`: a container that refused to boot answers at once,
      # never after a patience.
      def running_argv(name) = ["docker", "inspect", "--format", "{{.State.Running}}", name]

      # A file of the home read through the container: the container's own
      # user reads its own files, whichever uid the family runs as.
      def cat_argv(name, path) = exec_argv(name, "cat", path)

      # THE HOME HANDED BACK before the container goes (root inside,
      # whatever the image's user): `chown -R <uid>:<gid>` to the harness's
      # own ids. A mode alone was not enough — the entrypoint chowns a
      # `--user 0` boot's home to root, the bind mount's own dir included,
      # and under a sticky /tmp only a dir's owner unlinks it: the box's
      # teardown met `Errno::EPERM @ dir_s_rmdir` on a home `chmod -R a+rwX`
      # had emptied but left root's. Owned by the harness's user, every file
      # and the dir itself are its to delete, and `daemon.log` written
      # after the release lands as that user. The default ids are the
      # calling process's; the daemon passes its own.
      def release_argv(uid:, gid:) = ["chown", "-R", "#{uid}:#{gid}", HOME]

      def release_home_argv(name, uid: Process.uid, gid: Process.gid) = exec_argv(name, *release_argv(uid: uid, gid: gid), user: ROOT)

      # A ONE-SHOT CONTAINER OVER THE SAME HOME: the image's ENTRYPOINT
      # replaced by the command, root inside, gone after — what stands in
      # for an exec when the container has EXITED (the box's chess run: a
      # boot refused at once leaves a root-owned home no exec can release
      # and no exec can read; the host user's teardown then fails
      # ENOTEMPTY). `--entrypoint` skips the door's own chown.
      def run_once_argv(tag:, home:, command:)
        ["docker", "run", "--rm", "--user", ROOT, "-v", "#{home}:#{HOME}", "--entrypoint", command.first, tag, *command.drop(1)]
      end

      def release_home_run_once_argv(tag:, home:, uid: Process.uid, gid: Process.gid)
        run_once_argv(tag: tag, home: home, command: release_argv(uid: uid, gid: gid))
      end

      def cat_run_once_argv(tag:, home:, path:) = run_once_argv(tag: tag, home: home, command: ["cat", path])

      def stop_argv(name) = ["docker", "rm", "-f", name]

      # THE HOST SIDE: the full-mode rho's `rho do` naming the container's
      # runner; `--dir` describes the tree the runner announced (the image's
      # WorkingDir), which lives in the container, not on the host.
      def do_arguments(text, model:, runner:, dir: APP) = ["do", text, "--model", model, "--dir", dir, "--runner", runner]

      # A free host port for the container's control endpoint.
      def free_port
        server = TCPServer.new(LOOPBACK, 0)
        server.addr[1]
      ensure
        server&.close
      end

      # The one spawner: stdout+stderr as UTF-8 text and the status.
      def run!(argv)
        output, status = Open3.capture2e(*argv)
        [output.to_s.force_encoding(Encoding::UTF_8).scrub, status]
      end

      # THE EVIDENCE OF A RED RUN, SAVED WHILE THE CONTAINER STANDS: the
      # daemon's `evidence` (its stdout, rho's structured log) written
      # redacted as `<into>/<stem>.container.log` and `<stem>.rho.log` —
      # beside the build log, under the label's `logs/`, with its naming
      # (`<tag>.<run>.<what>.log`) — never into the home, which the
      # teardown removes (the box's chess run: `stop` writes the stdout
      # into the home as `daemon.log`, the home went with the world, and
      # the lane bug's dump held the world's logs alone). Answers the
      # paths so the record can name them.
      EVIDENCE = { "container" => :stdout, "rho" => :rho_log }.freeze

      def save_evidence(daemon, into:, stem:, redact: SecretHygiene.method(:redact))
        FileUtils.mkdir_p(into)
        evidence = daemon.evidence
        EVIDENCE.map do |what, key|
          path = File.join(into, "#{stem}.#{what}.log")
          File.write(path, redact.call(evidence.fetch(key)), encoding: Encoding::UTF_8)
          path
        end
      end

      # A RUNNER-MODE RHO IN A CONTAINER, addressed like every daemon: the
      # announcement read THROUGH the container (`docker exec … cat`; the
      # bind-mounted home is the container's uid's until the release) with
      # its endpoint's host rewritten to the published loopback port; `cli`
      # through `docker exec`; `start`/`stop` through `docker run`/`docker
      # rm`; `restart!` a FRESH container over the SAME home (the pairing
      # and the runner id live there; the image's tree starts clean — one
      # container per run); the container's stdout saved as `daemon.log` on
      # stop so `dump_logs!` and `WorldLog` read it where they read every
      # daemon's, and read as `evidence` while the container stands (the
      # lane's dump of a red run, before the home goes).
      class Daemon < E2E::RhoDaemon
        ANNOUNCED = /event=executor\.announced tools=\d+ address=runner\b/

        attr_reader :name, :port, :tag, :task_dir, :logs_dir, :user, :network, :uid, :gid

        # `uid`/`gid`: whom the release hands the home to — the harness's
        # own process by default (`Docker.release_argv`).
        def initialize(base_url:, home:, name:, port:, tag:, task_dir: nil, logs_dir: nil, user: nil, network: nil,
          uid: Process.uid, gid: Process.gid, docker: Docker.method(:run!))
          super(base_url: base_url, home: home)
          @name = name
          @port = port
          @tag = tag
          @task_dir = task_dir
          @logs_dir = logs_dir
          @user = user
          @network = network
          @uid = uid
          @gid = gid
          @docker = docker
        end

        def run_argv
          Docker.run_argv(name: @name, tag: @tag, port: @port, home: @home, nexus_url: @base_url, task_dir: @task_dir,
            logs_dir: @logs_dir, user: @user, network: @network)
        end

        # A stale announcement — the previous container's, on the shared
        # home — would answer before the new server listens: gone first. A
        # container that EXITED before announcing (a refused bind, a missing
        # verb) is a raise at once, with its stdout, never a patience.
        def start
          FileUtils.rm_f(File.join(@home, "tmp", "announcement.json"))
          FileUtils.mkdir_p(@logs_dir) if @logs_dir
          output, status = @docker.call(run_argv)
          raise "docker run #{@name} failed:\n#{output}" unless status.success?

          await("the container never announced itself") do
            document = announcement
            next document if document && document["endpoint"]

            raise_exited!
            nil
          end
        end

        # The pairing's URLs as the HOST sees Nexus (`Docker.pairing_from_container`).
        def start_ceremony
          Docker.pairing_from_container(super, base_url: @base_url, network: @network)
        end

        # `docker inspect` answering `false` is the one certain signal; a
        # recording docker that answers nothing reads as running.
        def exited?
          output, status = @docker.call(Docker.running_argv(@name))
          status.success? && output.to_s.strip == "false"
        end

        def raise_exited!
          return unless exited?

          logs, = @docker.call(Docker.logs_argv(@name))
          raise "#{@name} exited before announcing itself; its stdout:\n#{logs.to_s.lines.last(20).join}"
        end

        # rho's structured log THROUGH the container — the base's readers
        # (`await_announced`, the lane's readiness after the ceremony;
        # `claims`) read `log_text`, and the host path is the container's
        # uid's alone until the release (root's 0600 in root's 0700 `log/`
        # under a root family on native Linux). Not written yet, or the
        # container gone, is "" — the base's shape.
        def log_text = read_in_container(Docker::RHO_LOG).to_s

        # THE EVIDENCE OF A RED RUN, read while the container still stands
        # (`Docker.save_evidence` writes it beside the build log): the
        # container's stdout — `docker logs`, which an exited container
        # answers too — and rho's structured log through the container, or
        # through a one-shot once it exited. Nothing is written into the home.
        def evidence
          stdout, = @docker.call(Docker.logs_argv(@name))
          { stdout: stdout.to_s, rho_log: (read_in_container(Docker::RHO_LOG) || read_inference_request(Docker::RHO_LOG)).to_s }
        end

        # ONE CONTAINER PER RUN: the previous one removed (its stdout saved),
        # a new one over the same home with this run's verifier dir, ready
        # once its runner address announced AGAIN — the log is the home's
        # and carries every boot's line, so the mark is the count before
        # the stop, read through the container being replaced (a one-shot
        # when it has exited), and the wait reads through the new one.
        def restart!(logs_dir: @logs_dir)
          mark = announced_count(read_in_container(Docker::RHO_LOG) || read_inference_request(Docker::RHO_LOG))
          stop
          @logs_dir = logs_dir
          start
          await("the restarted container never announced its runner address") do
            next true if announced_count(log_text) > mark

            raise_exited!
            nil
          end
        end

        # THE GIT-TREE PRE-FLIGHT (guard), after this run's container stands and before the model is
        # asked: a WorkingDir holding a `.git` must answer `git rev-parse --git-dir` as the
        # container's user — root for terminal-bench, the image's uid for the rails family. git's
        # answer when it does; nil when the tree is no repository; a refusal (git ≥ 2.35.2's
        # "dubious ownership" of a tree another uid owns) is `TreeRefused` at once, git's own first
        # line ON the raise's first line AHEAD of the recipe hint (the run's record keeps that
        # line's first 300 chars: a long container name clips the hint, never git), so the record
        # reads a LANE bug and never the model's conduct.
        def preflight_git_tree!(workdir)
          _, present = @docker.call(Docker.git_tree_argv(@name, workdir: workdir, user: @user))
          return nil unless present.success?

          output, status = @docker.call(Docker.git_dir_argv(@name, workdir: workdir, user: @user))
          return output.to_s.strip if status.success?

          whom = @user.nil? ? "the image's own user" : "uid #{@user}"
          first, *rest = output.to_s.strip.lines(chomp: true)
          raise TreeRefused, "lane bug: git refuses #{workdir} as #{whom} in #{@name} before the model was asked: #{first} " \
                             "(the tree's owner is not the container's user — the image's APP_OWNER recipe)" \
                             "#{rest.empty? ? "" : "\n#{rest.join("\n")}"}"
        end

        # The patch, before the turn: `git apply` inside the app.
        def apply_environment!
          output, status = @docker.call(Docker.apply_argv(@name))
          raise "git apply of environment.patch failed in #{@name}:\n#{output}" unless status.success?

          output
        end

        # Their verification: every step's output, and whether the LAST
        # one (the hidden test) exited 0 — a restore or preverify that
        # fails is a red with its output, never a raise.
        def verify!(bench)
          outputs = []
          Docker.verify_argvs(@name, bench).each do |argv|
            output, status = @docker.call(argv)
            outputs << "$ #{argv[(argv.index(@name) + 1)..].join(" ")}\n#{output}"
            return { "pass" => false, "output" => outputs.join("\n") } unless status.success?
          end
          { "pass" => true, "output" => outputs.join("\n") }
        end

        # THE REWARD SHAPE (terminal-bench): the tests copied in, their
        # `test.sh` run as root in the workdir under the verifier's own
        # timeout, then `reward.txt` read off the host dir — `1`/`0`; absent
        # or unparseable is red by name; a step that fails is red with its
        # output. Never a raise.
        def verify_reward!(tests_dir:, workdir:, timeout: nil)
          raise ArgumentError, "verify_reward! needs the container's /logs/verifier bind-mounted (logs_dir:)" if @logs_dir.nil?

          outputs = []
          copied, status = @docker.call(Docker.copy_tests_argv(@name, tests_dir))
          outputs << "$ docker cp #{tests_dir} #{@name}:#{Docker::TESTS}\n#{copied}"
          return { "pass" => false, "output" => outputs.join("\n") } unless status.success?

          argv = Docker.reward_argv(@name, workdir: workdir)
          output, status = bounded(timeout) { @docker.call(argv) }
          outputs << "$ #{argv[(argv.index(@name) + 1)..].join(" ")} (exit #{status.exitstatus})\n#{output}"
          reward_line, reward = read_reward
          outputs << reward_line
          { "pass" => !reward.nil? && reward >= 1, "output" => outputs.join("\n"), "reward" => reward }
        rescue Timeout::Error
          outputs << "the verifier ran past #{timeout} s and was abandoned (the container is removed after the run)"
          { "pass" => false, "output" => outputs.join("\n"), "reward" => nil }
        end

        def cli(*arguments)
          @docker.call(Docker.cli_argv(@name, *arguments, nexus_url: @base_url, network: @network))
        end

        def cli_background(*) = raise(NotImplementedError, "a container's rho has no streaming verb through this harness")

        # The container's stdout read, the bind-mounted home HANDED BACK (its
        # files, and the dir itself, are the container's uid's — 1000, or
        # root — and the host user must delete them after), THEN the stdout
        # saved into the home as `daemon.log` (a root-owned home refuses the
        # host user before the release; after it the file is the host
        # user's), then removed. A container already gone answers nothing
        # to `logs`, and that is fine.
        def stop
          output, = @docker.call(Docker.logs_argv(@name))
          release_home!
          File.write(@log_path, output.to_s, mode: "a", encoding: Encoding::UTF_8)
          @docker.call(Docker.stop_argv(@name))
          nil
        end

        alias_method :kill!, :stop

        private

          # Through the container's own exec while it runs; an EXITED
          # container answers no exec, so a one-shot over the same home
          # does it (the box's chess run: the home root's after a boot rho
          # refused, and the host user's teardown owed a deletable tree).
          # Either way to the daemon's ids.
          def release_home!
            _, status = @docker.call(Docker.release_home_argv(@name, uid: @uid, gid: @gid))
            return if status.success?

            @docker.call(Docker.release_home_run_once_argv(tag: @tag, home: @home, uid: @uid, gid: @gid))
          end

          # A file of the home through the container: its text, or nil when
          # the exec is refused — the file not there yet, or the container
          # exited (which `raise_exited!` tells apart).
          def read_in_container(path)
            output, status = @docker.call(Docker.cat_argv(@name, path))
            status.success? ? output.to_s : nil
          end

          # The same file through a one-shot container (an exited one's).
          def read_inference_request(path)
            output, status = @docker.call(Docker.cat_run_once_argv(tag: @tag, home: @home, path: path))
            status.success? ? output.to_s : nil
          end

          def announced_count(log_text) = log_text.to_s.scan(ANNOUNCED).size

          def bounded(timeout, &block)
            return block.call if timeout.nil?

            Timeout.timeout(timeout, &block)
          end

          def read_reward
            path = Docker.reward_path(@logs_dir)
            return ["no #{Docker::VERIFIER_LOGS}/#{Docker::REWARD} was written (#{path})", nil] unless File.file?(path)

            text = File.read(path, encoding: Encoding::UTF_8)
            reward = Docker.reward_of(text)
            return ["#{Docker::REWARD} holds #{text.strip.inspect}, not a number", nil] if reward.nil?

            ["#{Docker::REWARD}: #{reward}", reward]
          end

          # The announcement THROUGH the container — never the host path
          # (`E2E::RhoDaemon`'s read is the host's own daemon's); absent or
          # half-written while the boot is awaited is nil, and once written it
          # is rho's own document, trusted as the host's read trusts it — a
          # `null` one reading as absent, as the host's reader takes it. The announced
          # endpoint binds 0.0.0.0 INSIDE a bridge container; on the host
          # the same port is published on loopback (on the host's network
          # it is loopback already).
          def announcement
            text = read_in_container(Docker::ANNOUNCEMENT)
            return nil if text.nil?

            document = JSON.parse(text)
            return document unless document && document["endpoint"]

            uri = URI(document["endpoint"])
            uri.host = LOOPBACK
            document.merge("endpoint" => uri.to_s)
          rescue JSON::ParserError
            nil
          end
      end
    end
  end
end
