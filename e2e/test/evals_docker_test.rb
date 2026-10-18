require "test_helper"
require "support/evals"
require "json"
require "tmpdir"

# THE DOCKER HOOKS, ARGV ONLY: every command a container family's leg would spawn — the derived
# image's build from ANY base (the rails profiles' map, terminal-bench's per-task base slugged into
# a tag), the pull and the pre-flight, the WorkingDir read, the container's run with the published
# port and the mounts (the tests, the verifier's host dir, the user, the host's network on Linux),
# the patch, the verifier's three steps, the reward's copy-then-exec, the host's `rho do --runner` —
# as the exact argv, never spawned; and the container daemon over a RECORDING docker: the
# announcement's host rewritten to loopback, a stale announcement never read, `restart!` a fresh
# container over the same home, `cli` through `docker exec`, `stop` saving the container's log and
# handing the home back to the harness's user; the evidence of a red run saved beside the build log.
# Nothing here runs docker.
class EvalsDockerTest < Minitest::Test
  K = E2E::Evals::Docker
  A = E2E::Evals::AgentsOnRails
  FIXTURE = File.expand_path("../support/fixtures/agents_on_rails", __dir__)
  Status = Data.define(:ok) do
    def success? = ok
  end

  # THE APP TREE'S OWNER IS THE FAMILY'S: the recipe chowns the base's WorkingDir to uid 1000 for
  # the rails family — `git apply` runs as the image's own user — and LEAVES IT THE BASE'S for
  # terminal-bench, whose container runs as root over harbor's root-owned tree: git ≥ 2.35.2 refuses
  # a repository another uid owns ("dubious ownership"), so a 1000-owned `/app/dclm` under a root
  # container made sanitize-git-repo's verifier raise before comparing a byte (glm #1: tests 1–2
  # passed, reward 0) and every other pass contingent on the model adding `safe.directory` itself.
  # The owner is a BUILD ARG the lane derives from the task's `container_user` (nil: the image's uid
  # works the tree; another uid: the base's owner stands), and the TAG carries the recipe's owner
  # when it is not the default — two derivations of one base never share a tag, and the box's cached
  # 1000-owned terminal-bench images are missed by name, never reused.
  def test_the_build_argv_derives_the_image_from_any_base_at_the_repo_root
    assert_equal ["docker", "build", "--platform", "linux/amd64", "-f", K::DOCKERFILE, "--build-arg",
                  "BASE=ghcr.io/evilmartians/lemans-fizzy:8112b3d", "--build-arg", "APP_OWNER=1000:1000", "-t", "rho-evals-fizzy", K::CONTEXT],
      K.build_argv(base: K.base_for("fizzy"), tag: K.tag_for("fizzy")), "the rails family: the tree chowned to the image's uid"
    assert_equal "1000:1000", K::APP_OWNER_RHO
    assert_equal "base", K::APP_OWNER_BASE
    assert_equal K::APP_OWNER_RHO, K.app_owner_for(container_user: nil), "the container runs as the image's uid: the tree is its"
    assert_equal K::APP_OWNER_BASE, K.app_owner_for(container_user: "0"), "the container runs as root: the base's owner stands"
    # A terminal-bench base: the tag is the base slugged (docker's tag
    # grammar) PLUS the recipe's owner when it is not the default.
    assert_equal "rho-evals-alexgshaw-chess-best-move-20251031", K.tag_for_base("alexgshaw/chess-best-move:20251031")
    assert_equal "rho-evals-alexgshaw-chess-best-move-20251031", K.tag_for_base("alexgshaw/chess-best-move:20251031", app_owner: K::APP_OWNER_RHO)
    assert_equal "rho-evals-alexgshaw-chess-best-move-20251031-app-owner-base",
      K.tag_for_base("alexgshaw/chess-best-move:20251031", app_owner: K::APP_OWNER_BASE)
    assert_equal ["docker", "build", "--platform", "linux/amd64", "-f", K::DOCKERFILE, "--build-arg",
                  "BASE=alexgshaw/chess-best-move:20251031", "--build-arg", "APP_OWNER=base",
                  "-t", "rho-evals-alexgshaw-chess-best-move-20251031-app-owner-base", K::CONTEXT],
      K.build_argv(base: "alexgshaw/chess-best-move:20251031", app_owner: K::APP_OWNER_BASE), "terminal-bench: the tree stays harbor's"
    assert_equal ["docker", "build", "--platform", "linux/amd64", "-f", K::DOCKERFILE, "--build-arg",
                  "BASE=alexgshaw/chess-best-move:20251031", "--build-arg", "APP_OWNER=1000:1000",
                  "-t", "rho-evals-alexgshaw-chess-best-move-20251031", K::CONTEXT],
      K.build_argv(base: "alexgshaw/chess-best-move:20251031"), "the default owner is the rails family's"
    assert_equal %w[docker pull --platform linux/amd64 alexgshaw/chess-best-move:20251031], K.pull_argv("alexgshaw/chess-best-move:20251031")
    assert_equal ["docker", "run", "--rm", "--platform", "linux/amd64", "b", "sh", "-c", "command -v apt-get"], K.preflight_argv("b"),
      "the pre-flight is apt-get alone: the derived image installs the compiler itself"
    assert_equal ["docker", "image", "inspect", "--format", "{{.Config.WorkingDir}}", "b"], K.workdir_argv("b")
    assert_equal %w[docker image inspect rho-evals-x], K.image_exists_argv("rho-evals-x")
    assert_path_exists K::DOCKERFILE
    dockerfile = File.read(K::DOCKERFILE, encoding: Encoding::UTF_8)
    assert_match(/^ARG BASE\n(?:#.*\n)*FROM --platform=linux\/amd64 \$\{BASE\}$/, dockerfile, "the base is pinned to its one arch")
    assert_match(/^ARG APP_OWNER=1000:1000$/, dockerfile, "the tree's owner is a build arg whose default is the rails family's")
    assert_match(/chown -R 1000:1000 \/opt\/rho \/var\/lib\/rho; \\$/, dockerfile, "rho's own homes are uid 1000's on every base; /app is not in that chown")
    assert_match(/case "\$APP_OWNER" in base\) ;; \*\) chown -R "\$APP_OWNER" \/app ;; esac$/, dockerfile,
      "the app tree is chowned only when the arg names an owner: `base` leaves it the base's")
    refute_match(/chown -R 1000:1000 [^\n]*\/app\b/, dockerfile, "no unconditional chown of /app remains")
    assert_includes dockerfile, "install/install.sh --from-checkout /rho/src", "the same installer the host runs"
    assert_includes dockerfile, 'ENTRYPOINT ["/usr/bin/tini", "--", "/opt/rho/libexec/docker-entrypoint"]'
    assert_path_exists File.join(K::CONTEXT, "agents/rho/rho/Gemfile"), "the context is the repo root"
    assert_path_exists File.join(K::CONTEXT, "install/install.sh"), "the installer is in the context"
    K::IMAGES.each_value { |image| assert_match(/:[^\/]+\z/, image, "#{image} names a tag (:latest does not exist on ghcr)") }
    assert_raises(ArgumentError) { K.base_for("rails") }
  end

  # THE GIT-TREE PRE-FLIGHT (honest guard): after the run's container stands and before the model is
  # asked, when the WorkingDir holds a `.git`, `git -C <workdir> rev-parse --git-dir` runs AS THE
  # CONTAINER'S USER (`docker exec`: root for terminal-bench, the image's uid for the rails family —
  # no `-u`); a refusal is a LANE ERROR raised at once, so the record carries an `error` and the
  # scorecard reads a lane bug, never model conduct; a tree with no `.git` is nothing to check; a
  # tree git answers passes with its answer. Over a scripted docker: the two argvs, the raise's
  # words (the workdir, the uid, git's own line), and that no further command is spawned past the
  # refusal.
  def test_the_git_tree_preflight_runs_as_the_container_user_and_a_refusal_is_a_lane_error
    assert_equal %w[docker exec -u 0 c test -e /app/dclm/.git], K.git_tree_argv("c", workdir: "/app/dclm", user: "0")
    assert_equal %w[docker exec -u 0 c git -C /app/dclm rev-parse --git-dir], K.git_dir_argv("c", workdir: "/app/dclm", user: "0")
    assert_equal %w[docker exec c test -e /app/.git], K.git_tree_argv("c", workdir: "/app", user: nil), "the image's own user: no -u"
    assert_equal %w[docker exec c git -C /app rev-parse --git-dir], K.git_dir_argv("c", workdir: "/app", user: nil)
    assert_operator K::TreeRefused, :<, StandardError

    Dir.mktmpdir("evals-docker") do |home|
      calls = []
      git_present = true
      git_answer = [".git\n", Status.new(ok: true)]
      docker = lambda do |argv|
        calls << argv
        next ["", Status.new(ok: git_present)] if argv.include?("test")
        next git_answer if argv.include?("rev-parse")

        ["", Status.new(ok: true)]
      end
      daemon = K::Daemon.new(base_url: "http://127.0.0.1:3999", home: home, name: "c", port: 47017, tag: "t", user: "0", docker: docker)

      assert_equal ".git", daemon.preflight_git_tree!("/app/dclm"), "git's answer, stripped"
      assert_equal [K.git_tree_argv("c", workdir: "/app/dclm", user: "0"), K.git_dir_argv("c", workdir: "/app/dclm", user: "0")], calls

      calls.clear
      git_present = false
      assert_nil daemon.preflight_git_tree!("/app"), "no .git: nothing to check"
      assert_equal [K.git_tree_argv("c", workdir: "/app", user: "0")], calls, "git is never asked about a tree that is not a repository"

      calls.clear
      git_present = true
      git_answer = ["fatal: detected dubious ownership in repository at '/app/dclm'\nTo add an exception for this directory, call:\n\n" \
                    "\tgit config --global --add safe.directory /app/dclm\n", Status.new(ok: false)]
      error = assert_raises(K::TreeRefused) { daemon.preflight_git_tree!("/app/dclm") }
      assert_includes error.message, "lane bug"
      assert_includes error.message, "git refuses /app/dclm as uid 0 in c"
      assert_includes error.message, "detected dubious ownership in repository at '/app/dclm'"
      assert_includes error.message.lines.first, "fatal: detected dubious ownership in repository at '/app/dclm'",
        "git's own line rides the raise's FIRST line: the run's record keeps that line alone"
      assert_includes error.message, "before the model was asked"
      assert_equal [K.git_tree_argv("c", workdir: "/app/dclm", user: "0"), K.git_dir_argv("c", workdir: "/app/dclm", user: "0")], calls,
        "nothing is spawned past the refusal"
      # The run's record keeps the first line's first 300 chars: under a
      # real container name (`<tag>-<pid>`, the tag carrying the owner) git's
      # line must sit inside that window, whatever else the raise explains.
      long = K::Daemon.new(base_url: "http://127.0.0.1:3999", home: home,
        name: "rho-evals-alexgshaw-multi-source-data-merger-with-a-longer-slug-20251031-app-owner-base-755872",
        port: 47019, tag: "t", user: "0", docker: docker)
      error = assert_raises(K::TreeRefused) { long.preflight_git_tree!("/app/dclm") }
      assert_includes error.message.lines.first.to_s.strip[0, 300], "fatal: detected dubious ownership in repository at '/app/dclm'",
        "git's line survives the record's 300-char window under a long container name"

      rails = K::Daemon.new(base_url: "http://127.0.0.1:3999", home: home, name: "r", port: 47018, tag: "t", docker: docker)
      calls.clear
      error = assert_raises(K::TreeRefused) { rails.preflight_git_tree!("/app") }
      assert_includes error.message, "git refuses /app as the image's own user in r"
      assert_equal [%w[docker exec r test -e /app/.git], %w[docker exec r git -C /app rev-parse --git-dir]], calls
    end
  end

  # The WorkingDir off the base through the spawner: read, or refused by
  # name when the image names none (their test.sh refuses `/`).
  def test_the_workdir_is_read_off_the_base_and_never_assumed
    assert_equal "/app/dclm", K.workdir_of("b", docker: ->(_argv) { ["/app/dclm\n", Status.new(ok: true)] })
    assert_match(/names no WorkingDir/, assert_raises(RuntimeError) { K.workdir_of("b", docker: ->(_argv) { ["\n", Status.new(ok: true)] }) }.message)
    assert_match(/names no WorkingDir/, assert_raises(RuntimeError) { K.workdir_of("b", docker: ->(_argv) { ["/\n", Status.new(ok: true)] }) }.message)
    assert_match(/inspect b failed/, assert_raises(RuntimeError) { K.workdir_of("b", docker: ->(_argv) { ["no such image", Status.new(ok: false)] }) }.message)
  end

  def test_the_run_argv_publishes_the_port_mounts_the_home_and_the_task_and_names_the_host
    argv = K.run_argv(name: "rho-evals-sample", tag: "rho-evals-writebook", port: 47001, home: "/tmp/home", task_dir: "/corpus/tasks/sample",
      nexus_url: "http://127.0.0.1:3999")
    assert_equal ["docker", "run", "-d", "--name", "rho-evals-sample", "-p", "127.0.0.1:47001:47001", "-v", "/tmp/home:/var/lib/rho",
                  "-v", "/corpus/tasks/sample:/tests:ro", "--add-host", "host.docker.internal:host-gateway", "-e", "RHO_MODE=runner",
                  "rho-evals-writebook", "server", "--bind", "0.0.0.0", "--port", "47001", "--nexus-url", "http://host.docker.internal:3999",
                  "--unsafe-plaintext"], argv
    assert_equal "http://host.docker.internal:3999", K.nexus_url_from_container("http://localhost:3999")
    assert_equal "https://nexus.example", K.nexus_url_from_container("https://nexus.example")

    # terminal-bench's run: no tests mount for the turn, the verifier's host
    # dir at /logs/verifier, root — after the home, before the mode.
    tb = K.run_argv(name: "c", tag: "rho-evals-alexgshaw-x-1", port: 47002, home: "/tmp/home", logs_dir: "/tmp/verifier", user: "0",
      nexus_url: "http://127.0.0.1:3999")
    assert_equal ["docker", "run", "-d", "--name", "c", "-p", "127.0.0.1:47002:47002", "-v", "/tmp/home:/var/lib/rho",
                  "-v", "/tmp/verifier:/logs/verifier", "--add-host", "host.docker.internal:host-gateway", "--user", "0",
                  "-e", "RHO_MODE=runner",
                  "rho-evals-alexgshaw-x-1", "server", "--bind", "0.0.0.0", "--port", "47002",
                  "--nexus-url", "http://host.docker.internal:3999", "--unsafe-plaintext"], tb
    refute_includes tb, "/tests:ro"

    # On the host's network (Linux: the harness Nexus binds 127.0.0.1 and no
    # bridge reaches it): no published port, no host alias, loopback bind,
    # the base URL as it is, no plaintext waiver (loopback).
    host = K.run_argv(name: "c", tag: "t", port: 47003, home: "/tmp/home", task_dir: "/t", nexus_url: "http://127.0.0.1:3999", network: "host")
    assert_equal ["docker", "run", "-d", "--name", "c", "--network", "host", "-v", "/tmp/home:/var/lib/rho", "-v", "/t:/tests:ro",
                  "-e", "RHO_MODE=runner", "t", "server", "--bind", "127.0.0.1", "--port", "47003", "--nexus-url", "http://127.0.0.1:3999"], host
    assert_equal %w[docker inspect --format {{.State.Running}} c], K.running_argv("c")

    # The pairing URL back from the container's view of Nexus: the host's
    # browser resolves 127.0.0.1, never host.docker.internal; the host's
    # network answers the host's URL already; the answer is never mutated.
    answer = { "verification_uri_complete" => "http://host.docker.internal:3999/oauth/device?user_code=ABCD-EFGH",
               "verification_uri" => "http://host.docker.internal:3999/oauth/device", "user_code" => "ABCD-EFGH", "branch" => "runner" }.freeze
    seen = K.pairing_from_container(answer, base_url: "http://127.0.0.1:3999")
    assert_equal "http://127.0.0.1:3999/oauth/device?user_code=ABCD-EFGH", seen["verification_uri_complete"]
    assert_equal "http://127.0.0.1:3999/oauth/device", seen["verification_uri"]
    assert_equal %w[ABCD-EFGH runner], seen.values_at("user_code", "branch")
    assert_equal "http://host.docker.internal:3999/oauth/device", answer["verification_uri"], "the answer is not mutated"
    assert_same answer, K.pairing_from_container(answer, base_url: "http://127.0.0.1:3999", network: "host")
    assert_equal({ "error" => { "code" => "x" } }, K.pairing_from_container({ "error" => { "code" => "x" } }, base_url: "http://127.0.0.1:3999"))
    assert_equal "http://127.0.0.1:3999", K.nexus_url_from_container("http://127.0.0.1:3999", network: "host")
    assert_equal "host", K.network_for("x86_64-linux")
    assert_nil K.network_for("arm64-darwin25")
    assert_equal ["docker", "exec", "c", "rho", "status", "--nexus-url", "http://127.0.0.1:1"],
      K.cli_argv("c", "status", nexus_url: "http://127.0.0.1:1", network: "host")
  end

  def test_the_exec_argvs_the_patch_the_verifier_and_the_hosts_do
    assert_equal %w[docker exec -w /app c git apply /tests/environment.patch], K.apply_argv("c")
    assert_equal ["docker", "exec", "c", "rho", "status", "--nexus-url", "http://host.docker.internal:1"],
      K.cli_argv("c", "status", nexus_url: "http://127.0.0.1:1")
    bench = A.load(FIXTURE).bench
    assert_equal [
      ["docker", "exec", "-w", "/app", "c", "git", "checkout", "--", "test", "bin", "config/environments/test.rb"],
      %w[docker exec -w /app c bin/rails test],
      %w[docker exec -w /app c ruby -Itest /tests/verification_test.rb],
    ], K.verify_argvs("c", bench)
    assert_equal %w[docker logs c], K.logs_argv("c")
    assert_equal %w[docker rm -f c], K.stop_argv("c")
    # THE RELEASE HANDS THE HOME BACK: `chown -R <uid>:<gid>` to the
    # harness's user as root inside — the entrypoint chowns a `--user 0`
    # boot's home to root, the bind mount's own dir included, and under a
    # sticky /tmp only the owner unlinks that dir (the box: `chmod -R
    # a+rwX` emptied the home and the teardown's rmdir met EPERM on a dir
    # still root's). The ids are the caller's, pinned here as numbers.
    assert_equal %w[docker exec -u 0 c chown -R 501:20 /var/lib/rho], K.release_home_argv("c", uid: 501, gid: 20)
    assert_equal %w[docker exec -u 0 c chown -R 1000:1000 /var/lib/rho], K.release_home_argv("c", uid: 1000, gid: 1000)
    assert_equal K.release_home_argv("c", uid: Process.uid, gid: Process.gid), K.release_home_argv("c"), "the default is the harness's own ids"
    # THE HOME'S FILES ARE READ THROUGH THE CONTAINER (the box's chess run:
    # root's 0600 announcement and log in root's 0700 dirs on a native-Linux
    # host, the harness another uid): the announcement and the structured
    # log by `docker exec … cat`, never the host path; the release and the
    # log's read survive an EXITED container (no exec answers one) as a
    # one-shot container over the same home, root inside, the ENTRYPOINT
    # replaced by the command.
    assert_equal "/var/lib/rho/tmp/announcement.json", K::ANNOUNCEMENT
    assert_equal "/var/lib/rho/log/rho.log", K::RHO_LOG
    assert_equal %w[docker exec c cat /var/lib/rho/tmp/announcement.json], K.cat_argv("c", K::ANNOUNCEMENT)
    assert_equal %w[docker exec c cat /var/lib/rho/log/rho.log], K.cat_argv("c", K::RHO_LOG)
    assert_equal ["docker", "run", "--rm", "--user", "0", "-v", "/tmp/home:/var/lib/rho", "--entrypoint", "chown", "t", "-R", "501:20", "/var/lib/rho"],
      K.release_home_run_once_argv(tag: "t", home: "/tmp/home", uid: 501, gid: 20)
    assert_equal K.release_home_run_once_argv(tag: "t", home: "/tmp/home", uid: Process.uid, gid: Process.gid),
      K.release_home_run_once_argv(tag: "t", home: "/tmp/home")
    assert_equal ["docker", "run", "--rm", "--user", "0", "-v", "/tmp/home:/var/lib/rho", "--entrypoint", "cat", "t", "/var/lib/rho/log/rho.log"],
      K.cat_run_once_argv(tag: "t", home: "/tmp/home", path: K::RHO_LOG)
    assert_equal ["do", "Throttle it.", "--model", "fixture/strong", "--dir", "/app", "--runner", "exr-1"],
      K.do_arguments("Throttle it.", model: "fixture/strong", runner: "exr-1")
    assert_equal ["do", "Fix it.", "--model", "m", "--dir", "/app/dclm", "--runner", "exr-1"],
      K.do_arguments("Fix it.", model: "m", runner: "exr-1", dir: "/app/dclm")
    # The reward shape: the tests copied in after the turn, test.sh as root
    # in the image's WorkingDir with root's HOME, the reward on the host.
    assert_equal ["docker", "cp", "/corpus/chess-best-move/tests", "c:/tests"], K.copy_tests_argv("c", "/corpus/chess-best-move/tests")
    assert_equal %w[docker exec -w /app -u 0 -e HOME=/root c bash /tests/test.sh], K.reward_argv("c", workdir: "/app")
    assert_equal "/tmp/verifier/reward.txt", K.reward_path("/tmp/verifier")
    assert_in_delta 1.0, K.reward_of("1\n")
    assert_in_delta 0.0, K.reward_of("0")
    assert_in_delta 0.5, K.reward_of(" 0.5 ")
    assert_nil K.reward_of("banana")
    assert_nil K.reward_of("")
    assert_nil K.reward_of(nil)
  end

  # THE CONTAINER DAEMON over a recording docker: start removes a STALE
  # announcement (the previous container's, on a shared home), spawns the
  # run — which, like a real container, writes the announcement into the
  # container's home — and reads it THROUGH THE CONTAINER (`docker exec …
  # cat`; a decoy on the host path proves the host is never read: on a
  # native-Linux host a root container's home is root's 0700 and the
  # harness's uid cannot open it) with its host rewritten; cli is an exec;
  # stop saves the log AFTER releasing the home (the same reason: the host
  # user writes `daemon.log` into a home the release just opened) and
  # removes the container. The daemon carries the ids the release hands
  # the home to, fixed here so the pin is a number, never the machine's.
  def test_the_daemon_addresses_the_container_through_docker_exec
    Dir.mktmpdir("evals-docker") do |home|
      calls = []
      host_decoy = File.join(home, "tmp", "announcement.json")
      container_announcement = nil
      log_before_release = nil
      docker = lambda do |argv|
        calls << argv
        case argv[1]
        when "run"
          container_announcement = JSON.generate({ "endpoint" => "http://0.0.0.0:47001", "bearer" => "local-bearer" })
          FileUtils.mkdir_p(File.dirname(host_decoy))
          File.write(host_decoy, JSON.generate({ "endpoint" => "http://0.0.0.0:47001", "bearer" => "host-file" }))
          ["", Status.new(ok: true)]
        when "logs" then ["container stdout\n", Status.new(ok: true)]
        when "exec"
          if argv.last == K::ANNOUNCEMENT
            container_announcement ? [container_announcement, Status.new(ok: true)] : ["cat: no such file\n", Status.new(ok: false)]
          elsif argv.include?("chown")
            log_before_release = File.exist?(File.join(home, "daemon.log"))
            ["", Status.new(ok: true)]
          else
            [argv.include?("git") ? "" : "state: connected\n", Status.new(ok: !argv.include?("bin/rails"))]
          end
        else ["", Status.new(ok: true)]
        end
      end
      daemon = K::Daemon.new(base_url: "http://127.0.0.1:3999", home: home, name: "rho-evals-sample", port: 47001,
        tag: "rho-evals-writebook", task_dir: "/corpus/tasks/sample", uid: 501, gid: 20, docker: docker)
      FileUtils.mkdir_p(File.join(home, "tmp"))
      File.write(host_decoy, JSON.generate({ "endpoint" => "http://0.0.0.0:1", "bearer" => "stale" }))

      announced = daemon.start
      assert_equal "http://127.0.0.1:47001", announced["endpoint"], "the host is rewritten to the published loopback port"
      assert_equal "local-bearer", announced["bearer"], "the announcement is read through the container, never off the host path"
      assert_equal daemon.run_argv, calls.first
      assert_includes calls, K.cat_argv("rho-evals-sample", K::ANNOUNCEMENT), "the read is a docker exec"
      assert_equal File.join(home, "log", "rho.log"), daemon.rho_log_path

      output, status = daemon.cli("status")
      assert_equal "state: connected\n", output
      assert_predicate status, :success?
      assert_equal K.cli_argv("rho-evals-sample", "status", nexus_url: "http://127.0.0.1:3999"), calls.last

      assert_equal "", daemon.apply_environment!
      assert_equal K.apply_argv("rho-evals-sample"), calls.last

      verdict = daemon.verify!(A.load(FIXTURE).bench)
      assert_equal false, verdict["pass"], "the preverify step failed: the hidden test never ran"
      assert_includes verdict["output"], "$ git checkout -- test bin config/environments/test.rb"
      assert_includes verdict["output"], "$ bin/rails test"
      refute_includes verdict["output"], "verification_test.rb"

      daemon.stop
      assert_equal %w[docker logs rho-evals-sample], calls[-3]
      assert_equal %w[docker exec -u 0 rho-evals-sample chown -R 501:20 /var/lib/rho], calls[-2],
        "the home is the harness user's to delete after — the daemon's ids, not the machine's"
      assert_equal %w[docker rm -f rho-evals-sample], calls.last
      assert_equal "container stdout\n", File.read(daemon.log_path, encoding: Encoding::UTF_8)
      assert_equal false, log_before_release, "daemon.log is written AFTER the release: before it the home is the container's uid's alone"
      assert_raises(NotImplementedError) { daemon.cli_background("follow") }
    end
  end

  # ONE CONTAINER PER RUN: `restart!` removes the container, brings a fresh
  # one up over the SAME home with the run's verifier dir, and is ready only
  # once the runner address announced AGAIN — the first boot's line in the
  # shared log never counts. The log is read through the container (the
  # one being replaced for the mark, the new one for the wait); a decoy on
  # the host path carrying a third line proves the host is never read.
  def test_restart_brings_a_fresh_container_over_the_same_home_and_waits_for_a_new_announcement
    Dir.mktmpdir("evals-docker") do |home|
      calls = []
      container_log = +""
      container_announcement = nil
      boots = 0
      docker = lambda do |argv|
        calls << argv
        case argv[1]
        when "run"
          boots += 1
          container_announcement = JSON.generate({ "endpoint" => "http://0.0.0.0:47005", "bearer" => "b#{boots}" })
          container_log << "event=executor.announced tools=9 address=runner boot=#{boots}\n"
          FileUtils.mkdir_p(File.dirname(daemon_rho_log = File.join(home, "log", "rho.log")))
          File.write(daemon_rho_log, "event=executor.announced tools=9 address=runner decoy=host\n" * 3)
          ["", Status.new(ok: true)]
        when "exec"
          case argv.last
          when K::ANNOUNCEMENT then [container_announcement.to_s, Status.new(ok: !container_announcement.nil?)]
          when K::RHO_LOG then [container_log.dup, Status.new(ok: true)]
          else ["", Status.new(ok: true)]
          end
        else ["", Status.new(ok: true)]
        end
      end
      daemon = K::Daemon.new(base_url: "http://127.0.0.1:3999", home: home, name: "c", port: 47005, tag: "t",
        logs_dir: File.join(home, "verifier-0"), user: "0", docker: docker)
      daemon.start
      assert_equal 1, boots
      assert_path_exists File.join(home, "verifier-0"), "the verifier's host dir is made before the run"

      daemon.restart!(logs_dir: File.join(home, "verifier-1"))
      assert_equal 2, boots
      assert_equal File.join(home, "verifier-1"), daemon.logs_dir
      stopped = calls.map { |argv| argv[1] }.each_cons(4).find { |window| window == %w[logs exec rm run] }
      refute_nil stopped, "removed (its log saved, the home released), then run again: #{calls.map { |argv| argv[1] }.inspect}"
      assert_includes daemon.run_argv, "#{File.join(home, "verifier-1")}:/logs/verifier"
      assert_equal 2, container_log.lines.size, "the shared home's log carries both boots' lines"
      assert_includes calls, K.cat_argv("c", K::RHO_LOG), "the log is read through the container"
      assert_empty calls.select { |argv| argv.include?("--entrypoint") }, "no one-shot container while the one being replaced still answers"
    end
  end

  # THE EXITED CONTAINER (the box's chess run: rho refused to boot as root
  # over the harness's uid-1000 home and the container was gone at once):
  # no exec answers it, so `restart!`'s mark and `stop`'s release go
  # through ONE-SHOT containers over the same home — the release is what
  # lets the host user delete a root-owned home after (the ENOTEMPTY of
  # the box's teardown). A running container is released through its own
  # exec, never a one-shot; either way the home goes to the daemon's ids.
  def test_the_release_and_the_log_survive_an_exited_container_as_inference_requests
    Dir.mktmpdir("evals-docker") do |home|
      calls = []
      alive = false
      container_announcement = nil
      docker = lambda do |argv|
        calls << argv
        case argv[1]
        when "run"
          if argv.include?("--entrypoint")
            [argv.include?("cat") ? "event=executor.announced tools=9 address=runner boot=old\n" : "", Status.new(ok: true)]
          else
            alive = true
            container_announcement = JSON.generate({ "endpoint" => "http://0.0.0.0:47011", "bearer" => "fresh" })
            ["", Status.new(ok: true)]
          end
        when "exec"
          next ["Error response from daemon: container c is not running\n", Status.new(ok: false)] unless alive

          case argv.last
          when K::ANNOUNCEMENT then [container_announcement, Status.new(ok: true)]
          when K::RHO_LOG then ["event=executor.announced tools=9 address=runner boot=old\nevent=executor.announced tools=9 address=runner boot=new\n", Status.new(ok: true)]
          else ["", Status.new(ok: true)]
          end
        else ["", Status.new(ok: true)]
        end
      end
      daemon = K::Daemon.new(base_url: "http://127.0.0.1:3999", home: home, name: "c", port: 47011, tag: "t", user: "0", uid: 501, gid: 20, docker: docker)

      daemon.stop
      assert_equal [%w[docker logs c], %w[docker exec -u 0 c chown -R 501:20 /var/lib/rho],
                    ["docker", "run", "--rm", "--user", "0", "-v", "#{home}:/var/lib/rho", "--entrypoint", "chown", "t", "-R", "501:20", "/var/lib/rho"],
                    %w[docker rm -f c]], calls,
        "the exec refused: the release is a one-shot container over the home, to the daemon's ids"

      calls.clear
      daemon.restart!
      verbs = calls.map { |argv| argv.include?("--entrypoint") ? "one-shot #{argv[argv.index("--entrypoint") + 1]}" : argv[1] }
      assert_equal ["exec", "one-shot cat", "logs", "exec", "one-shot chown", "rm", "run"], verbs.first(7),
        "the mark read through a one-shot cat, the release a one-shot chown, then the fresh container"
      assert_equal K.cat_run_once_argv(tag: "t", home: home, path: K::RHO_LOG), calls[1]
      assert_includes calls, K.cat_argv("c", K::RHO_LOG), "the fresh container's log is read through its own exec"
      assert_equal 1, calls.count { |argv| argv.include?("--entrypoint") && argv.include?("cat") }, "one one-shot for the mark, none for the wait"

      calls.clear
      daemon.stop
      assert_equal [%w[docker logs c], %w[docker exec -u 0 c chown -R 501:20 /var/lib/rho], %w[docker rm -f c]], calls,
        "a running container is released through its own exec"
    end
  end

  # THE EVIDENCE OF A RED RUN (the box's chess run: a `lane bug` — the
  # restarted container never announced — whose dump held the WORLD's logs
  # alone: the container's stdout reaches `daemon.log` inside the home on
  # `stop`, and the teardown removes the home). `evidence` reads the
  # container's stdout (`docker logs`; an exited container answers it too)
  # and rho's structured log through the container — a one-shot once it
  # exited — and `save_evidence` writes both, redacted, beside the build
  # log as `<into>/<stem>.container.log` and `<stem>.rho.log`, never into
  # the home, answering the paths so the record can name them.
  def test_the_evidence_of_a_red_run_is_saved_beside_the_build_log_while_the_container_stands
    Dir.mktmpdir("evals-docker") do |home|
      secret = E2E::SecretHygiene.register("evidence-secret-#{SecureRandom.hex(6)}")
      calls = []
      alive = true
      docker = lambda do |argv|
        calls << argv
        case argv[1]
        when "logs" then ["rho server: booted, bearer #{secret}\n", Status.new(ok: true)]
        when "exec"
          next ["Error response from daemon: container c is not running\n", Status.new(ok: false)] unless alive

          [argv.last == K::RHO_LOG ? "event=executor.announced tools=9 address=runner boot=1\n" : "", Status.new(ok: true)]
        when "run"
          [argv.include?("cat") ? "event=executor.announced tools=9 address=runner boot=exited\n" : "", Status.new(ok: true)]
        else ["", Status.new(ok: true)]
        end
      end
      daemon = K::Daemon.new(base_url: "http://127.0.0.1:3999", home: home, name: "c", port: 47015, tag: "t", user: "0", docker: docker)
      into = File.join(home, "artifacts", "logs")

      files = K.save_evidence(daemon, into: into, stem: "t.chess.glm.nexus.1")
      assert_equal [File.join(into, "t.chess.glm.nexus.1.container.log"), File.join(into, "t.chess.glm.nexus.1.rho.log")], files
      assert_equal "rho server: booted, bearer [REDACTED]\n", File.read(files[0], encoding: Encoding::UTF_8), "the stdout, redacted"
      assert_equal "event=executor.announced tools=9 address=runner boot=1\n", File.read(files[1], encoding: Encoding::UTF_8)
      assert_equal [%w[docker logs c], K.cat_argv("c", K::RHO_LOG)], calls, "the stdout and the exec cat; no one-shot while the container answers"
      refute_path_exists File.join(home, "daemon.log"), "the evidence never writes into the home"

      calls.clear
      alive = false
      files = K.save_evidence(daemon, into: into, stem: "t.chess.glm.nexus.2")
      assert_equal "event=executor.announced tools=9 address=runner boot=exited\n", File.read(files[1], encoding: Encoding::UTF_8),
        "an exited container's log through a one-shot cat"
      assert_equal [%w[docker logs c], K.cat_argv("c", K::RHO_LOG), K.cat_run_once_argv(tag: "t", home: home, path: K::RHO_LOG)], calls
      assert_equal %w[t.chess.glm.nexus.1.container.log t.chess.glm.nexus.1.rho.log t.chess.glm.nexus.2.container.log t.chess.glm.nexus.2.rho.log],
        Dir.children(into).sort
    end
  end

  # THE STRUCTURED LOG IS THE CONTAINER'S TOO: `await_announced` (the
  # lane's readiness after the ceremony — `start_runner_rho!`,
  # `pair_runner!`) and `claims` read `log_text`, which for a container is
  # `docker exec … cat`, never the host path (root's 0600 in root's 0700
  # `log/` on a native-Linux host under a root family; the box's chess run
  # would have spent the whole patience there after the boot). A decoy on
  # the host path must never answer; a log not yet written is "" — the
  # base's shape — never a raise.
  def test_the_structured_log_is_read_through_the_container
    Dir.mktmpdir("evals-docker") do |home|
      calls = []
      container_log = "event=executor.announced tools=9 address=runner boot=1\nevent=runner_task_claimed task=tk-1 tool=shell deadline_at=t\n"
      docker = lambda do |argv|
        calls << argv
        next ["", Status.new(ok: true)] unless argv[1] == "exec" && argv.last == K::RHO_LOG

        container_log ? [container_log, Status.new(ok: true)] : ["cat: no such file\n", Status.new(ok: false)]
      end
      FileUtils.mkdir_p(File.join(home, "log"))
      File.write(File.join(home, "log", "rho.log"), "event=executor.announced tools=1 address=runner decoy=host\nevent=runner_task_claimed task=decoy\n")
      daemon = K::Daemon.new(base_url: "http://127.0.0.1:3999", home: home, name: "c", port: 47013, tag: "t", user: "0", docker: docker)

      assert_equal container_log, daemon.log_text, "the log is the container's, never the host path's"
      assert_equal K.cat_argv("c", K::RHO_LOG), calls.last, "the read is a docker exec"
      assert_equal %w[tk-1], daemon.claimed_keys
      daemon.await_announced(address: "runner")
      assert_empty calls.reject { |argv| argv == K.cat_argv("c", K::RHO_LOG) }, "nothing but the exec cat was issued"

      container_log = nil
      assert_equal "", daemon.log_text, "a log not written yet reads empty, never a raise"
    end
  end

  # A CONTAINER THAT EXITED BEFORE ANNOUNCING — a refused bind, a missing
  # verb — is a raise AT ONCE carrying its stdout, never a patience spent on
  # an announcement that will not come (the install GROUP's first world).
  # A docker that answers nothing to `inspect` (the recording ones above)
  # reads as running.
  def test_a_container_that_exited_before_announcing_raises_at_once_with_its_stdout
    Dir.mktmpdir("evals-docker") do |home|
      calls = []
      docker = lambda do |argv|
        calls << argv
        case argv[1]
        when "inspect" then ["false\n", Status.new(ok: true)]
        when "logs" then ["rho server: no transport assertion for a non-loopback bind.\n", Status.new(ok: true)]
        else ["", Status.new(ok: true)]
        end
      end
      daemon = K::Daemon.new(base_url: "http://127.0.0.1:3999", home: home, name: "c", port: 47009, tag: "t", docker: docker)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      error = assert_raises(RuntimeError) { daemon.start }
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5, "the exit was read at once, not after the patience"
      assert_match(/c exited before announcing itself; its stdout:\n.*no transport assertion/, error.message)
      # The announcement's exec (refused: the container is gone) is what a
      # read through the container costs before the inspect tells why.
      assert_equal %w[run exec inspect logs], calls.map { |argv| argv[1] }
      assert_equal K.cat_argv("c", K::ANNOUNCEMENT), calls[1]
    end
  end

  def test_a_failed_run_or_patch_raises_with_the_output
    Dir.mktmpdir("evals-docker") do |home|
      failing = ->(_argv) { ["no such image\n", Status.new(ok: false)] }
      daemon = K::Daemon.new(base_url: "http://127.0.0.1:1", home: home, name: "c", port: 1, tag: "t", task_dir: "/t", docker: failing)
      assert_match(/docker run c failed:\nno such image/, assert_raises(RuntimeError) { daemon.start }.message)
      assert_match(/git apply of environment\.patch failed in c/, assert_raises(RuntimeError) { daemon.apply_environment! }.message)
    end
  end

  # AN ANNOUNCEMENT THAT SAYS NOTHING is no announcement: a `null` document reads as absent, as the
  # host's read reads it, and `control` names that instead of reaching into nothing.
  def test_a_null_announcement_is_no_announcement
    Dir.mktmpdir("evals-docker") do |home|
      docker = ->(argv) { argv.last == K::ANNOUNCEMENT ? ["null", Status.new(ok: true)] : ["", Status.new(ok: true)] }
      daemon = K::Daemon.new(base_url: "http://127.0.0.1:3999", home: home, name: "c", port: 47001, tag: "t", docker: docker)
      error = assert_raises(RuntimeError) { daemon.control(:get, "/status") }
      assert_equal "the rho daemon has no announcement to address", error.message
    end
  end
end
