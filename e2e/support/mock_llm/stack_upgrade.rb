require_relative "app"

module E2E
  module MockLLM
    # One installed-stack request waits on the journey's own fixture directory.
    # This observes real provider IO without changing Nexus or writing its rows.
    class StackUpgrade
      MARKER = "stack-upgrade-provider"
      TIMEOUT = 180

      def initialize(app, directory:)
        @app = app
        @directory = directory
      end

      def call(env)
        if env["REQUEST_METHOD"] == "POST" && env["PATH_INFO"] == "/v1/responses"
          input = env.fetch("rack.input")
          body = input.read
          input.rewind
          wait_for_release if body.include?(MARKER)
        end
        @app.call(env)
      end

      private

        def wait_for_release
          File.open(File.join(@directory, "requests"), "a") { |file| file.puts("started") }
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TIMEOUT
          until File.exist?(File.join(@directory, "release"))
            raise "stack upgrade provider fixture timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

            sleep 0.05
          end
        end
    end
  end
end
