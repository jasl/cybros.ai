require "test_helper"

Capybara.enable_aria_label = true
Capybara.default_max_wait_time = 10

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  parallelize(workers: 1)

  DESKTOP_SIZE = [1400, 1400].freeze
  MOBILE_SIZE = [500, 844].freeze

  # Chrome's leaked-password dialog for fixture credentials blocks native page input.
  if ENV["CAPYBARA_SERVER_PORT"]
    served_by host: "rails-app", port: ENV["CAPYBARA_SERVER_PORT"]

    driven_by :selenium, using: :headless_chrome, screen_size: DESKTOP_SIZE, options: {
      browser: :remote,
      url: "http://#{ENV["SELENIUM_HOST"]}:4444",
    } do |options|
      options.add_preference("profile.password_manager_leak_detection", false)
    end
  else
    driven_by :selenium, using: :headless_chrome, screen_size: DESKTOP_SIZE do |options|
      options.add_preference("profile.password_manager_leak_detection", false)
    end
  end

  def after_teardown
    super
  ensure
    Capybara.current_session.quit
  end

  private

    def assert_focused(selector, message)
      assert page.has_css?("#{selector}:focus"), message
    end

    def open_user_menu
      find("aside details > summary").click
      assert_selector "aside details[open]"
    end

    def close_user_menu_with_escape(from: nil)
      (from || find("aside details > summary")).send_keys(:escape)
      assert_no_selector "aside details[open]"
    end

    def close_user_menu_by_outside_click
      find("main#main").click
      assert_no_selector "aside details[open]"
    end

    def confirm_through_dialog
      yield
      find("#turbo-confirm[open] button[value='confirm']").click
      assert_no_selector "#turbo-confirm[open]"
    end

    def sign_in_directly(user)
      session = create_browser_session(user.identity)
      cookie_jar = ActionDispatch::TestRequest.create.cookie_jar
      cookie_jar.signed[:session_id] = session.public_id

      visit rails_health_check_url
      page.driver.browser.manage.add_cookie(name: "session_id", value: cookie_jar[:session_id])
    end
end

class MobileSystemTestCase < ApplicationSystemTestCase
  if ENV["CAPYBARA_SERVER_PORT"]
    driven_by :selenium, using: :headless_chrome, screen_size: MOBILE_SIZE, options: {
      name: :mobile_headless_chrome,
      browser: :remote,
      url: "http://#{ENV["SELENIUM_HOST"]}:4444",
    } do |options|
      options.add_preference("profile.password_manager_leak_detection", false)
    end
  else
    driven_by :selenium, using: :headless_chrome, screen_size: MOBILE_SIZE,
      options: { name: :mobile_headless_chrome } do |options|
      options.add_preference("profile.password_manager_leak_detection", false)
    end
  end

  private

    def open_mobile_sidebar
      click_button "Open sidebar"
      wait_for_drawer(open: true)
    end

    def close_mobile_sidebar_via_overlay
      find("label[for='sidebar'].drawer-overlay").click(x: 130, y: 0)
      wait_for_drawer(open: false)
    end

    def wait_for_drawer(open:)
      assert_field "sidebar", checked: open, visible: :all
      assert_matches_style find(".drawer-side", visible: :all), opacity: (open ? "1" : "0")
    end
end
