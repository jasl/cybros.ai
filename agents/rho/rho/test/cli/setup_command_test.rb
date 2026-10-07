require "test_helper"
require "open3"

class SetupCommandTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("rho-setup-command")
  end

  def teardown = FileUtils.remove_entry(@root)

  def test_builtin_setup_help_is_available_before_plugins_are_enabled
    output, status = run_command("help", "setup")
    assert status.success?, output
    assert_includes output, "--public-url"
    assert_includes output, "--finish"
    refute_path_exists File.join(@root, "telegram")
  end

  def test_noninteractive_setup_refuses_instead_of_reading_secrets_from_stdin
    output, status = run_command("setup")
    refute status.success?
    assert_includes output, "interactive terminal"
    refute_path_exists File.join(@root, "settings.json")
  end

  def test_runner_setup_is_explicitly_inapplicable
    File.write(File.join(@root, "settings.json"), JSON.generate("mode" => "runner"))
    output, status = run_command("setup")
    refute status.success?
    assert_includes output, "runner-only installations use rho connect"
  end

  def test_finish_without_enabled_telegram_is_a_quiet_success_without_a_tty
    output, status = run_command("setup", "telegram", "--finish")
    assert status.success?, output
    assert_equal "", output
    refute_path_exists File.join(@root, "telegram")
  end

  private

    def run_command(*args)
      Open3.capture2e({ "RHO_HOME" => @root, "RHO_NEXUS_URL" => nil, "RHO_MODE" => nil },
        Gem.ruby, File.expand_path("../../exe/rho", __dir__), *args)
    end
end
