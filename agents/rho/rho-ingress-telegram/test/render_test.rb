require_relative "test_helper"
require "rexml/document"

class TelegramRenderTest < Minitest::Test
  Render = Rho::IngressTelegram::Render

  def test_markdown_becomes_supported_html_and_plain_text
    text = "# 中文标题\n\n**strong** *emphasis* ~~old~~ `a < b && c` 😀\n\n- first\n- second\n\n[Docs](https://example.com/?a=1&b=2)"
    chunk = Render.chunks(text).fetch(0)
    assert_includes chunk.html, "<b>中文标题</b>"
    assert_includes chunk.html, "<b>strong</b>"
    assert_includes chunk.html, "<i>emphasis</i>"
    assert_includes chunk.html, "<s>old</s>"
    assert_includes chunk.html, "<code>a &lt; b &amp;&amp; c</code>"
    assert_includes chunk.html, 'href="https://example.com/?a=1&amp;b=2"'
    assert_includes chunk.text, "• first\n• second"
    assert_includes chunk.text, "😀"
    assert_equal({ text: chunk.html, parse_mode: "HTML" }, chunk.formatted)
    assert_equal({ text: chunk.text }, chunk.plain)
    assert_valid_chunk(chunk)
  end

  def test_raw_html_and_unsafe_links_remain_readable_without_becoming_entities
    text = '<script>alert("x")</script> <b>literal</b> [bad](javascript:alert) ![image](https://example.com/image.png)'
    chunk = Render.chunks(text).fetch(0)
    assert_includes chunk.text, '<script>alert("x")</script>'
    assert_includes chunk.text, "<b>literal</b>"
    assert_includes chunk.text, "bad (javascript:alert)"
    assert_includes chunk.text, "image (https://example.com/image.png)"
    refute_includes chunk.html, "<script>"
    refute_includes chunk.html, "<b>literal</b>"
    refute_includes chunk.html, 'href="javascript:'
    refute_includes chunk.html, "<img"
    assert_valid_chunk(chunk)
  end

  def test_complete_answers_are_split_without_losing_rendered_text
    text = ("中文 **answer** 😀\n\n" * 1000) + "final paragraph"
    chunks = Render.chunks(text)
    assert_operator chunks.length, :>, 1
    assert_equal text.delete("*"), chunks.map(&:text).join
    chunks.each { |chunk| assert_valid_chunk(chunk) }
  end

  def test_plain_text_keeps_literal_markup_and_graphemes_across_chunks
    source = "**中文** &amp; <tag> 👨‍👩‍👧‍👦\n" * 10
    chunks = Render.chunks(source, limit: 32, plain: true)

    assert_operator chunks.length, :>, 1
    assert_equal source, chunks.map(&:text).join
    chunks.each do |chunk|
      assert_equal({ text: chunk.text }, chunk.plain)
      assert_equal 1, chunk.text.scan("👨‍👩‍👧‍👦").length
      assert_valid_chunk(chunk, limit: 32)
    end
  end

  def test_long_fenced_code_preserves_every_line_and_reopens_balanced_html
    code = "puts '<你好>&😀'\n" * 1000
    chunks = Render.chunks("```ruby\n#{code}```\n\nDone.")
    assert_equal "#{code}\n\nDone.", chunks.map(&:text).join
    assert chunks.first.html.start_with?('<pre><code class="language-ruby">')
    assert chunks[1].html.start_with?('<pre><code class="language-ruby">')
    assert chunks.last.html.end_with?("Done.")
    chunks.each { |chunk| assert_valid_chunk(chunk) }
  end

  def test_nested_styles_split_without_invalid_nesting_or_dropping_text
    chunks = Render.chunks("**bold *#{"中文😀" * 50}* end**", limit: 32)
    assert_equal "bold #{"中文😀" * 50} end", chunks.map(&:text).join
    chunks.each { |chunk| assert_valid_chunk(chunk, limit: 32) }
  end

  def test_ninety_line_code_block_keeps_its_selected_line_boundary
    lines = (1..90).map { |number| format("%02d: abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\n", number) }
    chunks = Render.chunks("```text\n#{lines.join}```")

    assert_equal 2, chunks.length
    assert_equal lines.first(71).join, chunks.first.text
    assert chunks.last.text.start_with?("72: ")
    assert_equal lines.join, chunks.map(&:text).join
    chunks.each do |chunk|
      assert chunk.html.start_with?('<pre><code class="language-text">')
      assert chunk.html.end_with?("</code></pre>")
      assert_valid_chunk(chunk)
    end
  end

  def test_nested_lists_and_multiple_item_paragraphs_have_readable_separators
    source = "- parent\n  - child\n  - sibling\n\n    child paragraph\n\n- next"
    chunk = Render.chunks(source).fetch(0)
    assert_match(/• parent\n+• child\n• sibling\n\nchild paragraph\n• next/, chunk.text)
    assert_valid_chunk(chunk)
  end

  def test_tables_task_lists_and_unsupported_kramdown_extensions_remain_readable
    source = "| Name | Value |\n| --- | --- |\n| 中文 | 42 |\n\n- [x] done\n- [ ] pending\n\n{::comment}visible{:/comment}"
    text = Render.chunks(source).map(&:text).join
    assert_includes text, "Name | Value"
    assert_includes text, "中文 | 42"
    assert_includes text, "[x] done"
    assert_includes text, "[ ] pending"
    assert_includes text, "{::comment}visible{:/comment}"
  end

  def test_progress_cap_counts_utf16_and_keeps_graphemes_whole
    family = "👨‍👩‍👧‍👦"
    text = "a" * 789 + family + "more"
    preview = Render.preview(text)
    assert_equal "a" * 789 + "…", preview
    assert_operator Render.utf16_length(preview), :<=, 800
    assert_equal "a\u0301b…", Render.preview("a\u0301bcd", limit: 4)
    assert_equal "…", Render.preview(family, limit: 4)
  end

  def test_short_progress_and_empty_output
    assert_equal "你好 😀", Render.preview("你好 😀")
    assert_equal [], Render.chunks("")
    assert_equal "", Render.preview("", limit: 0)
    assert_raises(ArgumentError) { Render.chunks("text", limit: 12) }
  end

  def test_split_preserves_emoji_clusters_and_oversized_combining_sequences
    family = "👨‍👩‍👧‍👦"
    chunks = Render.chunks("a" * 15 + family * 4, limit: 32)
    assert_equal "a" * 15 + family * 4, chunks.map(&:text).join
    assert chunks.drop(1).all? { |chunk| chunk.text.scan(/\X/).all? { |cluster| cluster == family } }
    text = "a" + "\u0301" * 100
    chunks = Render.chunks(text, limit: 32)
    assert_equal text, chunks.map(&:text).join
    chunks.each { |chunk| assert_valid_chunk(chunk, limit: 32) }
  end

  private

    def assert_valid_chunk(chunk, limit: 4096)
      document = REXML::Document.new("<root>#{chunk.html}</root>")
      rendered = REXML::XPath.match(document, "//text()").map(&:value).join
      assert_equal chunk.text, rendered
      assert_operator Render.utf16_length(rendered), :<=, limit
      tags = REXML::XPath.match(document, "//*").map(&:name).uniq
      assert_empty tags - %w[root b i s a code pre blockquote]
    end
end
