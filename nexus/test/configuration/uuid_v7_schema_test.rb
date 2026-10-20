require "test_helper"
require "stringio"

class UuidV7SchemaTest < ActiveSupport::TestCase
  test "database generated public identifiers use UUIDv7 on the connected PostgreSQL version" do
    connection = ApplicationRecord.connection
    expected = connection.database_version >= 180_000 ? "uuidv7()" : "uuid_generate_v7()"
    columns = connection.tables.flat_map do |table|
      connection.columns(table).select { |column| column.name == "public_id" && column.has_default? }
    end

    assert_not_empty columns
    columns.each do |column|
      assert_equal :uuid, column.type
      assert_equal expected, column.default_function
    end

    connection.create_table :uuid_v7_probe, temporary: true do |table|
      table.uuid :public_id, default: -> { expected }, null: false
    end
    generated = 2.times.map do
      connection.exec_query("INSERT INTO uuid_v7_probe DEFAULT VALUES RETURNING public_id").first.fetch("public_id")
    end
    generated.each do |uuid|
      assert_match(/\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/, uuid)
    end
    assert_equal generated.length, generated.uniq.length
  end

  test "dumping the primary database preserves the portable committed schema" do
    stream = StringIO.new
    ActiveRecord::SchemaDumper.dump(ApplicationRecord.connection_pool, stream)

    assert_equal Rails.root.join("db/schema.rb").read, stream.string
  end
end
