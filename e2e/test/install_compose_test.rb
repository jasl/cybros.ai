require "test_helper"
require "support/install_lane"
require "yaml"

# THE COMPOSE LANE OF THE `install` GROUP: the shipped `install/docker/compose.yml` brings the
# PRE-BUILT image up as `rho-runner` — an override file names the local image instead of the ghcr
# tag (verification never publishes an image), publishes the control port on the host's loopback and
# binds the home to a host dir so the harness reads the announcement and walks the ceremony — then
# ONE tool call through the container, the ORPHAN COUNT BEFORE THE STOP (a double-forked sleep whose
# group leader died: tini reaps it, zero zombies), and `docker compose stop` inside the file's own
# 30 s grace period. A SKIP — no docker, no compose, no image — names its reason and is never a
# pass.
class InstallComposeTest < Minitest::Test
  include E2E::InstallLane

  COMPOSE_FILE = File.expand_path("../../install/docker/compose.yml", __dir__)
  SERVICE = "rho-runner".freeze
  GRACE_SECONDS = 30

  # `docker compose` over the shipped file plus the override; every other
  # verb through `docker exec` on the container compose names.
  class ComposeDaemon < E2E::Evals::Docker::Daemon
    attr_reader :project, :override

    def initialize(project:, override:, **rest)
      super(**rest, name: "#{project}-#{SERVICE}-1")
      @project = project
      @override = override
    end

    def compose_argv(*verb) = ["docker", "compose", "-p", @project, "-f", COMPOSE_FILE, "-f", @override, *verb]

    def run_argv = compose_argv("up", "-d", SERVICE)

    # `stop` inside the grace period is the lane's own assertion; `down -v`
    # removes what `up` made (the named volumes the file declares).
    def stop
      output, = @docker.call(E2E::Evals::Docker.logs_argv(@name))
      release_home!
      File.write(@log_path, output.to_s, mode: "a", encoding: Encoding::UTF_8)
      @docker.call(compose_argv("down", "-v", "--remove-orphans"))
      nil
    end
  end

  def setup
    reason = E2E::InstallLane.compose_reason || E2E::InstallLane.image_reason
    skip "install_compose: #{reason}" if reason

    install_lane_setup!(home_prefix: "rho-install-compose-e2e", container_image: E2E::InstallLane.image)
  end

  def teardown = install_lane_teardown!

  def test_compose_brings_the_runner_up_serves_one_call_and_stops_inside_the_grace_with_no_orphans
    docker = E2E::Evals::Docker
    port = docker.free_port
    network = docker.network_for
    override = write_override!(image: E2E::InstallLane.image, port: port, network: network)
    daemon = ComposeDaemon.new(base_url: @base_url, home: @runner_home, port: port, tag: E2E::InstallLane.image, task_dir: @tests,
      network: network, project: "rho-install-compose-#{Process.pid}", override: override)
    runner_id = pair_runner!(daemon)

    # `docker compose exec rho-runner rho status`: the door the README names.
    reported, status = docker.run!(daemon.compose_argv("exec", "-T", SERVICE, "rho", "status", "--nexus-url",
      docker.nexus_url_from_container(@base_url, network: network)))
    assert_predicate status, :success?, reported
    assert_match(/^mode:      runner$/, reported, reported)

    workspace_public_id = boot_agent_rho!
    read_through_runner!(workspace_public_id, runner_id, File.join(docker::TESTS, "note.txt"))

    # The shipped file's `init: true`: docker-init is PID 1, the image's tini
    # its child, the orphan reaped either way.
    processes = assert_no_orphans_before_stop!(daemon.name, init: "docker-init")
    assert_match(/^\s*\d+\s+1\s+\S+\s+tini$/, processes, "the image's tini runs under docker-init:\n#{processes}")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    output, status = docker.run!(daemon.compose_argv("stop", "-t", GRACE_SECONDS.to_s, SERVICE))
    seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_predicate status, :success?, "docker compose stop:\n#{output}"
    assert_operator seconds, :<, GRACE_SECONDS, "docker compose stop took #{seconds.round(1)} s: TERM did not reach rho through tini"
  end

  private

    # The override: the local image, the control port published (or the
    # host's network on Linux, where the harness's loopback Nexus is
    # reachable no other way), the home bound to the lane's dir, the marker
    # file at /tests and the server's transport flags as the evals leg spells them.
    def write_override!(image:, port:, network:)
      docker = E2E::Evals::Docker
      host = network == docker::HOST_NETWORK
      service = {
        "image" => image,
        "volumes" => ["#{@runner_home}:#{docker::HOME}", "#{@tests}:#{docker::TESTS}:ro"],
        "command" => ["server", "--bind", (host ? docker::LOOPBACK : docker::ANY), "--port", port.to_s,
                      "--nexus-url", docker.nexus_url_from_container(@base_url, network: network), *(host ? [] : ["--unsafe-plaintext"])],
        "restart" => "no",
      }
      service = host ? service.merge("network_mode" => "host", "extra_hosts" => []) :
        service.merge("ports" => ["#{docker::LOOPBACK}:#{port}:#{port}"])
      path = File.join(@tests, "compose.override.yml")
      File.write(path, YAML.dump({ "services" => { SERVICE => service } }))
      path
    end
end
