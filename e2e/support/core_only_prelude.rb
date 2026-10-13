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
  %i[DEFAULT_GEMS CONTROL_GEMS TOOL_GEMS].each do |name|
    Rho::Extensions.send(:remove_const, name)
    Rho::Extensions.const_set(name, [].freeze)
  end

  # THE DISPATCH LOG: one `METHOD PATH` line per request the daemon sends the kernel, appended to
  # `RHO_HOME/dispatch.log`. It records that the daemon never called `/runs` create, start or
  # inputs for its own turn, and that both addresses announced before the profile declaration.
  # The journey reads the accepted tool surface from the public model-task resource instead of
  # inferring it from the profile's source configuration. The CLI loads this too and dispatches nothing.
  module E2E
    module CoreOnlyDispatchLog
      module_function

      def record(method, path)
        home = ENV["RHO_HOME"]
        return if home.nil? || home.empty?

        line = "#{method.to_s.upcase} #{path}"
        File.open(File.join(home, "dispatch.log"), "a") { |file| file.puts(line) }
      rescue SystemCallError
        # A log that cannot be written must not cost the request it describes.
        nil
      end
    end
  end

  CybrosAgent::Api.const_get(:Dispatch).prepend(Module.new do
    def call_accepting(path, method: :get, body: nil, **rest)
      E2E::CoreOnlyDispatchLog.record(method, path)
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
