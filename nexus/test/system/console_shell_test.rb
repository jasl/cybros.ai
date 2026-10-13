require "application_system_test_case"

class ConsoleShellTest < ApplicationSystemTestCase
  setup do
    @user = users(:member)
    sign_in_directly(@user)
    visit root_url
    assert_text "Signed in as #{@user.email}"
  end

  test "user menu keeps inside clicks open and closes accessibly" do
    assert_no_button "Sign out"

    open_user_menu
    # Scope to the popup: the summary row also shows the email, so an
    # unscoped assertion could not catch a broken identity header.
    within "aside .dropdown-content" do
      assert_text @user.email
      assert_button "Sign out"
    end

    find("aside .dropdown-content p", text: @user.email).click
    assert_selector "aside details[open]"

    # Escape while focus is deep inside the menu must close it and hand
    # focus back to the trigger, not strand it on <body>.
    close_user_menu_with_escape(from: find("aside .dropdown-content form button"))
    assert_no_button "Sign out"
    assert_focused "aside details > summary",
      "focus should return to the user menu trigger after Escape"

    open_user_menu
    within("aside") { assert_button "Sign out" }

    close_user_menu_by_outside_click
    assert_no_button "Sign out"
  end

  test "desktop sidebar persists its collapse state across requests" do
    within "aside" do
      assert_link "Dashboard"
      assert_link "Settings"
      assert_no_link "Administration"
    end
    assert_no_button "Open sidebar"
    # Pin the authenticated layout's Turbo cache opt-out: history restores
    # must revalidate against the server.
    assert_selector "meta[name='turbo-cache-control'][content='no-cache']", visible: false

    click_button "Collapse sidebar"
    assert_no_link "Dashboard"
    assert_button "Expand sidebar"

    visit root_url
    assert_text "Signed in as #{@user.email}"
    assert_no_link "Dashboard"

    click_button "Expand sidebar"
    within "aside" do
      assert_link "Dashboard"
    end
    assert_no_button "Expand sidebar"

    # Expanding must persist too: a fresh request re-renders from the cookie.
    visit root_url
    assert_text "Signed in as #{@user.email}"
    within "aside" do
      assert_link "Dashboard"
    end
    assert_no_button "Expand sidebar"
  end
end

class ConsoleShellSettingsAndThemeTest < ApplicationSystemTestCase
  setup do
    @user = users(:member)
    sign_in_directly(@user)
    visit root_url
    assert_text "Signed in as #{@user.email}"
  end

  test "the appearance menu pins a theme that survives a fresh request" do
    open_user_menu
    click_button "Dark"
    assert page.evaluate_script("document.documentElement.dataset.theme === 'dark'")

    visit root_url
    assert_text "Signed in as #{@user.email}"
    assert page.evaluate_script("document.documentElement.dataset.theme === 'dark'"),
      "the server should render the pinned theme on a fresh request"

    open_user_menu
    click_button "System"
    assert page.evaluate_script("!('theme' in document.documentElement.dataset)")
  end
end

class MobileConsoleShellTest < MobileSystemTestCase
  setup do
    @user = users(:member)
    sign_in_directly(@user)
    visit root_url
    assert_text "Signed in as #{@user.email}"
    assert_selector "header.navbar"
  end

  test "mobile drawer preserves interaction, focus, navigation, and breakpoint semantics" do
    assert_no_link "Dashboard"

    open_mobile_sidebar
    within "aside" do
      assert_link "Dashboard"
    end

    open_user_menu
    within "aside" do
      assert_button "Sign out"
    end

    close_mobile_sidebar_via_overlay
    assert_no_link "Dashboard"

    opener = find_button "Open sidebar"
    opener.send_keys(:enter)
    wait_for_drawer(open: true)

    assert_focused "[data-sidebar-target=closer]", "opening the drawer should focus its close button"
    assert page.evaluate_script("document.querySelector('[data-sidebar-target=content]').inert")
    find_button("Close sidebar").send_keys([:shift, :tab])
    assert_focused "[data-sidebar-target=side] *",
      "keyboard focus should stay inside the open drawer while page content is inert"
    assert_not page.evaluate_script("document.querySelector('[data-sidebar-target=side]').inert")
    assert_equal "true", find_button("Open sidebar", visible: :all)["aria-expanded"]
    find_button("Close sidebar").send_keys(:space)
    wait_for_drawer(open: false)

    assert_focused "[data-sidebar-target=opener]",
      "closing the drawer should restore focus to its opener"
    assert_not page.evaluate_script("document.querySelector('[data-sidebar-target=content]').inert")
    assert page.evaluate_script("document.querySelector('[data-sidebar-target=side]').inert")
    assert_equal "false", find_button("Open sidebar")["aria-expanded"]

    find_button("Open sidebar").send_keys(:space)
    wait_for_drawer(open: true)
    find_button("Close sidebar").send_keys(:enter)
    wait_for_drawer(open: false)

    open_mobile_sidebar
    click_link "Dashboard"

    # The drawer link disappearing is what proves the post-navigation reset;
    # it cannot pass before the Turbo body swap replaces the checkbox.
    assert_no_link "Dashboard"
    assert_text "Signed in as #{@user.email}"
    assert_button "Open sidebar"

    page.driver.browser.manage.add_cookie(name: "sidebar_collapsed", value: "1")
    visit root_url

    assert_text "Signed in as #{@user.email}"
    assert_button "Open sidebar"
    assert_no_button "Expand sidebar"

    open_mobile_sidebar
    within "aside" do
      assert_link "Dashboard"
    end
  end
end
