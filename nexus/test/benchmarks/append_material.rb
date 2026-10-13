require "test_helper"

class AppendMaterialBenchmark < ActiveSupport::TestCase
  test "measure the uncompressed authoring material array" do
    [32, 256, 4096].each do |count|
      [16, 64].each do |length|
        keys = Array.new(count) { |index| "task-#{index}".ljust(length, "x") }
        quoted = keys.map { |key| ApplicationRecord.connection.quote(key) }.join(",")
        bytes = ApplicationRecord.connection.select_value(
          "SELECT pg_column_size(ARRAY[#{quoted}]::character varying[])"
        )
        assert_operator bytes, :>, count * length
        puts({ keys: count, key_bytes: length, array_bytes: bytes }.to_json)
      end
    end
  end
end
