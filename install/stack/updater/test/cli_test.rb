require "minitest/autorun"
require "tmpdir"
require "stringio"
require_relative "../updater"

class UpdaterCLITest < Minitest::Test
  class TestCLI < CybrosUpdater::CLI
    attr_accessor :response
    attr_reader :requests

    def initialize(...)
      super
      @requests = []
    end

    private

    def request(operation, attributes = {})
      @requests << [operation, attributes]
      @response
    end

    def await_operation(_operation) = 0
  end

  def setup
    @directory = Dir.mktmpdir
    @environment = { "CYBROS_INSTALL_DIR" => @directory }
    @output = StringIO.new
    @errors = StringIO.new
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def cli(*arguments)
    TestCLI.new(arguments, environment: @environment, output: @output, errors: @errors)
  end

  def test_blocked_check_prints_report_without_accepting_an_upgrade
    command = cli("update")
    command.response = { "candidate" => nil, "preflight" => { "ready" => false, "checks" => [{ "message" => "Free disk space." }] } }

    assert_equal 1, command.run
    assert_equal [["check", { "tag" => "latest", "backup" => true }]], command.requests
    assert_equal command.response, JSON.parse(@output.string)
    assert_includes @errors.string, "preflight_failed"
  end

  def test_explicit_check_returns_the_report_and_does_not_upgrade
    command = cli("check", "2610080750")
    command.response = { "candidate" => nil, "preflight" => { "ready" => false } }

    assert_equal 0, command.run
    assert_equal [["check", { "tag" => "2610080750", "backup" => true }]], command.requests
    assert_equal command.response, JSON.parse(@output.string)
  end

  def test_no_backup_is_sent_to_both_check_and_acceptance
    command = cli("update", "2610080750", "--no-backup")
    command.response = { "candidate" => { "release" => "2610080750", "images" => [] }, "preflight" => { "ready" => true } }

    assert_equal 0, command.run
    assert_equal ["check", { "tag" => "2610080750", "backup" => false }], command.requests.first
    assert_equal "upgrade", command.requests.last.first
    assert_equal false, command.requests.last.last.fetch("backup")
  end

  def test_unknown_options_and_extra_tags_do_not_make_requests
    [["--unknown"], ["2610080750", "2610080800"]].each do |arguments|
      command = cli("update", *arguments)
      assert_equal 1, command.run
      assert_empty command.requests
    end
  end

  def test_offline_listing_reuses_the_owner_lock_and_releases_it
    assert_equal 0, cli("backups").run
    assert_equal({ "installations" => [], "databases" => [], "keep" => 3 }, JSON.parse(@output.string))
    state = File.join(@directory, "data", "updater")
    owner = CybrosUpdater::Store.new(state)
    assert_equal 1, cli("backups").run
    assert_includes @errors.string, "Another updater owns this installation"
    owner.close
    owner = nil
    assert_equal 0, cli("backups").run
  ensure
    owner&.close
  end

  def test_maintenance_validates_retention_and_restore_identity_at_the_boundary
    @environment["CYBROS_BACKUP_KEEP"] = "0"
    assert_equal 1, cli("backups").run
    assert_includes @errors.string, "CYBROS_BACKUP_KEEP"
    refute File.exist?(File.join(@directory, "data"))
    @environment["CYBROS_BACKUP_KEEP"] = "7"
    assert_equal 0, cli("backups").run
    assert_equal 7, JSON.parse(@output.string).fetch("keep")
    assert_equal 1, cli("restore", "../../outside", @directory).run
    assert_includes @errors.string, "backup UUIDv7"
  end
end
