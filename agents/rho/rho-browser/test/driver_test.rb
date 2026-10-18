require "test_helper"

# THE REAL DRIVER, AGAINST A PROCESS THAT IS ALIVE AND SILENT — the exact
# failure the whole clock exists for, and the one a fake cannot stand in
# for: the gem's transport spawns whatever string it is given, in its own
# process group, and waits on a promise the child must answer. A child
# that never speaks must be cut at the deadline and must be GONE
# afterwards, or every such start is a leaked process.
#
# `sh -c 'exec sleep …'` is that child: the transport appends
# `run-driver`, which `sh -c` ignores, and sleep neither reads nor writes.
class DriverTest < Minitest::Test
  MARK = "31337".freeze

  # A shell around pgrep can match its own command line on Linux.
  def leaked = IO.popen(["pgrep", "-f", "sleep #{MARK}"], &:read).split

  def test_a_driver_that_never_speaks_is_cut_at_the_deadline_and_killed
    # Only what THIS start spawns counts: a previous run's orphan on the
    # same machine must not fail — or pass — this one.
    before = leaked
    driver = Rho::Browser::Driver.new(
      cli: "sh -c 'exec sleep #{MARK}'", start_deadline: 1.0, stop_stage: 0.3
    )
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(Rho::Browser::Driver::StartTimedOut) { driver.start }
    took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_match(/did not start within 1\.0s/, error.message)
    assert_operator took, :<, 4.0, "start was not cut at its deadline"
    refute_predicate driver, :started?

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    sleep 0.05 until (leaked - before).empty? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    assert_empty leaked - before, "the silent driver process outlived its start"
  end

  # The installed driver: the prefix's
  # `bin/rho-playwright` is the default when it exists, an operator's
  # RHO_BROWSER_PLAYWRIGHT_CLI wins over it, and a bare machine keeps
  # `playwright` on PATH.
  def test_the_default_cli_is_the_prefixs_driver_when_installed
    Dir.mktmpdir("rho-prefix") do |prefix|
      assert_equal "playwright", Rho::Browser::Driver.default_cli({})
      assert_equal "playwright", Rho::Browser::Driver.default_cli({ "RHO_PREFIX" => prefix }),
        "a prefix without the dev rows"
      installed = File.join(prefix, "bin", "rho-playwright")
      FileUtils.mkdir_p(File.dirname(installed))
      File.write(installed, "#!/bin/sh\n")
      File.chmod(0o755, installed)
      assert_equal installed, Rho::Browser::Driver.default_cli({ "RHO_PREFIX" => prefix })
      assert_equal "npx -y playwright-core@1.62.1",
        Rho::Browser::Driver.default_cli({ "RHO_PREFIX" => prefix, "RHO_BROWSER_PLAYWRIGHT_CLI" => "npx -y playwright-core@1.62.1" })
    end
  end

  def test_stop_before_start_is_a_no_op
    driver = Rho::Browser::Driver.new(cli: "true")
    driver.stop
    refute_predicate driver, :started?
  end

  # A DRIVER THAT EXITS IS NOT A HANG. The gem never signals EOF, so
  # before the watcher a driver that died in its first second read as a
  # sixty-second timeout with the reason lost. Now it is a Failure at
  # once, naming the status and quoting what the driver said.
  def test_a_driver_that_exits_is_reported_at_once_with_its_status_and_words
    driver = Rho::Browser::Driver.new(
      cli: "sh -c 'echo driver-said-no >&2; exit 3'", start_deadline: 10.0, stop_stage: 0.3
    )
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(Rho::Browser::Driver::Exited) { driver.start }
    took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator took, :<, 3.0, "an exited driver waited for the start deadline"
    assert_match(/exited during start \(status 3\)/, error.message)
    assert_match(/driver-said-no/, error.message)
    refute_predicate driver, :started?
  end

  def test_a_missing_driver_names_what_to_install
    driver = Rho::Browser::Driver.new(cli: "/nonexistent/playwright-#{MARK}", start_deadline: 5.0)
    error = assert_raises(Rho::Browser::Driver::Missing) { driver.start }
    assert_match(/not installed or not on PATH/, error.message)
    assert_match(/npm i -g playwright/, error.message)
  end

  # Every failure is one class to a tool, so the model always reads the
  # message and never a class name.
  def test_every_start_failure_is_a_failure
    assert_operator Rho::Browser::Driver::Exited, :<, Rho::Browser::Driver::Failure
    assert_operator Rho::Browser::Driver::Missing, :<, Rho::Browser::Driver::Failure
    assert_operator Rho::Browser::Driver::StartTimedOut, :<, Rho::Browser::Driver::Failure
  end
end
