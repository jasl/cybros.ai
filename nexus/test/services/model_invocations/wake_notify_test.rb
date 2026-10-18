require "test_helper"

# The reactor's wake channel, heard by a real LISTEN connection: the notify
# rides the transaction's after_commit, so a commit delivers it and a
# rollback delivers nothing. Non-transactional on purpose — a notification
# cannot cross out of a wrapped test transaction.
class ModelInvocations::WakeNotifyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "a committed wake reaches the listener and a rolled-back one does not" do
    with_listener do |listener|
      ApplicationRecord.transaction do
        ModelInvocations::Wake.notify_runner_after_commit
      end
      assert notified?(listener), "the commit delivers the edge"

      ApplicationRecord.transaction do
        ModelInvocations::Wake.notify_runner_after_commit
        raise ActiveRecord::Rollback
      end
      assert_not notified?(listener), "a rolled-back claim wakes nobody"
    end
  end

  private

    def with_listener
      config = ActiveRecord::Base.connection_db_config.configuration_hash
      connection = PG.connect(
        host: config[:host], port: config[:port], dbname: config[:database],
        user: config[:username], password: config[:password]
      )
      connection.exec("LISTEN #{ModelInvocations::Wake::NOTIFY_CHANNEL}")
      yield connection
    ensure
      connection&.close
    end

    def notified?(listener)
      !listener.wait_for_notify(1).nil?
    end
end
