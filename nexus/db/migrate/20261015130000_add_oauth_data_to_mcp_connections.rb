class AddOAuthDataToMcpConnections < ActiveRecord::Migration[8.1]
  def change
    add_column :mcp_connections, :oauth_data, :text
  end
end
