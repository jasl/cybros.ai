module Rho
  class Runner
    module Extensions
      # HOW EXTENSIONS ARE FOUND AND RUN, and the place the owner's claim
      # that "Ruby only does this more naturally" is cashed in: pi spends
      # 806 lines on a loader because Node cannot require TypeScript and a
      # compiled binary has no node_modules, so it carries jiti, a virtual
      # module table and three runtime modes. Ruby has `$LOAD_PATH`,
      # RubyGems and `load`. This is that job.
      #
      # THREE LEGS, in a fixed order, each an explicit act:
      #   1. the DEFAULT set the host names — "rho integrates the default
      #      set", which is a literal list, not a discovery;
      #   2. gems declaring `metadata["rho_extensions"]`, named by the
      #      operator's settings — installed is not the same as wanted;
      #   3. `RHO_HOME/extensions/*.rb`, one level, no recursion.
      #
      # NOTHING AUTO-LOADS FROM A GEM SWEEP. These tools run shell
      # commands on the operator's machine on behalf of a remote model, so
      # a gem arriving as somebody's transitive dependency must not become
      # a tool. `available` answers what is installed; the settings say
      # what to load, and the two are different questions.
      #
      # ONE FACTORY'S FAILURE IS ITS OWN. A raise during registration is
      # recorded and the load continues: an operator with three extensions
      # and one typo gets two working tools and a line saying which one
      # broke, rather than a daemon that will not take work.
      module Loader
        GEM_METADATA_KEY = "rho_extensions".freeze
        Failure = Data.define(:source, :error_class, :message)

        # `committed` is the handles that ACTUALLY landed. A host that
        # reads more off a handle than the registry does — a daemon
        # collecting commands, say — must read it from here and not from
        # every handle constructed, or a factory that raised half-way
        # would still contribute its commands while its tools were
        # correctly discarded.
        Result = Data.define(:registry, :failures, :committed) do
          def initialize(committed: [], **) = super

          def ok? = failures.empty?
        end

        # One load in progress: what every leg reads and appends to.
        Load = Data.define(:registry, :failures, :committed, :api_class, :api_options, :log, :reusable)

        module_function

        # `builtin` is anything answering `register(api)`; `paths` are
        # files to `load`; `gems` are feature names to `require`.
        # `api_options` reach every handle's constructor beside the three
        # the loader supplies — how a daemon hands each extension its host.
        def call(builtin: [], gems: [], paths: [], api_class: Api, api_options: {}, log: nil, reuse: [])
          reusable = reuse.to_h do |api|
            [[api.source, api.source == "<built-in>" ? api.extension_name : nil], api]
          end
          load = Load.new(registry: Registry.new(log: log), failures: [], committed: [],
            api_class: api_class, api_options: api_options, log: log, reusable: reusable)

          Array(builtin).each do |mod|
            load_one(load, source: "<built-in>", name: extension_name_of(mod)) { mod }
          end

          Array(gems).each do |feature|
            load_one(load, source: "gem:#{feature}", name: feature.to_s) { require_feature(feature) }
          end

          Array(paths).each do |path|
            load_one(load, source: path, name: File.basename(path, ".rb")) { load_file(path) }
          end

          Result.new(registry: load.registry, failures: load.failures, committed: load.committed)
        end

        # What is INSTALLED, which is not what is loaded. Minitest answers
        # the same question the same way — `Gem.find_files` over a
        # convention — and it is Ruby's canonical plugin index.
        def available
          Gem::Specification.map do |spec|
            value = spec.metadata[GEM_METADATA_KEY]
            next if value.nil? || value.empty?

            { "gem" => spec.name, "version" => spec.version.to_s,
              "features" => value.split(",").map(&:strip).reject(&:empty?) }
          end.compact
        rescue StandardError
          []
        end

        # A file is loaded into an ANONYMOUS module, so two extensions
        # defining the same constant name cannot collide in Object and a
        # file reloaded twice does not warn about redefinition.
        def load_file(path)
          wrapper = Module.new
          Kernel.load(path, wrapper)
          module_in(wrapper)
        end

        def require_feature(feature)
          require feature.to_s
          module_named(feature)
        end

        def load_one(load, source:, name:)
          existing = load.reusable[[source, source == "<built-in>" ? name : nil]]
          if existing
            load.registry.commit(existing)
            load.committed << existing
            return
          end

          mod = yield
          raise RegistrationError, "#{source} defines no extension module" if mod.nil?

          api = load.api_class.new(extension_name: extension_name_of(mod), source: source,
            log: load.log, announced: announced_so_far(load.registry), **load.api_options)
          mod.register(api)
          api.freeze
          load.registry.commit(api)
          load.committed << api
        rescue StandardError, ScriptError => error
          api&.resources&.retire
          load.log&.warn("extension_load_failed", source: source,
            error_class: error.class.name, detail: error.message)
          load.failures << Failure.new(source: source, error_class: error.class.name,
            message: error.message)
        end

        # The handle's `announced`: each address's announcement as the
        # registry renders it before this extension commits.
        def announced_so_far(registry)
          Api::SERVES.to_h { |serves| [serves, registry.serving(serves).announcement] }
        end

        def extension_name_of(mod)
          return mod::NAME.to_s if mod.const_defined?(:NAME, false)

          mod.name.to_s.split("::").last.to_s.downcase
        end

        # The one module inside the anonymous wrapper that answers
        # `register` — so a file may define helpers beside its extension.
        def module_in(wrapper)
          wrapper.constants(false).map { |const| wrapper.const_get(const, false) }
            .find { |value| value.respond_to?(:register) }
        end

        def module_named(feature)
          name = feature.to_s.split("/").map { |part| camelize(part) }.join("::")
          Object.const_get(name)
        rescue NameError
          nil
        end

        def camelize(part) = part.split(/[_-]/).map(&:capitalize).join
      end
    end
  end
end
