require "test_helper"

class WorkReadingHelperTest < ActionView::TestCase
  test "Markdown renders readable structure and keeps fenced code as exact text" do
    code = "<script>alert('code')</script>\n  puts \"a & b\"\n"
    source = "# Heading\n\n**Strong** and *emphasis*\n\n- First\n- Second\n\n> Quote\n\n| A | B |\n| --- | --- |\n| One | Two |\n\n```html\n#{code}```\n"
    html = Nokogiri::HTML5.fragment(work_markdown(source))

    assert_equal "Heading", html.at_css("h2").text
    assert_equal "Strong", html.at_css("strong").text
    assert_equal 2, html.css("li").length
    assert_equal "One", html.at_css("tbody td").text
    assert_equal code, html.at_css("pre code").text
    assert_empty html.css("script, input, style")
  end

  test "untrusted HTML extensions and image syntax cannot add active browser content" do
    source = <<~MARKDOWN
      <script>window.stolen = true</script>
      <img src="https://example.test/tracker" onerror="alert(1)">
      <svg><a href="javascript:alert(1)">SVG</a></svg>
      <iframe src="https://example.test/"></iframe>
      {::options template="/tmp/not-a-template" /}

      ![Diagram](https://example.test/diagram.png)
      ![](https://example.test/unnamed.png)
      [Script](javascript:alert%281%29)
      [Encoded](jav&#x61;script:alert%281%29)
      [Data](data:text/html,hello)
      [FTP](ftp://example.test/file)
      [Web](https://example.test/page)
      [中文](https://example.test/中文)
      [Mail](mailto:hello@example.test)
      [Relative](/conversations)
    MARKDOWN
    html = Nokogiri::HTML5.fragment(work_markdown(source))

    assert_empty html.css("script, img, svg, iframe, style, input")
    assert_empty html.css("[onerror], [onclick], [style], [data-controller], [id]")
    links = html.css("a").to_h { |link| [link.text, link["href"]] }
    %w[Script Encoded Data FTP].each { |label| assert_nil links.fetch(label) }
    assert_equal "https://example.test/diagram.png", links.fetch("Diagram")
    assert_equal "https://example.test/unnamed.png", links.fetch("https://example.test/unnamed.png")
    assert_equal "https://example.test/page", links.fetch("Web")
    assert_equal "https://example.test/中文", links.fetch("中文")
    assert_equal "mailto:hello@example.test", links.fetch("Mail")
    assert_equal "/conversations", links.fetch("Relative")
    assert_includes html.text, "<script>window.stolen = true</script>"
    assert_includes html.text, "{::options"
  end

  test "missing configuration does not erase retained selection facts" do
    model = Variant.new(provider_id: "fixture", model_ref: "text")
    facts = captured_configuration_facts(nil, initial_model: model, actual_model: model,
      model_selection: nil, fallback_models: ["fixture/backup"], approval_mode: "ask", conversation_reach: "subtree")

    assert_equal "fixture/text", facts.fetch("Initial model")
    assert_equal "fixture/text", facts.fetch("Actual model")
    assert_equal "fixture/backup", facts.fetch("Ordered fallback models")
    assert_equal "ask", facts.fetch("Approval mode")
    assert_equal "subtree", facts.fetch("Conversation reach")
    assert_equal "Unavailable", facts.fetch("Tool definitions in the capture")
    assert_equal "Unavailable", facts.fetch("Memory restriction")
    assert_equal "Unavailable", captured_model_label(Variant.new)
  end

  test "sanitizer depth and parser stack limits retain escaped original text" do
    [1_000, 3_000].each do |depth|
      source = "> " * depth + "<script>still text</script>\r\n  exact & spaced\r"
      html = Nokogiri::HTML5.fragment(work_markdown(source))

      assert_equal source, html.at_css("pre.whitespace-pre-wrap code").text
      assert_empty html.css("script, blockquote")
    end
  end

  test "unrelated Markdown argument errors remain visible" do
    Work::Markdown.stub(:render, ->(_source) { raise ArgumentError, "unexpected converter option" }) do
      error = assert_raises(ArgumentError) { work_markdown("ordinary text") }
      assert_equal "unexpected converter option", error.message
    end
  end

  test "an uncompiled imported tool declaration does not claim zero captured tools" do
    configuration = AgentConfiguration.new(kernel_tools: ["ask"])
    facts = captured_configuration_facts(configuration, initial_model: nil, actual_model: nil,
      model_selection: nil, fallback_models: [], approval_mode: "ask", conversation_reach: "workspace")

    assert_equal "Unavailable", facts.fetch("Tool definitions in the capture")
  end

  test "original text survives HTML newline normalization without becoming markup" do
    source = "\n\nfirst\r\nsecond\r<script>still text</script>\r"
    html = Nokogiri::HTML5.fragment(tag.pre(tag.code(work_original_text(source))))

    assert_equal source, html.at_css("code").text
    assert_empty html.css("script")
  end

  test "effective waiting freezes at pause or maintenance and failures use completion time" do
    now = Time.utc(2026, 10, 16, 12)
    run = Run.new(status: "paused", paused_at: now - 2.minutes)
    task = Tasks::AwaitTask.new(run: run, status: "awaiting_input", await_started_at: now - 5.minutes)
    assert_match "3 minutes", attention_elapsed(task, as_of: now, maintenance_now: now)
    assert_match "1 minute", attention_elapsed(task, as_of: now, maintenance_now: now - 4.minutes)
    task.await_started_at = nil
    assert_equal "Waiting start is unavailable", attention_elapsed(task, as_of: now, maintenance_now: now)
    task.status = "failed"
    task.completed_at = now - 10.minutes
    assert_equal "Failure recorded 10 minutes ago", attention_elapsed(task, as_of: now, maintenance_now: now)
  end
end
