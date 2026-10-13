require "test_helper"

class ConnectionStartupCancellationTest < Minitest::Test
  include McpTest::Helpers

  def test_canceling_the_startup_thread_reaps_the_child_acquired_before_publication
    row = McpTest.real_row(args: ["sleep"])
    transport = nil
    factory = McpTest.real_transport_factory
    connection = Rho::Mcp::Connection.new(row, transport_factory: lambda do |entry, **options|
      transport = factory.call(entry, **options)
    end)
    worker = Thread.new { connection.open! }
    assert await { transport&.pid }, "the real child was acquired during startup"
    group = transport.group_pid
    assert process_group_alive?(group)

    worker.kill
    assert worker.join(5), "the interrupted startup releases its child within the normal close bound"
    refute process_group_alive?(group), "no unannounced child outlives its startup owner"
    refute_predicate connection, :connected?
  ensure
    worker&.kill
    worker&.join(5)
    connection&.close
    transport&.kill
  end
end
