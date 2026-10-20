require "test_helper"

class Nexus::ForeignKeyViolationTest < ActiveSupport::TestCase
  %w[23503 23001].each do |sqlstate|
    test "SQLSTATE #{sqlstate} matches only the expected foreign key" do
      error = database_error(sqlstate)

      assert Nexus::ForeignKeyViolation.matches?(error, constraint: "retained_parent")
      assert_not Nexus::ForeignKeyViolation.matches?(error, constraint: "another_parent")
      assert_equal 1, ApplicationRecord.lease_connection.select_value("SELECT 1"),
        "the error's savepoint must leave the outer transaction usable"
    end
  end

  test "another database error with the same constraint name does not match" do
    error = database_error("23505")

    assert_not Nexus::ForeignKeyViolation.matches?(error, constraint: "retained_parent")
  end

  test "an error without a PostgreSQL cause does not match" do
    error = ActiveRecord::StatementInvalid.new("unrelated failure")

    assert_not Nexus::ForeignKeyViolation.matches?(error, constraint: "retained_parent")
  end

  private

    # Exercise pg's SQLSTATE classes and Rails' real exception translation
    # for both supported server responses, independent of the local version.
    def database_error(sqlstate)
      assert_raises(ActiveRecord::StatementInvalid) do
        ApplicationRecord.transaction(requires_new: true) do
          ApplicationRecord.lease_connection.execute(<<~SQL)
            DO $$ BEGIN
              RAISE EXCEPTION USING
                ERRCODE = '#{sqlstate}',
                MESSAGE = 'referenced parent',
                CONSTRAINT = 'retained_parent';
            END $$;
          SQL
        end
      end
    end
end
