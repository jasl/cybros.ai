require "test_helper"
require "minitest/mock"
require "support/install_lane"

class InstallLaneHarnessTest < Minitest::Test
  include E2E::InstallLane

  Docker = E2E::Evals::Docker
  Status = Data.define(:ok) do
    def success? = ok
  end
  Page = Data.define do
    def has_text?(text) = text == "Dashboard"
  end
  Speaker = Data.define(:page) do
    def visit(_path); end
  end
  World = Data.define(:rho_steward)
  Hosts = Data.define do
    def start; end
  end

  def teardown = install_lane_teardown!

  def test_host_setup_keeps_the_runner_home_private_without_docker
    Docker.stub(:run!, ->(*) { flunk "host installation must not require Docker" }) do
      with_world { install_lane_setup!(home_prefix: "install-home-harness") }
      assert_equal 0o700, File.stat(@runner_home).mode & 0o777
      assert_equal Process.uid, File.stat(@runner_home).uid
      install_lane_teardown!
    end
  end

  def test_container_setup_hands_the_private_home_to_the_image_and_returns_it_without_a_daemon
    calls = []
    Docker.stub(:run!, ->(argv) { calls << argv; ["", Status.new(ok: true)] }) do
      with_world { install_lane_setup!(home_prefix: "install-home-harness", container_image: "installed-rho") }
      home = @runner_home
      assert_equal 0o700, File.stat(home).mode & 0o777
      assert_equal [Docker.run_once_argv(tag: "installed-rho", home: home,
        command: ["chown", "1000:1000", Docker::HOME])], calls

      install_lane_teardown!
      assert_equal Docker.release_home_run_once_argv(tag: "installed-rho", home: home), calls.last
      refute_path_exists home
    end
  end

  def test_a_failed_owner_change_stops_setup_and_still_releases_the_home
    calls = []
    Docker.stub(:run!, ->(argv) { calls << argv; ["chown refused", Status.new(ok: calls.length > 1)] }) do
      error = assert_raises(RuntimeError) do
        with_world { install_lane_setup!(home_prefix: "install-home-harness", container_image: "installed-rho") }
      end
      assert_includes error.message, "chown refused"
      home = @runner_home
      install_lane_teardown!
      assert_equal Docker.release_home_run_once_argv(tag: "installed-rho", home: home), calls.last
      refute_path_exists home
    end
  end

  private

    def with_world(&block)
      E2E.stub(:base_url, "http://127.0.0.1:1") do
        E2E::ActorProvisioning.stub(:world, World.new(rho_steward: nil)) do
          E2E::StewardSession.stub(:actor, Speaker.new(page: Page.new)) do
            E2E.stub(:enable_dev_lane!, nil) do
              E2E.stub(:hosts, Hosts.new, &block)
            end
          end
        end
      end
    end
end
