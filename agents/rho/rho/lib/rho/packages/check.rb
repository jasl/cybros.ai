require "rbconfig"

module Rho
  class Packages
    module Check
      TIMEOUT = 60
      OUTPUT_BYTES = 64 * 1024
      SCRIPT = "ARGV.each { |path| require File.expand_path(path) }".freeze

      def self.run(directory, timeout: TIMEOUT)
        tests = Dir.glob("test/**/*_test.rb", base: directory).sort
        return { checked: true, tests: 0, passed: true, output: "No test/**/*_test.rb files; structure and dependencies checked." } if tests.empty?

        output = +""
        stream, writer = IO.pipe
        child = Rho::Runner::OwnedProcess.spawn(RbConfig.ruby, "-Itest", "-Ilib", "-e", SCRIPT, "--", *tests,
          chdir: directory, in: File::NULL, out: writer, err: writer)
        writer.close
        reader = Thread.new do
          loop do
            output << stream.readpartial(8192)
            output = output.byteslice(-OUTPUT_BYTES, OUTPUT_BYTES) if output.bytesize > OUTPUT_BYTES
          end
        rescue EOFError, IOError
          nil
        end
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        timed_out = false
        until (status = child.poll)
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            timed_out = true
            break
          end
          sleep Rho::Runner::OwnedProcess::POLL_SECONDS
        end
        # The existing process owner ends descendants on every exit, including
        # a successful test that left a background child holding its output.
        status = child.kill_and_reap
        reader.join
        { checked: true, tests: tests.length, passed: !timed_out && status.success?,
          exit_status: status.exitstatus, timed_out: timed_out, output: output.force_encoding(Encoding::UTF_8).scrub }
      ensure
        child&.kill_and_reap
        writer&.close unless writer&.closed?
        stream&.close unless stream&.closed?
        reader&.join
      end
    end
  end
end
