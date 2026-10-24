require "test_helper"
require "minitest/mock"
require "fileutils"
require "tmpdir"

# THE CHROME DRIVER IS RESOLVED OFFLINE FIRST: Selenium Manager re-resolves chromedriver over the
# network each time its one-hour metadata has expired, and a world boot sat minutes on that lookup
# before the steward's first page. A named driver (`E2E_CHROMEDRIVER`) wins; else Selenium Manager is
# asked offline for the driver its cache already holds for this Chrome, taken only when its major is
# the browser's; an empty answer — nothing cached — or a driver of another major names no service,
# which leaves Selenium's own online lookup exactly as it was. Driver resolution doubles the
# manager and uses scripts that answer `--version`; responsive layout runs in a local Chrome page.
# Screenshot waits execute their actual browser script under Bun with a controlled rendering clock.
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

  class ScreenshotPage
    attr_reader :captures, :settlement

    def initialize(frames)
      @frames = frames
      @captures = []
    end

    def evaluate_async_script(script, *arguments)
      output, errors, status = Open3.capture3("bun", "-e", <<~JAVASCRIPT, stdin_data: JSON.generate(script: script, arguments: arguments, frames: @frames))
        const input = await Bun.stdin.json();
        let now = 0, frame = -1, nextId = 0, calls = 0, result;
        const pending = new Map();
        const schedule = (callback, delay) => {
          const id = ++nextId;
          pending.set(id, { at: now + delay, callback });
          return id;
        };
        const current = () => input.frames[Math.min(frame, input.frames.length - 1)];
        globalThis.requestAnimationFrame = callback => schedule(() => { frame++; callback(now); }, 16);
        globalThis.cancelAnimationFrame = id => pending.delete(id);
        globalThis.setTimeout = schedule;
        globalThis.clearTimeout = id => pending.delete(id);
        globalThis.document = { getAnimations: () => current().animations.map(animation => ({
          playState: animation.state || "running",
          playbackRate: animation.rate ?? 1,
          effect: { getComputedTiming: () => ({ endTime: animation.end === "infinite" ? Infinity : animation.end }) },
        })) };
        new Function(input.script)(...input.arguments, value => { calls++; result = value; });
        for (let steps = 0; pending.size; steps++) {
          if (steps > 1000) throw new Error("screenshot wait did not terminate");
          const [id, task] = [...pending].sort((a, b) => a[1].at - b[1].at)[0];
          pending.delete(id);
          now = task.at;
          task.callback();
        }
        process.stdout.write(JSON.stringify({ result, calls, phase: current().phase, elapsed: now }));
      JAVASCRIPT
      raise errors unless status.success?

      @settlement = JSON.parse(output)
      @settlement.fetch("result")
    end

    def save_screenshot(path)
      @captures << { path: path, phase: @settlement&.fetch("phase") }
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

  def test_screenshot_waits_for_resize_and_following_finite_transitions
    page = ScreenshotPage.new([
      { phase: "resize-pending", animations: [] },
      { phase: "sidebar-closing", animations: [{ end: 300 }] },
      { phase: "sidebar-closed", animations: [] },
      { phase: "panel-opening", animations: [{ end: 200 }] },
      { phase: "settled", animations: [] },
    ])
    path = File.join(@dir, "screenshots", "narrow.png")

    A.new("http://example.test").stub(:page, page) { |actor| actor.save_screenshot(path) }

    assert_equal [{ path: path, phase: "settled" }], page.captures
    assert_equal 1, page.settlement.fetch("calls")
  end

  def test_resize_waits_for_the_responsive_grid_before_returning_control
    File.write(File.join(@dir, "resize.html"), <<~HTML)
      <!doctype html><html><head><style>
        body { margin: 0; }
        .frame { display: grid; grid-template-columns: var(--sidebar-width) minmax(0, 1fr); transition: grid-template-columns 1s; }
        main { grid-column: 2; }
      </style></head><body><div class="frame"><aside></aside><main>
        <button onclick="document.querySelector('output').textContent = 'opened'">Settings</button><output></output>
      </main></div><script>
        const frame = document.querySelector('.frame');
        const paint = () => frame.style.setProperty('--sidebar-width', innerWidth < 768 ? '0px' : '280px');
        addEventListener('resize', () => requestAnimationFrame(paint));
        paint();
      </script></body></html>
    HTML
    actor = A.new("file://#{@dir}/")
    actor.resize(390, 844)
    actor.visit("resize.html")
    assert_equal 0, actor.page.evaluate_script("document.querySelector('main').getBoundingClientRect().x")

    actor.resize(1400, 1000)

    assert_equal 280, actor.page.evaluate_script("document.querySelector('main').getBoundingClientRect().x"),
      "the sidebar transition is complete before the next interaction"
    actor.page.click_button "Settings"
    assert actor.page.has_css?("output", text: "opened")

    actor.resize(390, 844)

    assert_equal 0, actor.page.evaluate_script("document.querySelector('main').getBoundingClientRect().x"),
      "the narrow frame also settles before the next interaction"
  ensure
    actor&.close
  end

  def test_stable_or_endless_animations_do_not_block_a_screenshot
    page = ScreenshotPage.new([
      { phase: "stable", animations: [{ end: "infinite" }, { end: 300, state: "paused" }, { end: 300, rate: 0 }] },
    ])

    A.new("http://example.test").stub(:page, page) { |actor| actor.save_screenshot(File.join(@dir, "stable.png")) }

    assert_equal "stable", page.captures.fetch(0).fetch(:phase)
    assert_equal 1, page.settlement.fetch("calls")
  end

  def test_a_finite_animation_that_never_settles_refuses_the_screenshot_within_the_bound
    page = ScreenshotPage.new([{ phase: "still-moving", animations: [{ end: 60_000 }] }])

    error = assert_raises(Timeout::Error) do
      A.new("http://example.test").stub(:page, page) { |actor| actor.save_screenshot(File.join(@dir, "moving.png")) }
    end

    assert_match(/animations did not settle/, error.message)
    assert_empty page.captures
    assert_equal 1, page.settlement.fetch("calls")
    assert_operator page.settlement.fetch("elapsed"), :<=, 5_000
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
