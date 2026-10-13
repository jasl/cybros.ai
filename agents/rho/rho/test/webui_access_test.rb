require "test_helper"

# Asset: the gate in front of the WebUI. Its mode follows the bind unless
# set, its password is a salted digest with a monotonic generation, and a
# run of wrong guesses is held off for a window.
class WebuiAccessTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("rho-access")
    @home = Rho::Home.resolve(base_url: "https://nexus.example", root: @root)
    @now = Time.utc(2026, 10, 9, 12, 0, 0)
  end

  def teardown = FileUtils.remove_entry(@root)

  def access(bind: "127.0.0.1", **settings)
    Rho::WebuiAccess.new(home: @home, config: Rho::Config.from_hash(settings, home: @home), bind: bind, clock: -> { @now })
  end

  def test_the_mode_follows_the_bind_unless_the_setting_chooses
    assert_equal "open", access.mode
    assert_equal "open", access(bind: "::1").mode
    assert_equal "nexus", access(bind: "0.0.0.0").mode
    assert_equal "nexus", access(bind: "10.0.0.115").mode
    assert_equal "password", access(bind: "127.0.0.1", "webui_access" => "password").mode
    assert_equal "open", access(bind: "0.0.0.0", "webui_access" => "open").mode
    assert_nil access.configured
    assert_equal({ mode: "nexus", configured: nil, password_set: false }, access(bind: "0.0.0.0").describe)
    error = assert_raises(Rho::ConfigurationError) { Rho::Config.from_hash({ "webui_access" => "anyone" }, home: @home) }
    assert_includes error.message, "webui_access must be one of open, nexus, password"
  end

  def test_the_password_is_a_salted_digest_whose_generation_advances_on_every_set_and_clear
    gate = access("webui_access" => "password")
    assert_equal 0, gate.generation
    assert_equal :password_not_set, gate.unlock("anything").code
    assert_raises(Rho::ConfigurationError) { gate.set_password("1234567") }
    assert gate.set_password("a passphrase")
    assert_equal 1, gate.generation
    assert gate.password_set?
    document = JSON.parse(File.read(@home.webui_password_path))
    assert_equal %w[N algorithm digest generation length p r salt], document.keys.sort
    refute_includes document.values.map(&:to_s).join, "a passphrase"
    assert_equal :accepted, gate.unlock("a passphrase").code
    assert_equal :refused, gate.unlock("A passphrase").code
    assert gate.set_password("another one")
    assert_equal 2, gate.generation
    assert_equal :refused, gate.unlock("a passphrase").code
    refute gate.set_password(nil)
    assert_equal 3, gate.generation
    refute gate.password_set?
    assert_equal :password_not_set, gate.unlock("another one").code
  end

  def test_open_and_nexus_modes_answer_without_a_password_and_wrong_guesses_are_held_off
    assert_equal :accepted, access.unlock(nil).code
    assert_equal :nexus_login_required, access(bind: "0.0.0.0").unlock("whatever").code

    gate = access("webui_access" => "password")
    gate.set_password("the real one")
    Rho::WebuiAccess::MAX_ATTEMPTS.times { assert_equal :refused, gate.unlock("nope").code }
    held = gate.unlock("the real one")
    assert_equal :throttled, held.code, "the window holds the right password off too"
    assert_equal Rho::WebuiAccess::ATTEMPT_WINDOW, held.retry_after
    @now += 30
    assert_equal 30, gate.unlock("the real one").retry_after
    @now += 31
    assert_equal :accepted, gate.unlock("the real one").code
  end
end
