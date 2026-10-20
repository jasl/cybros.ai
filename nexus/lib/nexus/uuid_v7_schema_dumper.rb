# Rails dumps the connected server's default verbatim. Keep the primary schema
# loadable on both PostgreSQL 17 with pg_uuidv7 and PostgreSQL 18+ without it.
module Nexus::UuidV7SchemaDumper
  private

  def extensions(stream)
    if @connection.pool.db_config.name == "primary"
      @extensions -= ["pg_uuidv7"]
      super
      stream.puts "  # PostgreSQL 17 needs pg_uuidv7; PostgreSQL 18+ has a native generator."
      stream.puts '  enable_extension "pg_uuidv7" if connection.database_version < 180_000'
      stream.puts
    else
      super
    end
  end

  def schema_expression(column)
    if @connection.pool.db_config.name == "primary" && column.type == :uuid &&
        %w[uuidv7() uuid_generate_v7()].include?(column.default_function)
      '-> { connection.database_version >= 180_000 ? "uuidv7()" : "uuid_generate_v7()" }'
    else
      super
    end
  end
end
