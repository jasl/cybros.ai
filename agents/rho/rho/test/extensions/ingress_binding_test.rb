require_relative "ops_conversations_test"

class IngressBindingTest < Minitest::Test
  include RhoTest::OpsHarness

  def test_a_channel_binding_is_projected_and_refuses_browser_changes_until_the_channel_moves
    binding_path = File.join(@root, "binding.json")
    File.write(binding_path, JSON.generate("current" => "c-1"))
    extension_path = File.join(@root, "ingress.rb")
    File.write(extension_path, <<~RUBY)
      module BindingFixture
        NAME = "rho.test_ingress"
        def self.register(api)
          api.on(:conversation_binding) do |public_id|
            current = JSON.parse(File.read(#{binding_path.inspect})).fetch("current")
            { "channel" => "test", "label" => "Test channel" } if current == public_id
          end
        end
      end
    RUBY
    api = OpsConversationsTest::CatalogApi.new
    daemon = member_ready(boot(config: Rho::Config.from_hash({ "mode" => "agent", "plugins" => { "rho.test_ingress" => RhoTest.described_extension(extension_path, id: "rho.test_ingress") } })), api)

    detail = JSON.parse(request(daemon, :get, "/conversations/detail?public_id=c-1", token: bearer(daemon)).body)
    assert_equal [{ "extension" => "rho.test_ingress", "channel" => "test", "label" => "Test channel" }],
      detail.fetch("conversation").fetch("ingresses")

    status, body = browser_request(daemon, "PATCH", "/conversations", public_id: "c-1", title: "A stale browser write")
    assert_equal 409, status
    assert_equal "ingress_bound", body.dig(:error, :code)
    assert_empty api.writes

    # This is a product guard for the WebUI, not another Nexus permission.
    assert_equal "200", request(daemon, :patch, "/conversations", token: bearer(daemon),
      body: { public_id: "c-1", title: "An intentional operator change" }).code
    assert_equal 1, api.writes.length
    assert_equal 200, browser_request(daemon, "POST", "/followers/attach", public_id: "c-1", host_type: "conversation", live: false, stream: false).first
    assert_equal 200, browser_request(daemon, "POST", "/stop", public_id: "c-1", host_type: "conversation").first

    File.write(binding_path, JSON.generate("current" => "c-2"))
    detail = JSON.parse(request(daemon, :get, "/conversations/detail?public_id=c-1", token: bearer(daemon)).body)
    assert_empty detail.fetch("conversation").fetch("ingresses")
    assert_equal 200, browser_request(daemon, "PATCH", "/conversations", public_id: "c-1", title: "Editable again").first
    assert_equal "Editable again", api.writes.last.fetch("conversation").fetch("title")
  end

  private

    def browser_request(daemon, method, path, **body)
      message = json_request(body, token: bearer(daemon))
      message.headers["x-rho-viewing-conversation"] = ["c-1"]
      route(daemon, method, path).call(message)
    end
end
