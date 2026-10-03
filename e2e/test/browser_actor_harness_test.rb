require "test_helper"
require "minitest/mock"
require "fileutils"
require "tmpdir"

# THE CHROME DRIVER IS RESOLVED OFFLINE FIRST: Selenium Manager re-resolves chromedriver over the
# network each time its one-hour metadata has expired, and a world boot sat minutes on that lookup
# before the steward's first page. A named driver (`E2E_CHROMEDRIVER`) wins; else Selenium Manager is
# asked offline for the driver its cache already holds for this Chrome, taken only when its major is
# the browser's; an empty answer — nothing cached — or a driver of another major names no service,
# which leaves Selenium's own online lookup exactly as it was. Nothing launches a browser: the
# manager is doubled, the two binaries are scripts that answer `--version`, and the driver only built.
class BrowserActorHarnessTest < Minitest::Test
  A = E2E::BrowserActor

  # Selenium Manager, doubled: it answers one driver path and one browser path and keeps the
  # arguments it was asked with.
  class ManagerDouble
    attr_reader :arguments

    def initialize(driver_path, browser_path)
      @driver_path = driver_path
      @browser_path = browser_path
    end

    def binary_paths(*arguments)
      @arguments = arguments
      { "driver_path" => @driver_path, "browser_path" => @browser_path }
    end
  end

  def setup
    @dir = Dir.mktmpdir("browser-actor")
    @chrome = binary("chrome", "Google Chrome 154.0.8037.59 ")
    @driver = binary("chromedriver", "ChromeDriver 154.0.8037.92 (334b65d2-refs/branch-heads/8037@{#1589})")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_a_named_driver_wins_and_the_manager_is_never_asked
    manager = ManagerDouble.new(@driver, @chrome)
    assert_equal "/opt/chromedriver", A.resolve_chromedriver(env: { "E2E_CHROMEDRIVER" => "/opt/chromedriver" }, manager: manager)
    assert_nil manager.arguments
  end

  def test_the_cached_driver_is_read_offline
    manager = ManagerDouble.new(@driver, @chrome)
    assert_equal @driver, A.resolve_chromedriver(env: {}, manager: manager)
    assert_equal %w[--browser chrome --offline], manager.arguments, "no network: the cache answers or nothing does"

    binary = ManagerDouble.new(@driver, @chrome)
    A.resolve_chromedriver(env: { "E2E_CHROME_BINARY" => @chrome }, manager: binary)
    assert_equal ["--browser", "chrome", "--offline", "--browser-path", @chrome], binary.arguments, "the driver for the Chrome the lane runs"
  end

  # CHROME UPDATED PAST EVERY CACHED DRIVER: offline, Selenium Manager answers the newest driver its
  # cache holds whatever its major, and chromedriver refuses a session with a Chrome of another
  # major. Online, the lookup would have fetched the matching driver; offline it never would, so the
  # boot would fail on every run until the cache was mended by hand.
  def test_a_cached_driver_of_another_major_leaves_selenium_its_own_lookup
    older = binary("chromedriver-153", "ChromeDriver 153.0.8010.52 (e0d4b1a3-refs/branch-heads/8010@{#1201})")
    assert_nil A.resolve_chromedriver(env: {}, manager: ManagerDouble.new(older, @chrome))
    assert_nil A.resolve_chromedriver(env: {}, manager: ManagerDouble.new(@driver, File.join(@dir, "no-chrome"))),
      "a browser that cannot say its version cannot vouch for a driver"
  end

  def test_nothing_cached_leaves_selenium_its_own_lookup
    assert_nil A.resolve_chromedriver(env: {}, manager: ManagerDouble.new("", @chrome))
    unnamed = A.stub(:chromedriver_path, nil) { Capybara.drivers[:e2e_headless_chrome].call(nil) }
    refute unnamed.options.key?(:service), "no service named: Selenium resolves the driver as it always did"
    named = A.stub(:chromedriver_path, "/cache/chromedriver") { Capybara.drivers[:e2e_headless_chrome].call(nil) }
    assert_equal "/cache/chromedriver", named.options.fetch(:service).executable_path
  end

  private

    # A binary that answers `--version` the way Chrome and chromedriver do.
    def binary(name, version)
      path = File.join(@dir, name)
      File.write(path, "#!/bin/sh\necho '#{version}'\n")
      File.chmod(0o755, path)
      path
    end
end
