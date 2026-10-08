require "test_helper"
require "support"

# THE DOOR IT COMES THROUGH is the door the built-ins use — and this is
# the first extension that is not the plane's own author.
class ExtensionTest < Minitest::Test
  def teardown = Rho::Browser.reset!

  def test_it_registers_six_tools_and_a_shutdown_hook_through_the_public_loader
    result = Rho::Runner::Extensions::Loader.call(builtin: [Rho::Browser])

    assert_predicate result, :ok?, result.failures.inspect
    assert_equal %w[browser_click browser_evaluate browser_navigate browser_screenshot
                    browser_snapshot browser_type], result.registry.names.sort
    assert_equal ["rho.browser"], result.registry.extension_names
    assert_predicate result.committed.fetch(0), :restart_only?

    hook = result.committed.flat_map(&:lifecycle).find { |h| h.event == :shutdown }
    refute_nil hook, "no shutdown hook; the browser would outlive its host"
    assert_equal "rho.browser", hook.extension
  end

  # Beside the coding built-ins, no name collides and the surface stays
  # small: six tools that together cost less than the eleven they join
  # (including `file_import` and `file_publish`; the person's `files_bytes`
  # and the kernel's `skill` are both described to nobody).
  def test_it_coexists_with_the_coding_built_ins_and_stays_small
    result = Rho::Runner::Extensions::Loader.call(
      builtin: [Rho::Runner::Extensions::Coding, Rho::Browser]
    )
    assert_predicate result, :ok?
    assert_equal 17, result.registry.names.size

    bytes = result.registry.declarations.group_by { |d| d["name"].start_with?("browser_") }
      .transform_values { |ds| ds.sum { |d| JSON.generate(d).bytesize } }
    assert_operator bytes.fetch(true), :<, bytes.fetch(false),
      "browser declarations (#{bytes[true]}) outweigh the coding eleven (#{bytes[false]})"
  end

  def test_the_shutdown_hook_closes_the_session_and_it_is_lazy_until_then
    driver = BrowserTest::FakeDriver.new
    Rho::Browser.driver_factory = -> { driver }
    result = Rho::Runner::Extensions::Loader.call(builtin: [Rho::Browser])
    hook = result.committed.flat_map(&:lifecycle).find { |h| h.event == :shutdown }

    assert_equal 0, driver.starts, "loading the extension must not spawn a browser"
    Rho::Runner::ExecutionContext.with(Rho::Runner::ExecutionContext.new) do
      Rho::Browser.session.with_page { |_p| }
    end
    assert_equal 1, driver.starts
    hook.handler.call
    assert_equal 1, driver.stops
  end

  def test_startup_checks_and_releases_the_browser_without_creating_a_browsing_session
    driver = BrowserTest::FakeDriver.new
    Rho::Browser.driver_factory = -> { driver }
    result = Rho::Runner::Extensions::Loader.call(builtin: [Rho::Browser])
    startup = result.committed.fetch(0).lifecycle.find { |hook| hook.event == :startup }

    startup.handler.call

    assert_equal 1, driver.starts
    assert_equal 1, driver.stops
    assert_empty driver.pages
    refute Rho::Browser.session.started?
  end

  def test_startup_failure_provides_repair_guidance_and_releases_the_failed_driver
    driver = BrowserTest::FakeDriver.new(fail_starts: 1)
    Rho::Browser.driver_factory = -> { driver }
    result = Rho::Runner::Extensions::Loader.call(builtin: [Rho::Browser])
    startup = result.committed.fetch(0).lifecycle.find { |hook| hook.event == :startup }

    error = assert_raises(Rho::Runner::Extensions::PrerequisiteError) { startup.handler.call }

    assert_includes error.message, "playwright install chromium"
    assert_includes error.message, "Playwright driver command"
    assert_includes error.message, "enable the plugin again"
    refute driver.started?
    assert_nil error.cause
  end

  # The shutdown hook fires BEFORE the pool drains, so a worker can still
  # dequeue a browser call while the host is going away. It must be
  # refused, not handed a fresh Session that launches a Chromium nothing
  # will close.
  def test_after_close_no_new_session_is_built
    Rho::Browser.driver_factory = -> { BrowserTest::FakeDriver.new }
    Rho::Browser.session
    Rho::Browser.close!
    assert_raises(Rho::Browser::Closed) { Rho::Browser.session }
    Rho::Browser.reset!
    assert_kind_of Rho::Browser::Session, Rho::Browser.session
  end

  def test_the_policy_reaches_the_instructions_as_guidelines
    result = Rho::Runner::Extensions::Loader.call(builtin: [Rho::Browser])
    guidelines = result.registry.prompt_fragments.flat_map { |f| f["guidelines"] }.uniq
    assert_equal Rho::Browser::Tools::GUIDELINES.length, guidelines.length,
      "guidelines should dedupe to one copy across the six tools"
    assert guidelines.any? { |g| g.include?("Refs belong to the latest snapshot") }
  end

  def test_the_idle_window_uses_the_plugin_configuration_and_reset_restores_the_default
    assert_equal Rho::Browser::Session::IDLE_SECONDS, Rho::Browser.idle_after
    api = Rho::Runner::Extensions::Api.new(extension_name: Rho::Browser::NAME,
      source: "test", configuration: { "idle_seconds" => 120 })
    Rho::Browser.register(api)
    assert_equal 120.0, Rho::Browser.idle_after
    Rho::Browser.reset!
    assert_equal Rho::Browser::Session::IDLE_SECONDS, Rho::Browser.idle_after
  end
end
