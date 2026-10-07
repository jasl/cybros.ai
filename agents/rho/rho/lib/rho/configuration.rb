require "json"
require "json_schemer"
require_relative "errors"

module Rho
  module Configuration
    Resolved = Data.define(:overrides, :value, :diagnostics)
    Diagnostic = Data.define(:path, :reason, :fallback)
    Secret = Data.define(:path, :set)
    View = Data.define(:schema, :overrides, :value, :diagnostics, :secrets) do
      def to_h
        super.merge(diagnostics: diagnostics.map(&:to_h), secrets: secrets.map(&:to_h))
      end
    end

    # Migrations own format changes only. The caller owns serialization and publishes
    # the returned document and version together after current-shape normalization.
    def self.migrate(document, from:, to:, steps:)
      unless from >= 0 && to >= from
        raise ConfigurationError, "configuration version is newer than the selected implementation"
      end

      current = copy(document)
      ((from + 1)..to).each do |version|
        migration = steps.fetch(version) do
          raise ConfigurationError, "missing configuration migration to version #{version}"
        end
        begin
          current = copy(migration.call(current))
        rescue StandardError
          # A plugin exception can include configuration values. Only the failing
          # version is safe to return through management and logs.
          raise ConfigurationError, "configuration migration to version #{version} failed", cause: nil
        end
      end
      current
    end

    def self.copy(value)
      JSON.parse(JSON.generate(value, strict: true))
    rescue JSON::GeneratorError, JSON::ParserError
      raise ConfigurationError, "configuration must contain JSON values", cause: nil
    end

    def self.load_migrations(path)
      scope = Module.new
      scope.module_eval(File.read(path, encoding: "UTF-8"), path, 1)
      scope.const_get(:MIGRATIONS, false).to_h
    rescue StandardError, ScriptError
      raise ConfigurationError, "configuration migration file could not be loaded", cause: nil
    end
  end
end

require_relative "configuration/schema"
