require_relative "test_helper"

class ConfigTest < OperatorTest
  def test_saved_session_is_atomic_and_redacted_when_inspected
    saved_session
    assert_equal ["session.json"], Dir.children(@home)
    refute_includes @config.inspect, TOKEN
    refute_includes @config.read.inspect, TOKEN
  end

  def test_corrupt_session_has_a_safe_actionable_error
    File.write(File.join(@home, "session.json"), "{synthetic-secret")
    error = assert_raises(CybrosControl::Error) { @config.read }
    refute_includes error.message, "synthetic-secret"
  end

  def test_operator_urls_allow_home_servers_and_reject_embedded_credentials
    assert_equal "http://192.168.1.10:3300", CybrosControl::Config.base_url("http://192.168.1.10:3300/")
    assert_equal "https://nexus.example.test", CybrosControl::Config.base_url("https://nexus.example.test")
    %w[file:///tmp/nexus https://user:secret@example.test https://example.test/?key=secret https://example.test/#secret].each do |url|
      error = assert_raises(CybrosControl::UsageError) { CybrosControl::Config.base_url(url) }
      refute_includes error.message, "secret"
    end
  end
end
