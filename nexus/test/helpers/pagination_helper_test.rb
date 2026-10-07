require "test_helper"
require "nokogiri"

class PaginationHelperTest < ActionView::TestCase
  PAGY_REQUEST = Data.define(:base_url, :path, :params)
    .new("http://www.example.com", "/widgets", {}.freeze)
    .freeze

  test "renders a middle Pagy series as an accessible daisyUI join" do
    navigation = parse_navigation(build_pagy(count: 1_000, page: 50))

    nav = navigation.at_css("nav.min-w-0.max-w-full.overflow-x-auto[aria-label='Result pages']")
    assert nav
    join = nav.at_css("div.join")
    assert join
    assert_direction_link nav, rel: "prev", label: "Previous", href: "/widgets?page=49"
    assert_direction_link nav, rel: "next", label: "Next", href: "/widgets?page=51"

    current = nav.at_css("span.btn-active[aria-current='page']:not([aria-disabled])")
    assert_equal "50", current.text
    assert_nil current["href"]
    assert_includes current.classes, "cursor-default"
    assert_equal 2, nav.css("span.btn-disabled[role='separator']").size
    assert_daisy_ui_items join
  end

  test "renders the first page with disabled previous and linked next controls" do
    navigation = parse_navigation(build_pagy(count: 1_000, page: 1))

    assert_disabled_direction navigation, label: "Previous"
    assert_direction_link navigation, rel: "next", label: "Next", href: "/widgets?page=2"
    assert_current_page navigation, page: "1"
    assert_equal 1, navigation.css("span.btn-disabled[role='separator']").size
    assert_daisy_ui_items navigation.at_css("div.join")
  end

  test "renders the last page with linked previous and disabled next controls" do
    navigation = parse_navigation(build_pagy(count: 1_000, page: 100))

    assert_direction_link navigation, rel: "prev", label: "Previous", href: "/widgets?page=99"
    assert_disabled_direction navigation, label: "Next"
    assert_current_page navigation, page: "100"
    assert_equal 1, navigation.css("span.btn-disabled[role='separator']").size
    assert_daisy_ui_items navigation.at_css("div.join")
  end

  test "renders nothing for a single page" do
    assert_nil pagy_daisy_ui_nav(build_pagy(count: 5, page: 1), aria_label: "Widgets pages")
  end

  test "renders a return link from a page beyond a single-page result" do
    navigation = parse_navigation(build_pagy(count: 5, page: 2))

    assert_direction_link navigation, rel: "prev", label: "Previous", href: "/widgets?page=1"
  end

  private

    def build_pagy(count:, page:)
      Pagy::Offset.new(count: count, page: page, limit: 10, request: PAGY_REQUEST)
    end

    def parse_navigation(pagy)
      Nokogiri::HTML5.fragment(pagy_daisy_ui_nav(pagy, aria_label: "Result pages"))
    end

    def assert_direction_link(navigation, rel:, label:, href:)
      link = navigation.at_css("a[rel='#{rel}'][aria-label='#{label}']")
      assert link
      assert_equal href, link["href"]
    end

    def assert_disabled_direction(navigation, label:)
      link = navigation.at_css("a.btn-disabled[role='link'][aria-disabled='true'][aria-label='#{label}']")
      assert link
      assert_nil link["href"]
    end

    def assert_current_page(navigation, page:)
      current = navigation.at_css("span.btn-active[aria-current='page']:not([aria-disabled])")
      assert_equal page, current.text
      assert_nil current["href"]
    end

    def assert_daisy_ui_items(nav)
      assert nav.element_children.all? { |item|
        item.classes.include?("join-item") && item.classes.include?("btn") && item.classes.include?("btn-sm")
      }
    end
end
