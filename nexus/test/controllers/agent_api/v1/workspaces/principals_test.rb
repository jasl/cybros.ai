require "test_helper"

# THE PRINCIPALS LISTING (used by the `to`-addressing verbs): who may be named on a conversation's
# access carrier — every member User of the account with access to this workspace, of either kind,
# with the kernel's key (`public_id`) beside the words a person reads. An agent row names its
# steward, so an agent program can learn its own person's id from the one listing it already reads.
class AgentAPI::V1::Workspaces::PrincipalsTest < ActionDispatch::IntegrationTest
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @secret = create_access_token_fixture(user: @human, name: "Member").secret
  end

  def auth = { "Authorization" => "Bearer #{@secret}" }
  def principals_path(workspace) = "/agent_api/v1/workspaces/#{workspace.public_id}/principals"

  test "lists every member with access to the workspace, by display name, never the system user" do
    get principals_path(workspaces(:shared)), headers: auth

    assert_response :success
    rows = response.parsed_body.fetch("principals")
    assert_equal ["Curator", "Fixture Agent", "Member", "Owner"], rows.map { |row| row["display_name"] }
    agent = rows.find { |row| row["kind"] == "agent" }
    assert_equal({
      "public_id" => users(:agent).public_id, "handle" => "fixture-agent", "kind" => "agent",
      "display_name" => "Fixture Agent", "agent_identifier" => "fixture-agent-installation",
      "steward_public_id" => users(:owner).public_id,
    }, agent)
    member = rows.find { |row| row["public_id"] == @human.public_id }
    assert_equal({ "public_id" => @human.public_id, "handle" => "member", "kind" => "human", "display_name" => "Member",
                   "agent_identifier" => nil, "steward_public_id" => nil }, member)
    assert_not rows.any? { |row| row["display_name"] == "System" }
  end

  test "a private workspace lists its owner and the owner's agents alone; no access is absence" do
    get principals_path(workspaces(:dedicated)), headers: auth
    assert_response :not_found, "a private workspace the caller cannot browse is absence"

    @secret = create_access_token_fixture(user: users(:owner), name: "Owner").secret
    get principals_path(workspaces(:dedicated)), headers: auth
    assert_response :success
    assert_equal ["Fixture Agent", "Owner"], response.parsed_body.fetch("principals").map { |row| row["display_name"] }

    users(:agent).update_column(:status, "suspended")
    get principals_path(workspaces(:dedicated)), headers: auth
    assert_equal ["Owner"], response.parsed_body.fetch("principals").map { |row| row["display_name"] },
      "a suspended agent has no access and is not a principal here"
  end
end
