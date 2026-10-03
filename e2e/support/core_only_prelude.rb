# Loaded through RUBYOPT into every rho process the core-only journey spawns: the shipped default
# set shrinks to the runner's Coding extension, so `rho do` runs on the core alone.
begin
  require "rho"
rescue LoadError
  # The `bundle` launcher itself runs first, before bundler/setup put rho on
  # the load path; only the product process past it has anything to shrink.
else
  Rho::Extensions.send(:remove_const, :DEFAULT_EXTENSIONS)
  Rho::Extensions.const_set(:DEFAULT_EXTENSIONS, [Rho::Runner::Extensions::Coding].freeze)
  %i[DEFAULT_GEMS CONTROL_GEMS].each do |name|
    Rho::Extensions.send(:remove_const, name)
    Rho::Extensions.const_set(name, [].freeze)
  end

  # THE DISPATCH LOG: one `METHOD PATH` line per request the daemon sends the kernel, appended to
  # `RHO_HOME/dispatch.log`. It is the only core-only-observable record of two things the journey
  # asserts and no member-plane read can show it: that the daemon never called `/agent_loops`
  # create, start or inputs for its own turn (the conversation door did the authoring), and WHICH
  # tools the boot declaration carried — the profile presenter renders the CALLER's own
  # configuration, and the journey holds the steward's token, not rho's. So the declaration PUT's
  # line also carries the body's tool names, sorted. The CLI process loads this too and dispatches
  # nothing — harmless.
  module E2E
    module CoreOnlyDispatchLog
      DECLARATION_PATH = "/agent_api/v1/profile/configuration".freeze

      module_function

      def record(method, path, body = nil)
        home = ENV["RHO_HOME"]
        return if home.nil? || home.empty?

        line = "#{method.to_s.upcase} #{path}"
        names = declared_tool_names(path, body)
        line = "#{line} tools=#{names.join(",")}" if names
        File.open(File.join(home, "dispatch.log"), "a") { |file| file.puts(line) }
      rescue SystemCallError
        # A log that cannot be written must not cost the request it describes.
        nil
      end

      def declared_tool_names(path, body)
        return nil unless path == DECLARATION_PATH && body.is_a?(Hash)

        Array(body.dig("configuration", "tool_definitions")).filter_map do |entry|
          entry.is_a?(Hash) ? entry.dig("function", "name") : nil
        end.sort
      end
    end
  end

  CybrosAgent::Api.const_get(:Dispatch).prepend(Module.new do
    def call_accepting(path, method: :get, body: nil, **rest)
      E2E::CoreOnlyDispatchLog.record(method, path, body)
      super
    end

    def get(path)
      E2E::CoreOnlyDispatchLog.record(:get, path)
      super
    end

    def download(path)
      E2E::CoreOnlyDispatchLog.record(:get, path)
      super
    end
  end)
end
