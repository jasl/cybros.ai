require "test_helper"
require "open3"
require "tmpdir"

# The boot shim, proven in a real subprocess: bin/model_runner's require
# order gives the runner its own log file with a console broadcast, and a
# double install registers nothing twice. A file the environment names
# (`RAILS_LOG_FILE`, config/environments/development.rb: the e2e world's
# own, whole, unrotated) stands, and the shim yields to it.
class ModelRunner::RailsBootTest < ActiveSupport::TestCase
  test "a RAILS_LOG_FILE names the runner's whole log and the shim yields to it" do
    Dir.mktmpdir do |dir|
      log_file = File.join(dir, "world", "model_runner.rails.log")
      script = <<~RUBY
        require "#{Rails.root}/config/application"
        require "#{Rails.root}/lib/model_runner/rails_boot"
        ModelRunner::RailsBoot.install(Nexus::Application)
        require "#{Rails.root}/config/environment"
        puts "LOG_PATH=\#{Rails.application.config.paths["log"].to_a.first}"
        puts "LOG_FILE_SIZE=\#{Rails.application.config.log_file_size.inspect}"
        Rails.logger.info("knob-probe-marker-\#{Process.pid}")
        puts "MARKER=knob-probe-marker-\#{Process.pid}"
      RUBY
      path = File.join(dir, "knob_probe.rb")
      File.write(path, script)
      # The development environment carries the knob; the boot connects to
      # no database, the marker is the only line written.
      stdout, stderr, status = Open3.capture3(
        { "RAILS_ENV" => "development", "RAILS_LOG_FILE" => log_file }, RbConfig.ruby, path, chdir: Rails.root.join("bin").to_s
      )

      assert status.success?, "boot failed: #{stderr}"
      assert_includes stdout, "LOG_PATH=#{log_file}", "the environment's file, not the runner's own"
      assert_includes stdout, "LOG_FILE_SIZE=nil", "a per-world file is whole: no rotation"
      marker = stdout[/MARKER=(\S+)/, 1]
      assert_equal 2, stdout.scan(marker).length, "the console broadcast stays beside the echo"
      assert_includes File.read(log_file), marker, "the runner's lines reach the environment's file"
      own = Rails.root.join("log", "model_runner.development.log")
      refute File.exist?(own) && File.read(own).include?(marker), "the runner's own file gets nothing of a world's"
    end
  end

  test "the runner boots with its own log and an idempotent install" do
    script = <<~RUBY
      require "#{Rails.root}/config/application"
      require "#{Rails.root}/lib/model_runner/rails_boot"
      ModelRunner::RailsBoot.install(Nexus::Application)
      ModelRunner::RailsBoot.install(Nexus::Application)
      require "#{Rails.root}/config/environment"
      puts "LOG_PATH=\#{Rails.application.config.paths["log"].to_a.first}"
      puts "INITIALIZERS=\#{Rails.application.initializers.count { |i| i.name.to_s.start_with?("model_runner.") }}"
      Rails.logger.info("boot-probe-marker-\#{Process.pid}")
      puts "MARKER=boot-probe-marker-\#{Process.pid}"
      puts "BOOTED=ok"
    RUBY

    stdout = stderr = status = nil
    Dir.mktmpdir do |dir|
      path = File.join(dir, "boot_probe.rb")
      File.write(path, script)
      stdout, stderr, status = Open3.capture3(
        { "RAILS_ENV" => "test" }, RbConfig.ruby, path, chdir: Rails.root.join("bin").to_s
      )
    end

    assert status.success?, "boot failed: #{stderr}"
    assert_includes stdout, "LOG_PATH=#{Rails.root.join("log", "model_runner.test.log")}"
    assert_includes stdout, "INITIALIZERS=2", "a second install must register nothing twice"
    assert_includes stdout, "BOOTED=ok"
    marker = stdout[/MARKER=(\S+)/, 1]
    # TWICE: once from the script's own puts, once from the broadcast — a
    # single occurrence means the console initializer's body is dead while
    # every registration correlate stays green (the round-1 defect shape,
    # nearly reintroduced on the other half of the same contract).
    assert_equal 2, stdout.scan(marker).length,
      "the broadcast puts the runner's lines on the console exactly once beside the echo"
    # The predecessor pinned the file half and the port had dropped it: the
    # marker must reach the runner's OWN log, or the shim's whole purpose is
    # silently dead while every correlate stays green.
    assert_includes File.read(Rails.root.join("log", "model_runner.test.log")), marker,
      "the runner's lines belong in its own file"
  end
end
