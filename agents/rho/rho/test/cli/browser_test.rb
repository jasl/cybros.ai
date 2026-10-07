require "test_helper"
require "stringio"

# THE ONE BROWSER LAUNCHER: `$BROWSER` is the
# opener when set — the URL in place of `%s`, appended otherwise — else
# the platform's; a spawn that fails prints and returns, never raises.
class CliBrowserTest < Minitest::Test
  RECORDER = File.expand_path("../support/browser_recorder.rb", __dir__)

  def test_browser_with_a_slot_gets_the_url_in_place_of_it
    assert_equal ["firefox", "--new-tab", "https://x/#a b", "--"],
      Rho::Cli::Browser.command("https://x/#a b", env: { "BROWSER" => "firefox --new-tab %s --" })
  end

  def test_browser_without_a_slot_gets_the_url_appended_after_a_shell_split
    assert_equal ["/Applications/My Browser.app/Contents/MacOS/browser", "-p", "work", "https://x/"],
      Rho::Cli::Browser.command("https://x/", env: { "BROWSER" => "'/Applications/My Browser.app/Contents/MacOS/browser' -p work" })
  end

  def test_an_unset_or_blank_browser_falls_to_the_platforms_opener
    assert_equal ["open", "https://x/"], Rho::Cli::Browser.command("https://x/", env: {}, host_os: "darwin25")
    assert_equal ["xdg-open", "https://x/"], Rho::Cli::Browser.command("https://x/", env: { "BROWSER" => "  " }, host_os: "linux")
  end

  def test_launch_spawns_the_opener_detached_with_the_url_last
    Dir.mktmpdir("rho-browser") do |dir|
      record = File.join(dir, "opened")
      env = { "BROWSER" => "#{Gem.ruby} #{RECORDER} #{record}" }
      out = StringIO.new
      assert Rho::Cli::Browser.launch("https://x/#code=1", env: env, out: out)
      assert_equal "", out.string, "a launch that worked prints nothing"
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      sleep 0.05 until File.exist?(record) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      assert_equal "https://x/#code=1", File.read(record), "the opener ran with the URL"
    end
  end

  def test_a_missing_opener_prints_and_returns
    out = StringIO.new
    refute Rho::Cli::Browser.launch("https://x/", env: { "BROWSER" => "/nonexistent/opener-#{Process.pid}" }, out: out)
    assert_equal "(could not launch a browser: Errno::ENOENT — the URL above still works)\n", out.string
  end
end
