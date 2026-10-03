require "test_helper"

# Opening the page: the one path a browser credential travels.
class ConsoleLinkCommandsTest < Minitest::Test
  include RhoTest::CliHarness

  def console = Rho::Extensions::ConsoleLink::Commands.console(cli, [], { open: false })

  # `--open` goes through the ONE launcher, which honours `$BROWSER`: the
  # stub records the URL the verb printed.
  def test_console_open_launches_the_browser_through_the_launcher
    announce(endpoint: routed_endpoint(
      "POST /console/code" => [[200, {
        "url" => "http://127.0.0.1:7717/#code=abc", "code" => "abc",
        "home" => "/Users/x/.rho", "expires_in_seconds" => 90,
      }]]
    ))
    record = File.join(@root, "opened")
    recorder = File.expand_path("../support/browser_recorder.rb", __dir__)
    previous = ENV["BROWSER"]
    ENV["BROWSER"] = "#{Gem.ruby} #{recorder} #{record}"
    Rho::Extensions::ConsoleLink::Commands.console(cli, [], { open: true })
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    sleep 0.05 until File.exist?(record) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    assert_equal "http://127.0.0.1:7717/#code=abc", File.read(record)
    assert_match(%r{^console: http://127\.0\.0\.1:7717/\#code=abc$}, @out.string, "the URL is printed before the launch")
  ensure
    ENV["BROWSER"] = previous
  end

  def test_console_prints_the_link_the_home_and_the_expiry
    announce(endpoint: routed_endpoint(
      "POST /console/code" => [[200, {
        "url" => "http://127.0.0.1:7717/#code=abc", "code" => "abc",
        "home" => "/Users/x/.rho", "expires_in_seconds" => 90,
      }]]
    ))

    document = console

    assert_equal "abc", document.fetch("code")
    assert_match(%r{^console: http://127\.0\.0\.1:7717/\#code=abc$}, @out.string, @out.string)
    assert_match(%r{^home:\s+/Users/x/\.rho$}, @out.string, @out.string)
    assert_match(/^expires: 90s, single use/, @out.string, @out.string)
  end

  # A daemon serving no page has no link to give, and saying so beats a
  # backtrace.
  def test_console_against_a_pageless_daemon_says_what_the_daemon_said
    announce(endpoint: routed_endpoint(
      "POST /console/code" => [[409, { "error" => { "code" => "page_not_served",
                                                    "message" => "This daemon serves no console page" } }]]
    ))

    error = assert_raises(Rho::Error) { console }
    assert_match(/serves no console page/, error.message)
  end

  def test_console_with_no_daemon_refuses_the_way_every_verb_does
    error = assert_raises(Rho::Error) { console }

    assert_match(/no local daemon is running/, error.message)
  end
end
