require "test_helper"

# db/cable_schema.rb is the ONLY source of the production cable database's
# shape — there is no cable_migrate directory. An unrelated 2026-08-15
# re-dump emptied it to version 0 and nothing noticed until the re-audit,
# because development runs the async adapter and test runs the test
# adapter: the one environment that reads this file is a fresh production
# deploy, where a missing table kills the first broadcast and the hourly
# trim. This pin makes the loss loud.
class CableSchemaTest < ActiveSupport::TestCase
  test "the cable schema still creates the messages table Solid Cable needs" do
    schema = File.read(Rails.root.join("db/cable_schema.rb"))

    assert_includes schema, 'create_table "solid_cable_messages"',
      "production cable (config/cable.yml: solid_cable, writing: cable) loads its shape " \
      "from this file alone"
    assert_includes schema, '"channel_hash"'
    assert_not_includes schema, "version: 0",
      "an empty re-dump is exactly the loss this pin exists to catch"
  end
end
