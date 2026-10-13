module CybrosUpdater
  class Command
    Result = Data.define(:output, :exitstatus)

    def initialize(directory)
      @directory = directory
    end

    def run(arguments, timeout:, environment: {}, capture: true, allow_failure: false, output_file: nil, executable: "docker")
      output = +""
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      result = nil
      stream, writer = IO.pipe
      # A dump goes directly from the child to its private file. Only stderr
      # reaches this pipe, so SQL never enters metadata capture or browser logs.
      pid = Process.spawn(environment, executable, *arguments, chdir: @directory, pgroup: true,
        in: File::NULL, out: output_file || writer, err: writer)
      writer.close
      waiter = Process.detach(pid)
      observed = 0
      loop do
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          raise Error.new("command_timeout", "Deployment command exceeded its deadline.")
        end
        if IO.select([stream], nil, nil, 0.25)
          begin
            chunk = stream.read_nonblock(4096)
            output << chunk if capture && !output_file
            observed += chunk.bytesize
            if (capture || output_file) && observed > 4 * 1024 * 1024
              raise Error.new("command_output_limit", "Deployment command diagnostics exceeded their limit.")
            end
          rescue IO::WaitReadable
            next
          rescue EOFError
            break
          end
        end
      end
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      unless remaining.positive? && waiter.join(remaining)
        raise Error.new("command_timeout", "Deployment command exceeded its deadline.")
      end
      result = Result.new(output: output, exitstatus: waiter.value.exitstatus)
      if !allow_failure && result.exitstatus != 0
        raise Error.new("command_failed", "Deployment command failed; inspect the operation receipt and local container diagnostics.")
      end
      result
    rescue Errno::ENOENT
      raise Error.new("updater_unavailable", "A required deployment command is unavailable.")
    ensure
      if waiter&.alive?
        signal("TERM", waiter.pid)
        unless waiter.join(1)
          signal("KILL", waiter.pid)
          waiter.join
        end
      end
      writer&.close unless writer&.closed?
      stream&.close unless stream&.closed?
    end

    private

    def signal(name, pid)
      Process.kill(name, -pid)
    rescue Errno::ESRCH
      nil
    end
  end
end
