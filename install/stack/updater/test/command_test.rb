require "minitest/autorun"
require "tmpdir"
require_relative "../updater"

class UpdaterCommandTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("command path ")
    executable = File.join(@directory, "docker")
    File.write(executable, <<~RUBY)
      #!/usr/bin/env ruby
      case ARGV.first
      when "echo"
        puts ARGV.drop(1)
      when "fail"
        warn "password=synthetic-private-credential"
        exit 7
      when "sleep"
        sleep 5
      when "large"
        STDOUT.write("x" * (5 * 1024 * 1024))
      when "dump"
        STDOUT.write("sensitive database contents\n" * (256 * 1024))
        warn "password=synthetic-dump-stderr"
      else
        exit 8
      end
    RUBY
    File.chmod(0o700, executable)
    @environment = { "PATH" => "#{@directory}:#{ENV.fetch("PATH")}" }
    @command = CybrosUpdater::Command.new(@directory)
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_arguments_are_preserved_without_shell_interpolation
    argument = "a path with spaces; $(touch missing)"
    result = @command.run(["echo", argument], timeout: 2, environment: @environment)
    assert_equal "#{argument}\n", result.output
    refute File.exist?(File.join(@directory, "missing"))
  end

  def test_command_failure_does_not_expose_raw_stderr
    error = assert_raises(CybrosUpdater::Error) { @command.run(["fail"], timeout: 2, environment: @environment) }
    assert_equal "command_failed", error.code
    refute_includes error.message, "synthetic-private-credential"
  end

  def test_output_can_be_drained_without_capturing_and_captured_metadata_is_bounded
    result = @command.run(["large"], timeout: 2, environment: @environment, capture: false)
    assert_equal "", result.output
    error = assert_raises(CybrosUpdater::Error) { @command.run(["large"], timeout: 2, environment: @environment) }
    assert_equal "command_output_limit", error.code
  end

  def test_hung_command_has_a_bounded_deadline
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(CybrosUpdater::Error) { @command.run(["sleep"], timeout: 0.05, environment: @environment) }
    assert_equal "command_timeout", error.code
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
  end

  def test_database_output_streams_to_its_private_file_without_stderr_or_capture_limits
    path = File.join(@directory, "private.sql")
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      result = @command.run(["dump"], timeout: 5, environment: @environment, output_file: file)
      assert_empty result.output
    end
    assert_operator File.size(path), :>, 4 * 1024 * 1024
    assert_equal 0o600, File.stat(path).mode & 0o777
    refute_includes File.read(path), "synthetic-dump-stderr"
  end

  def test_repository_settings_accept_registry_paths_but_not_tags_digests_or_urls
    cli = CybrosUpdater::CLI.new([], environment: { "REPOSITORY" => "ghcr.io/example/team/image" })
    assert_equal "ghcr.io/example/team/image", cli.send(:repository, "REPOSITORY", "unused")
    cli = CybrosUpdater::CLI.new([], environment: { "REPOSITORY" => "localhost:5000/example/image" })
    assert_equal "localhost:5000/example/image", cli.send(:repository, "REPOSITORY", "unused")
    cli = CybrosUpdater::CLI.new([], environment: { "REPOSITORY" => "example_team/image" })
    assert_equal "example_team/image", cli.send(:repository, "REPOSITORY", "unused")
    ["https://example.test/image", "example/image:latest", "example/image@sha256:abc", "example/image;echo"].each do |value|
      cli = CybrosUpdater::CLI.new([], environment: { "REPOSITORY" => value })
      assert_raises(CybrosUpdater::Error) { cli.send(:repository, "REPOSITORY", "unused") }
    end
  end
end
