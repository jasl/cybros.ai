require_relative "../../lib/nexus/uuid_v7_schema_dumper"

ActiveSupport.on_load(:active_record) do
  require "active_record/connection_adapters/postgresql_adapter"
  ActiveRecord::ConnectionAdapters::PostgreSQL::SchemaDumper.prepend(Nexus::UuidV7SchemaDumper)
end
