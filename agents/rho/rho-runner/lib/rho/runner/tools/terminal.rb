require "pty"
require "io/console"
require "rho/runner/webrtc_stream"

module Rho
  class Runner
    module Tools
      # An operator's terminal is one tool execution. Its claim owns the
      # shell; viewers and replaceable WebRTC helpers never own its lifetime.
      class Terminal
        NAME = "terminal".freeze
        DESCRIPTION = nil
        SCHEMA = { "type" => "object", "properties" => {}, "additionalProperties" => false }.freeze
        EFFECT_PROFILE = Bash::EFFECT_PROFILE

        def self.configured(executable:, servers:)
          tool = Class.new(self)
          constants(false).each { |name| tool.const_set(name, const_get(name)) }
          tool.define_method(:initialize) { |env:| super(env: env, executable: executable, servers: servers) }
          tool
        end

        def initialize(env:, executable:, servers: [])
          @env = env
          @executable = executable
          @servers = servers
        end

        def call(_args)
          @env.raise_if_cancelled!
          context = ExecutionContext.current
          raise Error, "Terminal requires a task realtime context" unless context&.realtime

          connection = WebrtcConnection.new(executable: @executable, context: context, servers: @servers)
          stream = WebrtcStream.new(connection: connection, context: context)
          shell = Shell.new(root: @env.root)
          ExecutionContext.with_cancel_signal(-> { shell.cancel }) do
            loop do
              @env.raise_if_cancelled!
              packet = stream.poll
              packet.data.each { |bytes| stream.acknowledge_input(shell.write(bytes, context: context)) }
              bytes = shell.read
              break if bytes.nil?

              stream.write_output(bytes) unless bytes == :wait_readable
              sleep(0.01)
            end
          end
          Result.ok("Terminal exited")
        ensure
          begin
            shell&.close
          ensure
            stream&.close
          end
        end

        class Shell
          def initialize(root:)
            @mutex = Mutex.new
            @released = false
            @signaled = false
            # The startup file closes ordinary shell jobs on exit; interactive
            # job control gives those jobs their own process groups.
            @reader, @writer, @pid = PTY.spawn(
              ChildEnv.call.merge("TERM" => "xterm-256color", "BASH_SILENCE_DEPRECATION_WARNING" => "1"),
              Bash::SHELL, "--noprofile", "--rcfile", File.expand_path("terminal.bashrc", __dir__), "-i",
              chdir: root, unsetenv_others: true
            )
            @reader.winsize = [24, 80]
          end

          def read
            @reader.read_nonblock(16 * 1024, exception: false)
          rescue Errno::EIO
            nil
          end

          def write(bytes, context:)
            offset = 0
            while offset < bytes.bytesize
              context.raise_if_cancelled!
              break if context.realtime && !context.realtime.allowed?

              count = @writer.write_nonblock(bytes.byteslice(offset..), exception: false)
              count == :wait_writable ? sleep(0.01) : offset += count
            end
            offset
          end

          def cancel
            @mutex.synchronize do
              return if @released || @signaled

              @signaled = true
              Process.kill("HUP", @pid)
            rescue Errno::ESRCH, Errno::EPERM
              nil
            end
          end

          def close
            cancel
            # Give the shell its hangup/EXIT path before the final group kill.
            sleep(0.1)
          ensure
            @mutex.synchronize do
              unless @released
                # The unreaped child reserves its PID until the last group signal.
                # Reaping earlier would let a late cancellation target another job.
                begin
                  Process.kill("KILL", -@pid)
                rescue Errno::ESRCH, Errno::EPERM
                  nil
                end
                # Release a full PTY before waiting: terminal teardown can wait
                # for its unread output even after the final process-group kill.
                @reader.close unless @reader.closed?
                @writer.close unless @writer.closed?
                Process.waitpid(@pid)
                @released = true
              end
            end
            @reader.close unless @reader.closed?
            @writer.close unless @writer.closed?
          end
        end
      end
    end
  end
end
