require_relative "test_helper"

class NativeEnvironmentTest < Minitest::Test
  def test_native_state_is_private_and_existing_native_settings_remain_authoritative
    Dir.mktmpdir do |root|
      native = Rho::T3::NativeEnvironment.new(root: File.join(root, "plugin"), work_root: File.join(root, "work"))
      native.prepare
      path = File.join(native.server_root, "userdata", "settings.json")
      settings = JSON.parse(File.read(path))
      assert_equal native.codex_root, settings.dig("providerInstances", "codex", "config", "homePath")
      assert_equal native.claude_root, settings.dig("providerInstances", "claudeAgent", "config", "homePath")
      assert_equal 0o700, File.stat(native.root).mode & 0o777
      Rho::StateFile.new(path).write({ "nativeEdit" => true })
      native.prepare
      assert_equal({ "nativeEdit" => true }, JSON.parse(File.read(path)))
    end
  end

  def test_child_environment_preserves_home_and_only_explicit_provider_secrets
    native = Rho::T3::NativeEnvironment.new(root: "/rho/plugins/rho.t3", work_root: "/work")
    env = native.environment(ENV.to_h.merge("OPENAI_API_KEY" => "fixture-key",
      "RHO_T3_TOKEN" => "fixture-bearer", "BUNDLE_GEMFILE" => "private"))
    assert_equal ENV.fetch("HOME"), env.fetch("HOME")
    assert_equal "fixture-key", env.fetch("OPENAI_API_KEY")
    assert_equal "/rho/plugins/rho.t3/codex", env.fetch("CODEX_HOME")
    refute env.key?("RHO_T3_TOKEN")
    refute env.key?("BUNDLE_GEMFILE")
  end
end
