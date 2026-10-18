require "test_helper"
require "support/install_lane"
require "open3"

# THE HOST LANE OF THE `install` GROUP: THE INSTALLER ITSELF, on this host, into a temporary prefix
# with a temporary home and launcher dir (`install/install.sh --profile full` from this checkout —
# the portable Ruby, the gems, the tool rows: the network and minutes), then `rho version`, `rho
# doctor --strict`, and the installed `bin/rho` as a RUNNER paired with the harness's Nexus serving
# one tool call; `rho uninstall` at the end. LOCAL-ONLY and opt-in (`E2E_INSTALL_HOST=1`;
# `RHO_INSTALL_TEST_CACHE` keeps the downloads between runs): in CI and unset it SKIPS with its
# reason, and a SKIP is never a pass — the ubuntu row of the Linux host closes in CI's e2e job
# through the container lane, the macOS row here by hand. The update ladder and the rollback stay
# `install/test/install_test.sh`'s.
class InstallHostTest < Minitest::Test
  include E2E::InstallLane

  INSTALLER = File.expand_path("../../install/install.sh", __dir__)
  OPT_IN = "E2E_INSTALL_HOST".freeze
  CACHE = "RHO_INSTALL_TEST_CACHE".freeze

  # The installed rho, spawned from its prefix's wrapper — no bundle, no
  # checkout: the launcher a person gets.
  class InstalledRhoDaemon < E2E::RhoDaemon
    def initialize(base_url:, home:, prefix:, user_home:)
      super(base_url: base_url, home: home, env: { "RHO_MODE" => "runner", "HOME" => user_home })
      @rho = File.join(prefix, "bin", "rho")
    end

    def start
      @pid = E2E::ProcessRegistry.spawn(@env.merge("RHO_HOME" => @home), @rho, "server", "--nexus-url", @base_url,
        chdir: @home, out: [@log_path, "a"], err: [@log_path, "a"], pgroup: true)
      await("the installed rho never announced itself") do
        document = announcement
        document && document["endpoint"] ? document : nil
      end
    end

    def cli(*arguments)
      output, status = Open3.capture2e(@env.merge("RHO_HOME" => @home), @rho, *arguments, "--nexus-url", @base_url, chdir: @home)
      [output.to_s.force_encoding(Encoding::UTF_8).scrub, status]
    end

    def cli_background(*) = raise(NotImplementedError, "the host lane streams nothing")
  end

  def setup
    skip "install_host: local-only and opt-in — #{OPT_IN}=1 runs the installer into a temporary prefix (network, minutes); " \
         "a SKIP is never a pass" unless ENV[OPT_IN] == "1"
    skip "install_host: never in CI (the container lane closes the Linux host row there)" if ENV["CI"].to_s == "true"

    install_lane_setup!(home_prefix: "rho-install-host-e2e")
    @prefix = Dir.mktmpdir("rho-install-host-prefix")
    @launcher = Dir.mktmpdir("rho-install-host-launcher")
    @install_user_home = Dir.mktmpdir("rho-install-host-user")
  end

  def teardown
    install_lane_teardown!
  ensure
    [@prefix, @launcher, @install_user_home].each { |dir| FileUtils.remove_entry(dir) if dir && File.directory?(dir) }
  end

  def test_the_installer_puts_a_rho_on_this_host_that_pairs_and_serves_one_call
    install_home = File.join(@runner_home, "installed-home")
    installed_env = { "RHO_HOME" => install_home, "HOME" => @install_user_home }
    env = installed_env.merge("RHO_PREFIX" => @prefix, "RHO_LAUNCHER_DIR" => @launcher, "NONINTERACTIVE" => "1",
            "RHO_DOWNLOAD_CACHE" => ENV.fetch(CACHE, File.join(@prefix, "cache", "downloads")),
            "RHO_NO_BOOTSNAP" => nil, "RHO_MODIFY_PATH" => nil, "RHO_SOURCE" => nil, "RHO_PROFILE" => nil)
    output, status = Open3.capture2e(env, "/bin/bash", INSTALLER, "--profile", "full")
    assert_predicate status, :success?, "install.sh --profile full:\n#{output.lines.last(40).join}"
    assert_includes output, "Installation successful", output.lines.last(10).join
    rho = File.join(@prefix, "bin", "rho")
    assert File.executable?(rho), "the prefix has no bin/rho"
    assert_equal rho, File.readlink(File.join(@launcher, "rho")), "the launcher points at the prefix"

    version, status = Open3.capture2e(installed_env, rho, "version")
    assert_predicate status, :success?, version
    assert_match(/\A\d+\.\d+\.\d+/, version, "rho version through the wrapper")
    doctor, status = Open3.capture2e(installed_env, rho, "doctor", "--strict")
    assert_predicate status, :success?, "rho doctor --strict:\n#{doctor}"
    assert_includes doctor, "0 failures", doctor
    assert_includes doctor, "profile full", doctor
    assert_tls_store_ok!(doctor) { |path| File.readable?(path) }

    runner_id = pair_runner!(InstalledRhoDaemon.new(base_url: @base_url, home: install_home, prefix: @prefix,
      user_home: @install_user_home))
    workspace_public_id = boot_agent_rho!
    read_through_runner!(workspace_public_id, runner_id, File.join(@tests, "note.txt"))

    @runner.stop
    removed, status = Open3.capture2e(installed_env, rho, "uninstall")
    assert_predicate status, :success?, "rho uninstall:\n#{removed}"
    refute_path_exists @prefix, "the prefix survived uninstall"
    refute_path_exists File.join(@launcher, "rho"), "the launcher survived uninstall"
    assert_path_exists install_home, "uninstall removed RHO_HOME without --purge"
  end
end
