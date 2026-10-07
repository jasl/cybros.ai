require "test_helper"
require "support/live_journey"
require "json"

# A REAL MODEL DRIVES A REAL BROWSER, through rho's extension plane, and
# proves it by what it reads off the page — not by what it says.
#
# The page is nexus's own sign-in form, served by the e2e's own server:
# public, no login, and it has exactly the two labelled fields a model
# must READ to answer. A model that guesses "Email/Password" without
# looking gets it right by luck, so the task also asks for the page's
# <title>, which it cannot know without a snapshot.
#
# WHAT THIS PROVES that the unit tests cannot: the extension loads under
# the daemon from settings.json (not a builtin), the six declarations
# reach a real provider beside the coding seven, a real Chromium starts
# lazily on the first call and is closed on shutdown, and a flash-tier
# model can operate the [ref=eN] surface at all.
#
# Paid, local, opt-in: E2E_LIVE=1, plus a Node Playwright driver — the
# journey pins one with npx so the machine's global install can drift.
class LiveBrowserTest < Minitest::Test
  MODEL = ENV.fetch("E2E_LIVE_MODEL") { E2E::LiveJourney.default_model }.freeze
  DRIVER = ENV.fetch("RHO_BROWSER_PLAYWRIGHT_CLI", "npx -y playwright-core@1.62.1").freeze

  include E2E::LiveJourney

  def setup
    start_live_journey!(MODEL, home_prefix: "rho-live-browser-e2e",
      daemon_env: { "RHO_BROWSER_PLAYWRIGHT_CLI" => DRIVER })
    # THE EXTENSION IS WANTED, NOT MERELY INSTALLED. It is in the bundle;
    # nothing loads it until the operator's settings name it.
    File.write(File.join(@home, "settings.json"), JSON.generate(E2E::RhoDaemon.dev_settings(plugins: { "rho.browser" => { "enabled" => true } })), perm: 0o600)
  end

  def teardown = finish_live_journey!

  def test_a_real_model_reads_a_real_page_through_the_browser_tools
    connect_and_open_lane!

    # THE DAEMON SAYS WHAT IT LOADED, before a model is asked anything —
    # a failed extension is a product fact and reads here.
    listed, status = @daemon.cli("runner")
    assert_predicate status, :success?, "rho runner failed:\n#{listed}"
    assert_match(/extension:\s+rho\.browser/, listed, "the browser extension did not load:\n#{listed}")
    refute_match(/FAILED:/, listed, "an extension failed to load:\n#{listed}")

    project = File.join(@home, "project")
    FileUtils.mkdir_p(project)
    @daemon.control(:post, "/environment", body: { root: project })

    url = "#{@base_url}/session/new"
    task = <<~TEXT.strip
      Open #{url} in the browser and read the page.
      Write a file called page.json in the current directory containing a JSON
      object with two keys: "title" — the page's exact <title> text — and
      "fields" — an array of the visible labels of every text or password
      input on the page, in the order they appear. Nothing else. Reply DONE.
    TEXT

    output, status = @daemon.cli("do", task, "--model", MODEL, "--dir", project)
    assert_predicate status, :success?, "rho do failed:\n#{output}"
    run_public_id = output[/^run:\s+(\S+)/, 1]
    # That the browser tools were offered is proved by the completed browser call below: the 201
    # names no tools (the declaration is the profile's).

    completed = await_loop_completion(run_public_id)
    report(completed)
    assert_equal "completed", completed.fetch("status"),
      "the loop did not finish: #{summarize(completed)}"

    # IT LOOKED. A model that answered from memory never called a browser
    # tool, and that is the difference between a browser and a guess.
    # And it looked SUCCESSFULLY. A browser call whose driver failed
    # answers an ERROR RESULT — which the runner submits and the kernel
    # settles as `completed`, with `is_error` in its summary — so status
    # alone would let a failed navigate followed by a curl through bash
    # pass. The call that counts completed AND was not an error.
    browser_calls = completed.fetch("tasks").select do |t|
      t.fetch("kind") == "tool_task" && t.fetch("tool_name").start_with?("browser_") &&
        t.fetch("status") == "completed" && t.dig("result", "is_error") != true
    end
    refute_empty browser_calls, "no browser tool call completed"
    assert browser_calls.any? { |t| %w[browser_navigate browser_snapshot].include?(t.fetch("tool_name")) },
      "it never read the page through the browser: #{summarize(completed)}"

    # THE PROOF IS ON DISK, and it is the page's own words.
    written = File.join(project, "page.json")
    assert_path_exists written, "it never wrote page.json"
    # UTF-8 BY NAME. The test process inherits the harness's locale, which
    # on this machine is none — so a bare `File.read` tags the bytes
    # US-ASCII and the page's own title (it has a non-ASCII character)
    # fails to parse. Same defect the daemon had; same fix, said locally.
    document = JSON.parse(File.read(written, encoding: Encoding::UTF_8))
    assert_equal expected_title, document.fetch("title"),
      "the title it wrote is not the page's title"
    labels = Array(document.fetch("fields")).map { |l| l.to_s.strip.downcase }
    assert_includes labels, "email"
    assert_includes labels, "password"
  end

  private

    # The page's own title, read the boring way, so the assertion does not
    # hardcode a string the view could change — and read UNAUTHENTICATED,
    # which is how the model's fresh headless browser saw it. The first
    # version of this asked Capybara, whose session `setup` had already
    # signed in, and got redirected to "Dashboard · Nexus": the model was
    # right and the oracle was wrong.
    def expected_title
      uri = URI.join(@base_url, "/session/new")
      html = Net::HTTP.start(uri.hostname, uri.port) { |http| http.get(uri.path).body }
      html = html.dup.force_encoding(Encoding::UTF_8)
      raw = html[%r{<title>(.*?)</title>}m, 1]
      refute_nil raw, "no <title> on #{uri}"
      unescape_html(raw.strip)
    end

    # The five named entities Rails' escaper emits, plus numeric ones —
    # not `CGI`, which Ruby 4.0 removed.
    def unescape_html(text)
      named = { "&amp;" => "&", "&lt;" => "<", "&gt;" => ">", "&quot;" => '"' }
      text.gsub(/&(?:#x([0-9a-f]+)|#(\d+)|(amp|lt|gt|quot));/i) do
        if Regexp.last_match(1) then Regexp.last_match(1).to_i(16).chr(Encoding::UTF_8)
        elsif Regexp.last_match(2) then Regexp.last_match(2).to_i.chr(Encoding::UTF_8)
        else named.fetch(Regexp.last_match(0))
        end
      end
    end

    def report(row)
      tools = row.fetch("tasks").select { |t| t.fetch("kind") == "tool_task" }
      puts "\n--- live browser ---------------------------------------------"
      puts "model:  #{MODEL}"
      puts "status: #{row.fetch("status")}"
      puts "rounds: #{row.fetch("tasks").count { |t| t.fetch("kind") == "model_task" }}"
      puts "calls:  #{tools.size} (#{tools.map { |t| t["tool_name"] }.tally.map { |n, c| "#{n}x#{c}" }.join(" ")})"
      puts "--------------------------------------------------------------"
    end
end
