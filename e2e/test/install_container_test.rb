require "test_helper"
require "support/install_lane"

# The prebuilt installation image must pass `rho doctor --strict`, pair as a runner with the harness
# Nexus, and serve a file read that only the container can answer. The journey runs against a
# bind-mounted home and observes the runner through its normal CLI and claim log. Missing Docker or
# a missing image is an explicit skip; this journey never builds an image inside the gate.
class InstallContainerTest < Minitest::Test
  include E2E::InstallLane

  def setup
    reason = E2E::InstallLane.docker_reason || E2E::InstallLane.image_reason
    skip "install_container: #{reason}" if reason

    install_lane_setup!(home_prefix: "rho-install-container-e2e", container_image: E2E::InstallLane.image)
  end

  def teardown = install_lane_teardown!

  def test_the_pre_built_image_pairs_as_a_runner_and_serves_one_tool_call
    image = E2E::InstallLane.image
    assert_doctor_green_in!(image)

    docker = E2E::Evals::Docker
    runner_id = pair_runner!(docker::Daemon.new(base_url: @base_url, home: @runner_home, name: "rho-install-container-#{Process.pid}",
      port: docker.free_port, tag: image, task_dir: @tests, network: docker.network_for))

    # The verbs a person types against the container, through `docker exec`:
    # the mode, the runner row serving its tools.
    reported, status = @runner.cli("status")
    assert_predicate status, :success?, reported
    assert_match(/^mode:      runner$/, reported, reported)
    assert_match(/^runner:    #{Regexp.escape(runner_id)} serving \d+ tools/, reported, reported)

    workspace_public_id = boot_agent_rho!
    read_through_runner!(workspace_public_id, runner_id, File.join(docker::TESTS, "note.txt"))
  end
end
