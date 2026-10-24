require "json"
require_relative "../../support/process_registry"
require_relative "../../support/secret_hygiene"

module E2E
  class FakeExecutorProcess
    ROOT = File.expand_path("..", __dir__)
    SCRIPT = File.expand_path("fake_executor_main.rb", __dir__)

    attr_reader :log_path

    def initialize(base_url:, home:, credential:, kind: :runner, tools: %w[echo read synthetic_wait], directory: nil)
      @options = { base_url: base_url, credential: SecretHygiene.register(credential),
        kind: kind, tools: tools, directory: directory }
      @log_path = File.join(home, "fake-executor.log")
    end

    def start
      @offset = events.length
      input, writer = IO.pipe
      env = ENV.keys.grep(/\ABUNDLE/).to_h { |name| [name, nil] }
      env.merge!("BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile"), "BUNDLE_FROZEN" => "true",
        "RUBYOPT" => nil, "RUBYLIB" => nil)
      @pid = ProcessRegistry.spawn(env, Gem.ruby, Gem.bin_path("bundler", "bundle"), "exec", "ruby", SCRIPT,
        chdir: ROOT, in: input, out: [log_path, "a"], err: [log_path, "a"], pgroup: true)
      input.close
      writer.puts(JSON.generate(@options))
      writer.close
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
      until executor_public_id
        if Process.waitpid(@pid, Process::WNOHANG)
          ProcessRegistry.unregister(@pid)
          @pid = nil
          raise "fake executor exited: #{SecretHygiene.redact(File.read(log_path))}"
        end
        raise "fake executor did not announce: #{SecretHygiene.redact(File.read(log_path))}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.1
      end
      self
    end

    def stop
      ProcessRegistry.terminate(@pid) if @pid
      @pid = nil
    end

    def kill!
      Process.kill("KILL", -@pid)
      Process.waitpid(@pid)
      ProcessRegistry.unregister(@pid)
      @pid = nil
    end

    def executor_public_id = events.drop(@offset || 0).find { |row| row["event"] == "announced" }&.fetch("executor_public_id")
    def log_text = File.file?(log_path) ? File.read(log_path) : ""
    def restores = events.select { |row| row["event"] == "restored" }
    def claims = events.drop(@offset || 0).select { |row| row["event"] == "claimed" }

    private

      def events
        return [] unless File.file?(log_path)

        File.readlines(log_path).filter_map { |line| JSON.parse(line) if line.start_with?("{") }
      end
  end
end
