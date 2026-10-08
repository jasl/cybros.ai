require "test_helper"

class ApiKeysetPaginationTest < Minitest::Test
  WORKSPACE_ID = "019f0000-0000-7000-8000-000000000101".freeze
  CONVERSATION_ID = "019f0000-0000-7000-8000-000000000201".freeze
  CURSOR = "opaque-descending-page".freeze

  def test_every_ordinary_list_forwards_the_direction_with_its_opaque_continuation
    lists.each do |name, collection, read|
      client, transport = client_for(collection)
      page = read.call(client, { order: "desc", after: CURSOR, limit: 2 })

      assert_empty page.items, name
      assert_nil page.next_after, name
      assert_equal({ "order" => "desc", "after" => CURSOR, "limit" => 2 },
        transport.requests.fetch(0).fetch(:params), name)
    end
  end

  def test_omitting_the_direction_keeps_the_servers_default
    lists.each do |name, collection, read|
      client, transport = client_for(collection)
      read.call(client, {})

      assert_nil transport.requests.fetch(0).fetch(:params), name
    end
  end

  private

    def client_for(collection)
      body = { collection => [], "pagination" => { "next_after" => nil, "last_cursor" => CURSOR } }
      transport = CybrosAgentTest::FakeTransport.new([[200, {}, body]])
      client = CybrosAgent::Client.new(base_url: "http://example.test", credential: "member", transport: transport)
      [client, transport]
    end

    def lists
      [
        ["workspaces", "workspaces", ->(client, options) { client.workspaces.list(**options) }],
        ["conversations", "conversations", ->(client, options) { client.workspace(WORKSPACE_ID).conversations.list(**options) }],
        ["archived conversations", "conversations", ->(client, options) { client.workspace(WORKSPACE_ID).conversations.archived(**options) }],
        ["children", "conversations", ->(client, options) { chat(client).children(**options) }],
        ["inferences", "inference_requests", ->(client, options) { client.workspace(WORKSPACE_ID).inference_requests.list(**options) }],
        ["schedules", "schedules", ->(client, options) { chat(client).schedules.list(**options) }],
        ["executions", "executions", ->(client, options) { chat(client).schedules.executions("schedule-1", **options) }],
        ["profile store", "store_entries", ->(client, options) { client.profile.store_entries.list(**options) }],
        ["workspace store", "store_entries", ->(client, options) { client.workspace(WORKSPACE_ID).store_entries.list(**options) }],
        ["conversation store", "store_entries", ->(client, options) { chat(client).store_entries.list(**options) }],
        ["runs", "runs", ->(client, options) { client.workspace(WORKSPACE_ID).runs.list(**options) }],
      ]
    end

    def chat(client) = client.workspace(WORKSPACE_ID).conversation(CONVERSATION_ID)
end
