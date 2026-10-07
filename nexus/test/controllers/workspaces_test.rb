require "test_helper"

# The member-facing Workspace console: reads resolve inside the effective-access relation where a
# miss conceals like absence, management is active-Human-owner-only with no administrator bypass,
# forms carry render-time lock_version, and dedication renders only a generic Agent-workspace badge
# — never the identifier.
class WorkspacesTest < ActionDispatch::IntegrationTest
  setup do
    @owner = users(:owner)
    @member = users(:member)
    @shared = workspaces(:shared)
    @personal = workspaces(:personal)
    @dedicated = workspaces(:dedicated)
    sign_in_as @owner
  end

  test "the index lists live workspaces and keeps the archived recycle bin separate" do
    archived = ::Workspaces::Create.call(creator: @owner, name: "Old notes").workspace
    ::Workspaces::Archive.call(workspace: archived, by: @owner, lock_version: archived.lock_version)

    get workspaces_path

    assert_response :success
    assert_select "tr[data-workspace-id='#{@shared.public_id}']"
    assert_select "tr[data-workspace-id='#{@dedicated.public_id}']"
    assert_select "tr[data-workspace-id='#{@personal.public_id}']", count: 0
    assert_select "tr[data-workspace-id='#{archived.public_id}']", count: 0

    get workspaces_path(tab: "archived")

    assert_response :success
    assert_select "tr[data-workspace-id='#{archived.public_id}']", text: /Archiving/
    assert_select "tr[data-workspace-id='#{@shared.public_id}']", count: 0
  end

  test "a dedicated workspace renders a generic agent badge and never the identifier" do
    get workspaces_path

    assert_response :success
    assert_select "tr[data-workspace-id='#{@dedicated.public_id}']", text: /Agent workspace/
    assert_no_match @dedicated.agent_identifier, response.body

    get workspace_path(@dedicated.public_id)

    assert_response :success
    assert_select "body", text: /Agent workspace/
    assert_no_match @dedicated.agent_identifier, response.body
  end

  test "the empty live list offers creation alongside agent-created workspaces" do
    @shared.update!(access_mode: :private)
    sign_out
    sign_in_as @member

    get workspaces_path

    assert_response :success
    assert_select "body", text: /Create a workspace for your data/
    assert_select "a[href=?]", new_workspace_path, text: "New workspace"
    assert_select "form[action=?]", workspaces_path, count: 0
  end

  test "another member's private workspace is not found rather than forbidden" do
    sign_out
    sign_in_as @member

    get workspace_path(@personal.public_id)
    assert_response :not_found
    get edit_workspace_path(@personal.public_id)
    assert_response :not_found
    post workspace_archival_path(@personal.public_id), params: { command: { lock_version: 0 } }
    assert_response :not_found
  end

  test "an administrator gains no bypass into another member's private workspace" do
    get workspace_path(@personal.public_id)
    assert_response :not_found
    get workspace_ownership_transfer_path(@personal.public_id)
    assert_response :not_found
    patch workspace_access_mode_path(@personal.public_id),
      params: { access_mode: { access_mode: "account_wide", lock_version: 0 } }
    assert_response :not_found
    assert_predicate @personal.reload, :private?
  end

  test "an account-wide reader without ownership reads but cannot manage" do
    @shared.update!(metadata: { "owner_only" => true })
    sign_out
    sign_in_as @member

    get workspace_path(@shared.public_id)
    assert_response :success
    assert_select "form[action=?]", workspace_archival_path(@shared.public_id), count: 0
    assert_select "body", text: /Only the workspace owner/

    get edit_workspace_path(@shared.public_id)
    assert_redirected_to workspace_path(@shared.public_id)
    assert_equal I18n.t("workspaces.not_owner"), flash[:alert]

    patch workspace_path(@shared.public_id),
      params: {
        workspace: {
          name: "Hijacked",
          metadata: JSON.generate({ "owner_only" => false }),
          lock_version: @shared.lock_version,
        },
      }
    assert_redirected_to workspace_path(@shared.public_id)
    assert_equal I18n.t("workspaces.not_owner"), flash[:alert]
    assert_equal "Shared", @shared.reload.name
    assert_equal({ "owner_only" => true }, @shared.metadata)

    post workspace_archival_path(@shared.public_id),
      params: { command: { lock_version: @shared.lock_version } }
    assert_redirected_to workspace_path(@shared.public_id)
    assert_equal I18n.t("workspaces.not_owner"), flash[:alert]
    assert_predicate @shared.reload, :active?

    get workspace_ownership_transfer_path(@shared.public_id)
    assert_redirected_to workspace_path(@shared.public_id)
    assert_equal I18n.t("workspaces.not_owner"), flash[:alert]
  end

  test "name and metadata round-trip through the edit form" do
    patch workspace_path(@shared.public_id),
      params: {
        workspace: {
          name: "Renamed",
          metadata: JSON.generate({ "topic" => "research", "reviewed" => true }),
          lock_version: @shared.lock_version,
        },
      }

    assert_redirected_to workspace_path(@shared.public_id)
    assert_equal I18n.t("workspaces.update.updated"), flash[:notice]
    assert_equal "Renamed", @shared.reload.name
    assert_equal({ "topic" => "research", "reviewed" => true }, @shared.metadata)
  end

  test "the edit form renders the current metadata object" do
    @shared.update!(metadata: { "topic" => "research", "reviewed" => true })

    get edit_workspace_path(@shared.public_id)

    assert_response :success
    assert_select "textarea[name='workspace[metadata]']", text: /"topic": "research"/
    assert_select "textarea[name='workspace[metadata]']", text: /"reviewed": true/
  end

  test "a stale edit re-renders with the current row, submitted input, and a refreshed lock" do
    patch workspace_path(@shared.public_id),
      params: {
        workspace: {
          name: "Renamed",
          metadata: JSON.generate({ "committed" => true }),
          lock_version: @shared.lock_version,
        },
      }
    assert_equal "Renamed", @shared.reload.name

    submitted_metadata = <<~JSON.strip
      {
        "second_attempt": true
      }
    JSON
    patch workspace_path(@shared.public_id),
      params: {
        workspace: {
          name: "Second attempt",
          metadata: submitted_metadata,
          lock_version: 0,
        },
      }

    assert_response :conflict
    assert_select "input[name='workspace[name]'][value='Second attempt']"
    assert_select "textarea[name='workspace[metadata]']", text: submitted_metadata
    assert_select "input[type=hidden][name='workspace[lock_version]'][value=?]",
      @shared.reload.lock_version.to_s
    assert_select "h1", text: "Edit workspace"
    assert_select "body", text: /Renamed/
    assert_select "[role=alert]", text: /changed elsewhere/
    assert_equal "Renamed", @shared.reload.name
    assert_equal({ "committed" => true }, @shared.metadata)
  end

  test "invalid fields re-render with their errors and submitted values" do
    oversized_metadata = JSON.generate(
      { "payload" => "x" * Nexus::SizeBounds.fetch(:workspace_metadata_bound) }
    )

    patch workspace_path(@shared.public_id),
      params: {
        workspace: {
          name: "",
          metadata: oversized_metadata,
          lock_version: @shared.lock_version,
        },
      }

    assert_response :unprocessable_entity
    assert_select "input[name='workspace[name]'][value='']"
    assert_select "textarea[name='workspace[metadata]']", text: oversized_metadata
    assert_select "p.field-error", text: /Name/
    assert_select "p.field-error", text: /size bound/
    assert_select "input[type=hidden][name='workspace[lock_version]'][value=?]",
      @shared.reload.lock_version.to_s
    assert_equal "Shared", @shared.reload.name
    assert_equal({}, @shared.metadata)
  end

  test "an invalid edit does not adopt a concurrent update's lock version" do
    submitted_lock_version = @shared.lock_version
    invalid_workspace = @shared.dup
    invalid_workspace.name = ""
    invalid_workspace.validate
    invalid_result = ::Workspaces::Mutation::Result.invalid(invalid_workspace)

    ::Workspaces::Update.stub(:call, lambda { |**|
      @shared.update!(name: "Concurrent edit")
      invalid_result
    }) do
      patch workspace_path(@shared.public_id),
        params: {
          workspace: {
            name: "",
            metadata: JSON.generate({ "submitted" => true }),
            lock_version: submitted_lock_version,
          },
        }
    end

    assert_response :unprocessable_entity
    assert_select "body", text: /Concurrent edit/
    assert_select "input[name='workspace[name]'][value='']"
    assert_select "textarea[name='workspace[metadata]']", text: /"submitted":true/
    assert_select "input[type=hidden][name='workspace[lock_version]'][value=?]",
      submitted_lock_version.to_s
    assert_equal "Concurrent edit", @shared.reload.name
  end

  test "malformed metadata JSON is rejected without losing the submitted text" do
    submitted_lock_version = @shared.lock_version
    @shared.update!(name: "Concurrent edit")
    submitted_metadata = %({"unfinished":)

    patch workspace_path(@shared.public_id),
      params: {
        workspace: {
          name: "Still shared",
          metadata: submitted_metadata,
          lock_version: submitted_lock_version,
        },
      }

    assert_response :unprocessable_entity
    assert_select "body", text: /Concurrent edit/
    assert_select "input[name='workspace[name]'][value='Still shared']"
    assert_select "textarea[name='workspace[metadata]']", text: submitted_metadata
    assert_select "p.field-error", text: /valid JSON object/
    assert_select "input[type=hidden][name='workspace[lock_version]'][value=?]",
      submitted_lock_version.to_s
    assert_equal "Concurrent edit", @shared.reload.name
    assert_equal({}, @shared.metadata)

    patch workspace_path(@shared.public_id),
      params: {
        workspace: {
          name: "Still shared",
          metadata: JSON.generate({ "corrected" => true }),
          lock_version: submitted_lock_version,
        },
      }

    assert_response :conflict
    assert_select "input[type=hidden][name='workspace[lock_version]'][value=?]",
      @shared.reload.lock_version.to_s
    assert_equal "Concurrent edit", @shared.name
    assert_equal({}, @shared.metadata)
  end

  test "metadata JSON must decode to an object" do
    patch workspace_path(@shared.public_id),
      params: {
        workspace: {
          name: "Still shared",
          metadata: "[1, 2]",
          lock_version: @shared.lock_version,
        },
      }

    assert_response :unprocessable_entity
    assert_select "textarea[name='workspace[metadata]']", text: "[1, 2]"
    assert_select "p.field-error", text: /JSON object/
    assert_equal "Shared", @shared.reload.name
    assert_equal({}, @shared.metadata)
  end

  test "a rename outside the active state is refused with the not-active alert" do
    ::Workspaces::Archive.call(workspace: @shared, by: @owner, lock_version: @shared.lock_version)

    patch workspace_path(@shared.public_id),
      params: { workspace: { name: "Too late", lock_version: @shared.reload.lock_version } }

    assert_redirected_to workspace_path(@shared.public_id)
    assert_equal I18n.t("workspaces.not_active"), flash[:alert]
    assert_equal "Shared", @shared.reload.name
  end

  test "the access mode form round-trips" do
    patch workspace_access_mode_path(@shared.public_id),
      params: { access_mode: { access_mode: "private", lock_version: @shared.lock_version } }

    assert_redirected_to workspace_path(@shared.public_id)
    assert_equal I18n.t("workspaces.access_modes.update.updated"), flash[:notice]
    assert_predicate @shared.reload, :private?
  end

  test "a stale access-mode change re-renders the workspace preserving the selection" do
    patch workspace_access_mode_path(@shared.public_id),
      params: { access_mode: { access_mode: "private", lock_version: 99 } }

    assert_response :conflict
    assert_select "h1", text: "Shared"
    assert_select "select[name='access_mode[access_mode]'] option[value=?][selected=?]",
      "private", "selected"
    assert_select "input[type=hidden][name='access_mode[lock_version]'][value=?]",
      @shared.reload.lock_version.to_s
    assert_select "[role=alert]", text: /changed elsewhere/
    assert_predicate @shared.reload, :account_wide?
  end

  test "lifecycle acceptance says accepted and the state converges honestly" do
    post workspace_archival_path(@shared.public_id),
      params: { command: { lock_version: @shared.lock_version } }

    assert_redirected_to workspace_path(@shared.public_id)
    assert_match(/accepted/i, flash[:notice])
    assert_equal "archived", @shared.reload.state

    get workspace_path(@shared.public_id)
    assert_response :success
    assert_select "form[action=?]", workspace_restoration_path(@shared.public_id) do
      assert_select "input[type=hidden][name='command[lock_version]'][value=?]",
        @shared.lock_version.to_s
      assert_select "button", text: "Restore"
    end

    post workspace_restoration_path(@shared.public_id),
      params: { command: { lock_version: @shared.lock_version } }

    assert_redirected_to workspace_path(@shared.public_id)
    assert_match(/accepted/i, flash[:notice])
    assert_equal "active", @shared.reload.state
  end

  test "input-free commands recover from stale through PRG with the changed-elsewhere alert" do
    post workspace_archival_path(@shared.public_id), params: { command: { lock_version: 999 } }

    assert_redirected_to workspace_path(@shared.public_id)
    assert_equal I18n.t("workspaces.changed_elsewhere"), flash[:alert]
    assert_predicate @shared.reload, :active?
  end

  test "archiving an already archived workspace reports the state without a false accept" do
    ::Workspaces::Archive.call(workspace: @shared, by: @owner, lock_version: @shared.lock_version)
    ::Workspaces::CompleteTransition.call(workspace: @shared)

    post workspace_archival_path(@shared.public_id),
      params: { command: { lock_version: @shared.reload.lock_version } }

    assert_redirected_to workspace_path(@shared.public_id)
    assert_equal I18n.t("workspaces.archivals.create.already_archived"), flash[:notice]
    assert_equal "archived", @shared.reload.state
  end

  test "deletion tombstones the workspace and the tombstone reads as absence" do
    delete workspace_deletion_path(@shared.public_id),
      params: { command: { lock_version: @shared.lock_version } }

    assert_redirected_to workspaces_path
    assert_match(/accepted/i, flash[:notice])
    assert_equal "deleted", @shared.reload.state

    get workspace_path(@shared.public_id)
    assert_response :not_found

    get workspaces_path
    assert_select "tr[data-workspace-id='#{@shared.public_id}']", count: 0

    get workspaces_path(tab: "archived")
    assert_select "tr[data-workspace-id='#{@shared.public_id}']", count: 0
  end

  test "the ownership picker lists active same-account humans except the current owner" do
    suspended = users(:curator)
    suspended.suspend

    get workspace_ownership_transfer_path(@shared.public_id)

    assert_response :success
    assert_select "form[action=?]", workspace_ownership_transfer_path(@shared.public_id) do
      assert_select "input[name='query']"
      assert_select "input[type=submit][value='Search']"
    end
    assert_select "[data-transfer-candidate-id='#{@member.public_id}']"
    assert_select "[data-transfer-candidate-id='#{@member.public_id}']" do
      assert_select "button[data-turbo-confirm]", text: "Transfer"
      assert_select "input[name='ownership_transfer[target_user_public_id]'][value=?]",
        @member.public_id
      assert_select "input[name='ownership_transfer[lock_version]'][value=?]",
        @shared.lock_version.to_s
    end
    assert_select "[data-transfer-candidate-id='#{@owner.public_id}']", count: 0
    assert_select "[data-transfer-candidate-id='#{suspended.public_id}']", count: 0
    assert_select "[data-transfer-candidate-id='#{users(:agent).public_id}']", count: 0
  end

  test "the ownership picker searches by name or email like the steward picker" do
    get workspace_ownership_transfer_path(@shared.public_id, query: "member@")

    assert_response :success
    assert_select "[data-transfer-candidate-id='#{@member.public_id}']"
    assert_select "[data-transfer-candidate-id='#{users(:curator).public_id}']", count: 0
  end

  test "a crafted self-transfer is rejected by the domain with a visible refusal" do
    post workspace_ownership_transfer_path(@shared.public_id), params: {
      ownership_transfer: {
        target_user_public_id: @owner.public_id, lock_version: @shared.lock_version,
      },
    }

    assert_response :unprocessable_entity
    assert_select "[role=alert]",
      text: /#{Regexp.escape(I18n.t("workspaces.ownership_transfers.create.target_not_eligible"))}/
    assert_equal @owner, @shared.reload.owner
  end

  test "ownership transfer hands the workspace over and creator attribution stays" do
    post workspace_ownership_transfer_path(@shared.public_id), params: {
      ownership_transfer: {
        target_user_public_id: @member.public_id, lock_version: @shared.lock_version,
      },
    }

    assert_redirected_to workspaces_path
    assert_equal I18n.t("workspaces.ownership_transfers.create.transferred"), flash[:notice]
    assert_equal @member, @shared.reload.owner
    assert_equal @owner, @shared.creator

    get workspace_path(@shared.public_id)
    assert_response :success
    assert_select "body", text: /Only the workspace owner can manage it/
    assert_select "form[action=?]", workspace_archival_path(@shared.public_id), count: 0

    sign_out
    sign_in_as @member
    get workspace_path(@shared.public_id)
    assert_response :success
    assert_select "form[action=?]", workspace_archival_path(@shared.public_id)
  end

  test "a stale transfer re-renders the picker preserving the search query" do
    post workspace_ownership_transfer_path(@shared.public_id), params: {
      ownership_transfer: {
        target_user_public_id: @member.public_id, lock_version: 999, query: "Mem",
      },
    }

    assert_response :conflict
    assert_select "input[name='query'][value='Mem']"
    assert_select "[data-transfer-candidate-id='#{@member.public_id}']"
    assert_select "[role=alert]", text: /changed elsewhere/
    assert_equal @owner, @shared.reload.owner
  end

  test "management forms carry the render-time lock version" do
    get workspace_path(@shared.public_id)

    assert_response :success
    assert_select "a[href=?]", edit_workspace_path(@shared.public_id), text: "Edit details"
    assert_select "a[href=?]", workspace_ownership_transfer_path(@shared.public_id),
      text: "Transfer ownership"
    assert_select "form[action=?]", workspace_access_mode_path(@shared.public_id) do
      assert_select "select[name='access_mode[access_mode]']"
      assert_select "input[name='access_mode[lock_version]'][value=?]",
        @shared.lock_version.to_s
    end
    assert_select "form[action=?]", workspace_archival_path(@shared.public_id) do
      assert_select "input[type=hidden][name='command[lock_version]'][value=?]",
        @shared.lock_version.to_s
      assert_select "button[data-turbo-confirm]", text: "Archive"
    end
    assert_select "form[action=?]", workspace_deletion_path(@shared.public_id) do
      assert_select "input[type=hidden][name='command[lock_version]'][value=?]",
        @shared.lock_version.to_s
      assert_select "button[data-turbo-confirm]", text: "Delete"
    end
  end

  test "the surface requires an authenticated human" do
    sign_out
    get workspaces_path
    assert_redirected_to new_session_path(return_to: workspaces_path)
  end
end
