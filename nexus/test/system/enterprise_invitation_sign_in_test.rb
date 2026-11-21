require "application_system_test_case"
require "puma"

class EnterpriseInvitationSignInTest < ApplicationSystemTestCase
  test "accept a mail-less invitation in Chromium using a provider with no public email" do
    server = Puma::Server.new(lambda do |env|
      request = Rack::Request.new(env)
      case request.path
      when "/authorize"
        callback = URI(request.params.fetch("redirect_uri"))
        callback.query = URI.encode_www_form(state: request.params.fetch("state"), code: "authorized")
        [302, { "location" => callback.to_s }, []]
      when "/token" then [200, { "content-type" => "application/json" }, [JSON.generate(token_type: "Bearer", access_token: "test-token")]]
      when "/user" then [200, { "content-type" => "application/json" }, [JSON.generate(id: 123, name: "Enterprise Worker")]]
      else [404, {}, []]
      end
    end)
    server.add_tcp_listener("127.0.0.1", 0)
    server.run
    issuer = "http://127.0.0.1:#{server.connected_ports.first}"
    provider = accounts(:cybros).sso_providers.create!(name: "Company", protocol: "oauth2",
      issuer: issuer, client_id: "nexus", client_secret: "test", enabled: true, scopes: "profile",
      authorization_endpoint: "#{issuer}/authorize", token_endpoint: "#{issuer}/token", userinfo_endpoint: "#{issuer}/user")
    invite = accounts(:cybros).invitations.create!(email: "new-person@example.org", inviter: users(:owner))

    visit join_url(token: invite.acceptance_token)
    assert_selector "meta[name=referrer][content=no-referrer]", visible: :all
    click_button "Continue with Company"
    assert_selector "h1", text: "Accept this Nexus invitation"
    fill_in "Your display name", with: "New Human"
    click_button "Confirm"
    assert_selector "main h1", text: "Overview"
    assert_equal invite.email, provider.sso_connections.sole.identity.email
  ensure
    server&.stop(true)
  end
end
