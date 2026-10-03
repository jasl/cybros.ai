require "test_helper"

class ContentBodies::CloneSealedTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @creator = users(:member)
    DevModelLane.ensure_enabled!(@account)
  end

  test "identity cloning copies sealed references without re-addressing their payloads" do
    one_shot = OneShot.create!(
      account: @account, workspace: workspaces(:shared), creating_user: @creator,
      workload: "text_generation"
    )
    upload = @account.content_uploads.create!(
      creating_user: @creator,
      file: ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new("image bytes"), filename: "image.png", content_type: "image/png"
      )
    )
    source = ContentBodies::Replace.call(
      owner: one_shot, role: OneShots::Create::BODY_ROLE,
      entries: Nexus::InputEntries.for("hello"), uploads: [upload], seal: true
    ).body
    invocation = DevModelLane.create_invocation!(
      one_shot: one_shot,
      selection: DevModelLane.selection(workload: "text_generation", account: @account)
    )

    request = Nexus::ContentAddress.stub(:for, ->(**) { flunk "sealed content was re-addressed" }) do
      ContentBodies::CloneSealed.call(source: source, owner: invocation, role: "request")
    end

    refute_equal source.id, request.id
    assert_predicate request, :sealed?
    assert_equal source.readable_text, request.readable_text
    assert_equal source.content_body_entries.pluck(:content_fragment_id, :position),
      request.content_body_entries.pluck(:content_fragment_id, :position)
    assert_equal source.content_body_uploads.pluck(:content_upload_id),
      request.content_body_uploads.pluck(:content_upload_id)
  end
end
