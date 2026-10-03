require "test_helper"

class ConversationCloseTest < Minitest::Test
  Api = Struct.new(:host, :log, keyword_init: true)
  Host = Struct.new(:home, keyword_init: true)
  Home = Struct.new(:root, keyword_init: true)

  def test_closing_a_conversation_during_restart_does_not_publish_an_unowned_transport
    transports = []
    entered = Queue.new
    release = Queue.new
    server = McpTest::FixtureServer.build(tools: ["echo"])
    Rho::Mcp.transport_factory = lambda do |_row, read_timeout:, oauth: nil|
      McpTest::FakeTransport.new(server).tap do |transport|
        transport.read_timeout = read_timeout
        transports << transport
        next if transports.length == 1

        original = transport.method(:connect)
        transport.define_singleton_method(:connect) do |client_info:, protocol_version: nil, capabilities: {}, mode: :legacy|
          entered << :connecting
          release.pop
          original.call(client_info: client_info, protocol_version: protocol_version, capabilities: capabilities, mode: mode)
        end
      end
    end
    api = Api.new(host: Host.new(home: Home.new(root: Dir.tmpdir)))
    set = Rho::Mcp::Conversations.open("conversation", [{ "name" => "fx", "command" => "ruby", "args" => [] }], api: api)
    tool = set.classes.fetch(0)
    transports.fetch(0).die!(status: 1)
    worker = Thread.new do
      Rho::Runner::ExecutionContext.with(Rho::Runner::ExecutionContext.new(task_key: "echo")) do
        tool.new(env: nil).call({ "text" => "late answer" })
      end
    rescue StandardError => error
      error
    end

    starting = entered.pop(timeout: 5)
    assert_equal :connecting, starting, worker.join(0) ? worker.value.inspect : "restart is waiting"
    set.close
    assert_predicate set, :closed?
    assert_empty Rho::Mcp.conversations
    release << :continue
    assert worker.join(5), "the in-flight restart completed"

    assert_equal 1, transports.fetch(1).closes, "the replacement acquired after the owner's close must be torn down"
    refute_predicate transports.fetch(1), :connected?
    assert_kind_of Rho::Mcp::Closed, worker.value, "the retired connection cannot answer through the old tool"
    assert_raises(Rho::Mcp::Closed) { set.entries.fetch(0).connection.open! }
    assert_equal 2, transports.length, "close is terminal: reopening acquires no resource"
  ensure
    release&.push(:continue)
    worker&.join(5)
    transports&.each(&:close)
    Rho::Mcp.reset!
  end
end
