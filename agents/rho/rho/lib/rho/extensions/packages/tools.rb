module Rho
  module Extensions
    module Packages
      module Tool
        def self.included(base)
          base.extend(Factory)
        end

        module Factory
          # The captured home is immutable registration context. Each call
          # gets its own Core; no process-global daemon or HTTP client exists.
          def for_home(home)
            tool = Class.new(self)
            constants(false).each { |name| tool.const_set(name, const_get(name)) }
            tool.define_method(:initialize) { |env:| super(env: env, core: Rho::Core.new(home: home)) }
            tool
          end
        end

        def initialize(env:, core:)
          @env = env
          @core = core
        end
      end

      class Read
        include Tool
        NAME = "list_extensions".freeze
        DESCRIPTION = "List locally installed personal extension versions, active selections, previous versions and configuration. Packages belong to this rho installation; use manage_extension to install, check, activate, disable or roll back one.".freeze
        SCHEMA = { "type" => "object", "properties" => {}, "additionalProperties" => false }.freeze
        EFFECT_PROFILE = { "kind" => "read_only", "destructive" => false, "effect_scope" => "closed",
          "idempotency" => "intrinsic", "reconciliation" => "none" }.freeze

        def call(_args)
          @env.raise_if_cancelled!
          Rho::Runner::Result.ok(JSON.generate(@core.packages))
        rescue Rho::Error => error
          Rho::Runner::Result.error(error.message)
        end
      end

      class Manage
        include Tool
        NAME = "manage_extension".freeze
        DESCRIPTION = <<~TEXT.strip.freeze
          Manage a personal extension on this rho installation through its managed owner. Develop a directory in the writable work area containing rho-extension.json and extension.rb, then install its absolute path to copy a version into local managed storage. Check explicitly executes its test/**/*_test.rb with this Ruby runtime. Activate selects a full version digest from list_extensions and an optional configuration object; candidate load/start failure retains the active version. Disable removes future registrations; rollback restores the previous code/config only when its business-state schema remains compatible. These operations may execute arbitrary installed code and mutate local or external state. Do not edit the protected installation directly. Backups of packages and assembly settings belong to the operator; business data belongs in Nexus.
        TEXT
        SCHEMA = {
          "type" => "object",
          "properties" => {
            "action" => { "type" => "string", "enum" => %w[install check activate disable rollback] },
            "path" => { "type" => "string", "description" => "Absolute source directory on the rho installation host; required for install." },
            "name" => { "type" => "string" }, "version" => { "type" => "string" },
            "configuration" => { "type" => "object" },
          },
          "required" => ["action"],
          "oneOf" => [
            { "properties" => { "action" => { "const" => "install" } }, "required" => ["path"] },
            { "properties" => { "action" => { "enum" => %w[check activate disable rollback] } }, "required" => ["name"] },
          ],
          "additionalProperties" => false,
        }.freeze
        EFFECT_PROFILE = { "kind" => "write", "destructive" => true, "effect_scope" => "open",
          "idempotency" => "none", "reconciliation" => "lookup" }.freeze
        TIMEOUT_MS = 120_000

        def call(args)
          @env.raise_if_cancelled!
          document = @core.manage_package(**args.transform_keys(&:to_sym))
          if document["passed"] == false
            Rho::Runner::Result.error(JSON.generate(document))
          else
            Rho::Runner::Result.ok(JSON.generate(document))
          end
        rescue Rho::Error => error
          Rho::Runner::Result.error(error.message)
        end
      end
    end
  end
end
