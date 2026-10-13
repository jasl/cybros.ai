require "application_system_test_case"

class WorkspaceManagementJourneyTest < ApplicationSystemTestCase
  test "confirm dialogs stay keyboard operable and Escape backs out safely" do
    workspace = workspaces(:shared)
    sign_in_directly(users(:owner))
    visit workspace_url(workspace.public_id)

    click_button "Archive"
    within("#turbo-confirm[open]") do
      assert_text "Archive Shared?"
      find(".modal-box button[value='cancel']").send_keys(:escape)
    end
    assert_no_selector "#turbo-confirm[open]"
    assert_no_text "Archive accepted"
    assert_predicate workspace.reload, :active?

    click_button "Archive"
    within("#turbo-confirm[open]") do
      find("button[value='confirm']").send_keys(:enter)
    end
    assert_text "Archive accepted"
    assert_equal "archived", workspace.reload.state
  end
end

class MobileWorkspaceManagementJourneyTest < MobileSystemTestCase
  test "workspace list and detail controls stay within the phone viewport" do
    workspaces(:shared).update!(access_mode: :private)
    sign_in_directly(users(:member))

    visit workspaces_url

    assert_text "No workspaces yet"
    assert_text "Create a workspace for your data"
    assert_link "New workspace"
    viewport_width = page.evaluate_script("document.documentElement.clientWidth")
    assert_operator page.evaluate_script("document.documentElement.scrollWidth"),
      :<=, viewport_width + 1, "the empty state must not scroll horizontally"

    owner = users(:owner)
    workspace = accounts(:cybros).workspaces.create!(
      creator: owner, owner: owner, name: "W" * Workspace::NAME_MAX_LENGTH
    )
    sign_in_directly(owner)
    visit workspace_url(workspace.public_id)

    assert_button "Archive"
    viewport_width = page.evaluate_script("document.documentElement.clientWidth")
    assert_operator page.evaluate_script("document.documentElement.scrollWidth"),
      :<=, viewport_width + 1, "the page must not scroll horizontally"
    bounds = page.evaluate_script(<<~JAVASCRIPT, find_button("Delete"))
      (() => {
        const rect = arguments[0].getBoundingClientRect()
        return { left: rect.left, right: rect.right }
      })()
    JAVASCRIPT
    assert_operator bounds.fetch("left"), :>=, 0
    assert_operator bounds.fetch("right"), :<=, viewport_width
  end
end
