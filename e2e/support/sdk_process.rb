require "json"
require "tempfile"
require_relative "process_runner"
require_relative "secret_hygiene"

module E2E
  # Language drivers import their SDK's public package. Secrets enter through
  # stdin; stdout contains only bounded NDJSON facts used by the journey.
  class SDKProcess
    ROOT = File.expand_path("../..", __dir__)
    MAX_OUTPUT = 1_048_576
    POLL = 0.02

    def self.prepare!
      return if @prepared

      build("pnpm", "run", "build", chdir: File.join(ROOT, "sdks/typescript"))
      build("cargo", "build", "--locked", "--features", "realtime", "--example", "e2e_driver", chdir: File.join(ROOT, "sdks/rust"))
      @prepared = true
    end

    def self.build(*command, chdir:)
      Tempfile.create("sdk-build") do |output|
        status = ProcessRunner.run(*command, chdir:, out: output, err: output, timeout: 180)
        next if status.success?

        output.rewind
        raise "SDK build failed: #{SecretHygiene.redact(output.read(MAX_OUTPUT))}"
      end
    end

    def self.command(language)
      case language
      # Run the SDK's local tsx without a package-script banner in the NDJSON stream.
      when :typescript then ["pnpm", "--dir", File.join(ROOT, "sdks/typescript"), "exec", "tsx", "test/e2e-driver.ts"]
      when :rust then [File.join(ROOT, "sdks/rust/target/debug/examples/e2e_driver")]
      else raise ArgumentError, "unknown SDK language: #{language.inspect}"
      end
    end

    def self.run(language, payload, timeout: 90)
      process = new(command(language), payload, timeout:)
      yield process if block_given?
      process.finish
    ensure
      process&.close
    end

    attr_reader :records

    def initialize(command, payload, timeout: 90)
      @output = Tempfile.new("sdk-facts")
      @errors = Tempfile.new("sdk-errors")
      @records = []
      @offset = 0
      @pending = +""
      @thread = Thread.new do
        ProcessRunner.run(*command, chdir: ROOT, stdin: JSON.generate(payload),
          out: @output, err: @errors, timeout:)
      end
      @thread.report_on_exception = false
    end

    def wait_for(event)
      loop do
        read_records
        found = @records.find { |record| record["event"] == event }
        return found if found

        if @thread.join(0)
          check_status
          read_records
          found = @records.find { |record| record["event"] == event }
          return found if found

          raise "SDK driver ended before #{event.inspect}"
        end
        sleep POLL
      end
    end

    def finish
      @thread.join
      check_status
      read_records
      raise "SDK driver left an incomplete NDJSON fact" unless @pending.empty?
      raise "SDK driver produced no result" if @records.empty?

      @records.last
    end

    def close
      @thread.kill if @thread&.alive?
      @thread&.join
    rescue StandardError
      # The read/finish caller already receives the driver's failure.
      nil
    ensure
      @output&.close!
      @errors&.close!
    end

    private

      def read_records
        raise "SDK driver output exceeded #{MAX_OUTPUT} bytes" if @output.size > MAX_OUTPUT

        bytes = File.binread(@output.path, MAX_OUTPUT, @offset) || ""
        @offset += bytes.bytesize
        @pending << bytes
        while (newline = @pending.index("\n"))
          line = @pending.slice!(0, newline + 1)
          @records << JSON.parse(line)
        end
      end

      def check_status
        status = @thread.value
        return if status.success?

        @errors.rewind
        raise "SDK driver exited #{status.exitstatus}: #{SecretHygiene.redact(@errors.read(MAX_OUTPUT))}"
      end
  end
end
