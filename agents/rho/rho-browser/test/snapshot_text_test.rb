require "test_helper"
require "support"

class SnapshotTextTest < Minitest::Test
  def test_the_marker_sits_inside_the_bound
    text = "x" * 10_000
    out = Rho::Browser::SnapshotText.clamp(text, 500)
    assert_operator out.bytesize, :<=, 500
    assert_match(/\[snapshot truncated: \d+ more bytes/, out)
  end

  def test_short_text_is_untouched
    assert_equal "abc", Rho::Browser::SnapshotText.clamp("abc", 500)
  end

  # A page opened from a 60 KB data: URL must still answer with its TREE —
  # the URL is capped, so the refs a model needs to act are never crowded
  # out by the address of the page they are on.
  def test_a_huge_url_cannot_crowd_out_the_tree
    page = BrowserTest::FakePage.new(url: "data:text/html," + ("a" * 60_000), title: "T",
      tree: "- button \"Go\" [ref=e1]")
    out = Rho::Browser::SnapshotText.call(page, max_bytes: 50 * 1024)
    assert_operator out.bytesize, :<=, 50 * 1024
    assert_includes out, "[ref=e1]"
    assert_includes out, "Page: data:text/html,aaaa"
  end

  # A long URL is shortened on its own line; the tree's "snapshot
  # truncated" marker must never appear on the Page: line, where it would
  # claim the wrong thing was cut and split the header.
  def test_a_long_url_is_shortened_on_one_line_without_the_tree_marker
    page = BrowserTest::FakePage.new(url: "data:text/html," + ("a" * 2000), title: "T",
      tree: "- button [ref=e1]")
    out = Rho::Browser::SnapshotText.call(page)
    header, rest = out.split("\n\n", 2)
    assert_equal 2, header.lines.size, "the header grew a line: #{header.inspect}"
    assert_match(/\APage: data:text\/html,a+ …\(\d+ more bytes\)\nTitle: T\z/, header)
    refute_includes header, "snapshot truncated"
    assert_includes rest, "[ref=e1]"
  end

  def test_the_page_header_counts_against_the_bound
    page = BrowserTest::FakePage.new(url: "http://x", title: "T", tree: "y" * 1000)
    out = Rho::Browser::SnapshotText.call(page, max_bytes: 200)
    assert_operator out.bytesize, :<=, 200
    assert out.start_with?("Page: http://x\nTitle: T\n\n")
  end
end
