# THE ONE WARNING IN EVERY LANE is capybara's, not ours: capybara 3.40.0
# lib/capybara/session/config.rb:95 (`default_host=` →
# `URI::DEFAULT_PARSER.make_regexp`, obsolete under Ruby 4.0's `uri`) fires
# at gem load (capybara.rb:503) under -w. Nothing in nexus, agents, sdks or
# nexus/vendor calls `make_regexp`, so $VERBOSE is held nil around this one
# require. Drop this when a capybara release uses `URI::RFC2396_PARSER`.
begin
  verbose, $VERBOSE = $VERBOSE, nil
  require "capybara"
ensure
  $VERBOSE = verbose
end
require "fileutils"
require "open3"
require "selenium-webdriver"
require "uri"

module E2E
  Capybara.register_driver :e2e_headless_chrome do |app|
    options = Selenium::WebDriver::Chrome::Options.new
    options.binary = ENV["E2E_CHROME_BINARY"] if ENV["E2E_CHROME_BINARY"]
    options.logging_prefs = { browser: "ALL" }
    [
      "--headless=new",
      "--window-size=1400,1400",
      "--allow-pre-commit-input",
      "--disable-features=PaintHolding",
      "--disable-renderer-backgrounding",
      "--disable-backgrounding-occluded-windows",
      "--disable-background-timer-throttling",
      "--disable-ipc-flooding-protection",
    ].each { |argument| options.add_argument(argument) }

    driver_options = { browser: :chrome, options: options }
    path = BrowserActor.chromedriver_path
    driver_options[:service] = Selenium::WebDriver::Service.chrome(path: path) if path

    Capybara::Selenium::Driver.new(app, **driver_options)
  end

  # CAPYBARA'S DEFAULT WAIT IS TWO SECONDS, which is the right number for an
  # in-process test app and the wrong one for this. Here a real browser drives
  # a DEVELOPMENT-mode Rails on a machine that is simultaneously running Puma,
  # a queue host, a model runner and a fake provider — and the ceremonies wait
  # on responses that verify bcrypt at full cost. A page visit measures around
  # 800ms when the machine is quiet, so two seconds is under three times the
  # quiet case, which is not a budget: it is a coin toss the moment anything
  # else is running.
  #
  # This is not a fix for any known race. Every wait in this harness is on a
  # deterministic condition already; what was never set is how long the harness
  # is willing to wait for one.
  Capybara.default_max_wait_time = 10

  # The real-browser actor for the device-flow human leg. Chrome owns cookies, redirects, CSRF form
  # state, and browser fetch headers.
  class BrowserActor
    # THE DRIVER, RESOLVED OFFLINE FIRST, once per process: Selenium Manager re-resolves chromedriver
    # over the network each time its one-hour metadata has expired, and a world boot waited minutes
    # on that lookup before the steward's first page. nil names no service, which leaves the
    # resolution to Selenium's own online lookup, as before.
    def self.chromedriver_path
      return @chromedriver_path if defined?(@chromedriver_path)

      @chromedriver_path = resolve_chromedriver
    end

    # `E2E_CHROMEDRIVER` names a driver outright; else Selenium Manager is asked, `--offline`, for
    # the driver its cache already holds for this Chrome (`E2E_CHROME_BINARY`'s when one is named),
    # taken only when its major is the browser's. Offline, an empty cache answers an empty path,
    # and a cache with no driver for this Chrome's major answers its newest driver of ANOTHER major,
    # which chromedriver refuses a session with — and which, taken, would keep the online lookup
    # from ever fetching the right one. Either way nil, a download never.
    def self.resolve_chromedriver(env: ENV, manager: Selenium::WebDriver::SeleniumManager)
      return env["E2E_CHROMEDRIVER"] if env["E2E_CHROMEDRIVER"]

      arguments = %w[--browser chrome --offline]
      arguments += ["--browser-path", env["E2E_CHROME_BINARY"]] if env["E2E_CHROME_BINARY"]
      driver, browser = manager.binary_paths(*arguments).values_at("driver_path", "browser_path").map(&:to_s)
      major = major_version(browser) unless driver.empty? || browser.empty?
      driver if major && major == major_version(driver)
    end

    # The major a Chrome or chromedriver binary reports on `--version` ("Google Chrome
    # 154.0.8037.59", "ChromeDriver 154.0.8037.92 (…)"), nil when it cannot say.
    def self.major_version(path)
      output, _errors, status = Open3.capture3(path, "--version")
      output[/(\d+)\.\d+\.\d+\.\d+/, 1] if status.success?
    rescue SystemCallError
      nil
    end

    attr_reader :page

    def initialize(base_url)
      @base_url = base_url
      @page = Capybara::Session.new(:e2e_headless_chrome)
    end

    def visit(location)
      page.visit(absolute_url(location))
    end

    def save_screenshot(path)
      FileUtils.mkdir_p(File.dirname(path))
      page.save_screenshot(path)
    end

    def console_logs
      page.driver.browser.logs.get(:browser).map(&:as_json)
    end

    def close
      page.quit
    end

    private

      def absolute_url(location)
        uri = URI(location)
        if uri.absolute?
          uri.to_s
        else
          URI.join("#{@base_url}/", location.to_s.delete_prefix("/")).to_s
        end
      end
  end
end
