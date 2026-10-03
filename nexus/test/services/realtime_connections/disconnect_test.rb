require "test_helper"

class RealtimeConnections::DisconnectTest < ActiveSupport::TestCase
  test "a user authority cut targets the user and stewarded agents" do
    human = users(:owner)
    audience = User.where(id: human.id).or(User.where(steward_id: human.id))
    expected = connection_identifiers(audience, reconnect: false)
    disconnected = capture_disconnected_connections do
      RealtimeConnections::Disconnect.user_authority(human)
    end

    assert_equal expected, disconnected
  end

  test "a workspace authority cut targets the account member audience" do
    workspace = workspaces(:shared)
    audience = User.where(account_id: workspace.account_id).members
    expected = connection_identifiers(audience, reconnect: true)
    disconnected = capture_disconnected_connections do
      RealtimeConnections::Disconnect.workspace_authority(workspace)
    end

    assert_equal expected, disconnected
  end

  test "a credential cut targets only that bearer connection" do
    token = create_access_token_fixture(user: users(:member), name: "Exact cable").token
    disconnected = capture_disconnected_connections do
      RealtimeConnections::Disconnect.credentials([token])
    end

    assert_equal [[token.user_id, token.id, true]], disconnected
  end

  private

    def capture_disconnected_connections
      disconnected = []
      remote_connections = Object.new
      # STRICT ON THE IDENTIFIER SET: Action Cable's `where` refuses a lookup that names fewer
      # identifiers than the connection declares, and a looser stub is exactly what hid that once.
      remote_connections.define_singleton_method(:where) do |current_user:, current_access_token:, current_executor_token:|
        raise "an executor identity on a member cut" unless current_executor_token.nil?

        remote_connection = Object.new
        remote_connection.define_singleton_method(:disconnect) do |reconnect:|
          disconnected << [current_user.id, current_access_token&.id, reconnect]
        end
        remote_connection
      end

      ActionCable.server.stub(:remote_connections, remote_connections) { yield }
      disconnected.sort_by { |user_id, token_id, _reconnect| [user_id, token_id.to_i] }
    end

    def connection_identifiers(users, reconnect:)
      cookie_connections = users.pluck(:id).map { |user_id| [user_id, nil, reconnect] }
      tokens = AccessToken.where(
        user_id: users.select(:id), credential_plane: :member, revoked_at: nil
      )
      tokens = tokens.where(expires_at: nil).or(tokens.where(expires_at: Time.current..))
      token_connections = tokens.pluck(:user_id, :id).map do |user_id, token_id|
        [user_id, token_id, reconnect]
      end
      (cookie_connections + token_connections).sort_by do |user_id, token_id|
        [user_id, token_id.to_i]
      end
    end
end
