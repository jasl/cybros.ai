require "test_helper"
require "digest"

# THE TOOL with a `ToolEnv` on a tmpdir: the status
# line and its two caps, the truncation and bash's footer text, the spill
# written only when truncated, `files`, the six keys of
# `structured_content`, the bytes naming (path extension / image subtype
# / `.bin`), the refusals as `Result.error`, `Tool.validate` accepting
# the class, the profile constants, the park, the clamp — and the log
# that names the host and never the URL.
class ToolsTest < Minitest::Test
  include WebToolsTest::Helpers

  Fetch = Rho::WebTools::Tools::Fetch

  def setup
    @app = WebToolsTest::FixtureApp.new
    @site = serve(@app)
    @other = serve(WebToolsTest::FixtureApp.new)
    @app.other = @other
    @log = recording_log
    Rho::WebTools.settings = { "allow_private_network" => true }
    Rho::WebTools.instance_variable_set(:@log, @log)
    Rho::WebTools.configure_markdown!
  end

  def teardown
    halt_servers
    Rho::WebTools.reset!
  end

  def fetch(env, url) = Fetch.new(env: env).call("url" => url)

  def test_the_declaration_is_the_designs_and_the_loader_accepts_it
    assert_equal "web_fetch", Fetch::NAME
    assert_equal({ "kind" => "read_only", "destructive" => false, "effect_scope" => "open",
                   "idempotency" => "intrinsic", "reconciliation" => "none" }, Fetch::EFFECT_PROFILE)
    assert_equal 60_000, Fetch::TIMEOUT_MS
    assert Fetch::INTERNAL_CLAMP
    assert_equal ["url"], Fetch::SCHEMA["required"]
    assert_equal "The URL to fetch content from", Fetch::SCHEMA.dig("properties", "url", "description")
    validator = Rho::Runner::Extensions::Tool.validate(Fetch, extension: "rho.web_tools")
    assert_nil Rho::Runner::InputSchema.refusal(validator, { "url" => "https://example.com" })
    assert Rho::Runner::Extensions::Tool.internal_clamp?(Fetch)
    assert_includes Fetch::DESCRIPTION, "Fetches content from a specified URL."
    assert_includes Fetch::DESCRIPTION, "truncated to 2000 lines or 50.0KB (whichever is hit first)"
    assert_includes Fetch::DESCRIPTION, "This tool is read-only and does not modify any files."
    assert_includes Fetch::DESCRIPTION, "A redirect to another site is reported, not followed"
    assert_includes Fetch::DESCRIPTION, "Use this tool when you need to retrieve and analyze web content."
    assert_includes Fetch::DESCRIPTION, "Example: {\"url\": \"https://docs.ruby-lang.org/en/master/String.html\"}"
    refute_includes Fetch::DESCRIPTION, "private"
    assert_operator Fetch::DESCRIPTION.bytesize, :<, 1024
    assert_equal 1, Fetch::PROMPT_GUIDELINES.length
    assert_includes Fetch::PROMPT_GUIDELINES.first, "instead of curl or wget in bash"
  end

  def test_the_page_answers_the_status_line_a_blank_line_and_the_markdown
    with_tool_env do |env, _root|
      result = fetch(env, "#{@site}/page.html")
      refute_predicate result, :is_error
      status_line, blank, *rest = result.content.lines
      assert_equal "#{@site}/page.html — 200 text/html; #{Fetch.size(WebToolsTest::FixtureApp::PAGE.bytesize)} fetched, " \
                   "#{Fetch.size(rest.join.bytesize)} markdown; title: Fixture Page\n", status_line
      assert_equal "\n", blank
      assert_includes rest.join, "# Fixture Heading"
      assert_empty result.files
      assert_empty Dir.glob(File.join(env.artifacts_dir, "*")), "a spill was written for a page under the cap"
      assert_equal %w[url final_url status content_type bytes truncation], result.structured_content.keys
      assert_equal({ "url" => "#{@site}/page.html", "final_url" => "#{@site}/page.html", "status" => 200,
                     "content_type" => "text/html", "bytes" => WebToolsTest::FixtureApp::PAGE.bytesize,
                     "truncation" => nil }, result.structured_content)
      line = @log.lines.find { |_, event, _| event == "web.fetch" }
      refute_nil line
      assert_equal "127.0.0.1", line[2][:host]
      assert_equal 200, line[2][:status]
      assert_equal 0, line[2][:redirects]
      assert_kind_of Integer, line[2][:ms]
      refute_match(/page\.html/, @log.lines.inspect, "a log line carries the URL")
    end
  end

  # THE BOUND, THE SPILL, THE FOOTER: bash's words verbatim, the whole
  # rendering in the artifacts directory, the path on `files`.
  def test_a_long_page_is_truncated_with_bashs_footer_and_spilled_whole
    with_tool_env do |env, _root|
      result = fetch(env, "#{@site}/long.html")
      refute_predicate result, :is_error
      spill = Dir.glob(File.join(env.artifacts_dir, "web-*.md")).fetch(0)
      assert_match(/\/web-[0-9a-f]{16}\.md\z/, spill)
      assert_equal [spill], result.files
      truncation = Rho::Runner::Truncation.truncate_head(File.read(spill, encoding: Encoding::UTF_8))
      assert truncation.truncated
      assert_equal :bytes, truncation.truncated_by
      footer = "\n\n[Showing lines 1-#{truncation.output_lines} of #{truncation.total_lines} (50.0KB limit). " \
               "Full output: #{spill}]"
      assert result.content.end_with?(footer), result.content[-200..]
      body = result.content.lines[2..].join.delete_suffix(footer)
      assert_equal truncation.content, body
      assert_operator body.bytesize, :<=, Rho::Runner::Truncation::DEFAULT_MAX_BYTES
      details = result.structured_content.fetch("truncation")
      assert_equal true, details.fetch("truncated")
      assert_equal :bytes, details.fetch("truncated_by")
      assert_equal truncation.total_lines, details.fetch("total_lines")
      assert_equal File.stat(env.artifacts_dir).mode & 0o777, 0o700
    end
  end

  # A SPILL IS NAMED BY ITS CONTENT: the footer names the spill's path, so a random name would make
  # every re-fetch of an unchanged page read as a new result. The rendering is written under a
  # temporary name and renamed to the digest of what it holds.
  def test_a_refetch_of_an_unchanged_long_page_answers_the_same_result_with_one_content_named_spill
    with_tool_env do |env, _root|
      first = fetch(env, "#{@site}/long.html")
      second = fetch(env, "#{@site}/long.html")

      assert_equal first.content, second.content, "the same page reads as the same result"
      spill = first.files.fetch(0)
      assert_equal File.join(env.artifacts_dir, "web-#{Digest::SHA256.file(spill).hexdigest[0, 16]}.md"), spill
      assert_equal [spill], second.files
      assert_equal [File.basename(spill)], Dir.children(env.artifacts_dir), "one spill, no temporary left behind"
    end
  end

  def test_a_single_line_over_the_cap_takes_reads_sentence_and_the_spill
    with_tool_env do |env, _root|
      result = fetch(env, "#{@site}/oneline.json")
      refute_predicate result, :is_error
      spill = result.files.fetch(0)
      assert_match(/\A#{Regexp.escape(@site)}\/oneline\.json — 200 application\/json; 58\.6KB fetched\n\n\[Line 1 is 58\.6KB, exceeds 50\.0KB limit\. Full output: #{Regexp.escape(spill)}\]\z/, result.content)
    end
  end

  def test_text_and_json_are_verbatim_under_the_status_line
    with_tool_env do |env, _root|
      # The runner's one counting convention: a trailing newline does not
      # open a final empty line, and the head bound rejoins what it kept.
      result = fetch(env, "#{@site}/notes.txt")
      assert_equal "#{@site}/notes.txt — 200 text/plain; 18B fetched\n\nline one\nline two", result.content
      result = fetch(env, "#{@site}/data.json")
      assert_equal "#{@site}/data.json — 200 application/json; 14B fetched\n\n{\"answer\": 42}", result.content
    end
  end

  # BYTES ARE SAVED ALWAYS, named by the path's extension, else the image
  # subtype `read` knows, else `.bin`; the sentence names the size and
  # the path, the path rides `files`.
  def test_bytes_are_saved_and_named
    with_tool_env do |env, _root|
      result = fetch(env, "#{@site}/pixel.png")
      refute_predicate result, :is_error
      path = result.files.fetch(0)
      assert_match(/\/web-[0-9a-f]{16}\.png\z/, path)
      assert_equal "#{@site}/pixel.png — 200 image/png; #{Fetch.size(WebToolsTest::FixtureApp::PNG.bytesize)} saved to #{path}",
        result.content
      assert_equal WebToolsTest::FixtureApp::PNG, File.binread(path)
      assert_equal "image/png", result.structured_content.fetch("content_type")
      assert_match(/\.jpeg\z/, fetch(env, "#{@site}/picture").files.fetch(0))
      assert_match(/\.bin\z/, fetch(env, "#{@site}/blob").files.fetch(0))
      read = Rho::Runner::Tools::Read.new(env: env).call("path" => path)
      assert_equal "#{File.basename(path)}: image attached", read.content
    end
  end

  # Saved bytes are named by their content the same way: a re-fetch of an unchanged file names the
  # same path and reads as the same result.
  def test_a_refetch_of_unchanged_bytes_answers_the_same_result_with_one_content_named_file
    with_tool_env do |env, _root|
      first = fetch(env, "#{@site}/pixel.png")
      second = fetch(env, "#{@site}/pixel.png")

      assert_equal first.content, second.content, "the same bytes read as the same result"
      path = File.join(env.artifacts_dir, "web-#{Digest::SHA256.hexdigest(WebToolsTest::FixtureApp::PNG)[0, 16]}.png")
      assert_equal [path], first.files
      assert_equal [path], second.files
      assert_equal [File.basename(path)], Dir.children(env.artifacts_dir), "one file, no temporary left behind"
    end
  end

  def test_the_status_line_caps_the_url_and_the_title_at_snapshot_texts_numbers
    assert_equal 512, Rho::WebTools::URL_MAX_BYTES
    assert_equal 256, Fetch::TITLE_MAX_BYTES
    page = Rho::WebTools::Page.new(url: "http://x/", final_url: "http://x/#{"a" * 2000}", status: 200,
      media_type: "text/html", charset: nil, body: "", bytes: 0, redirects: 2)
    rendering = Rho::WebTools::Render::Rendering.new(kind: :markdown, text: "t", title: "T" * 1000, cut: nil)
    line = Fetch.status_line(page, rendering)
    url, rest = line.split(" — ", 2)
    assert_operator url.bytesize, :<=, 512
    assert_match(/ …\(\d+ more bytes\)\z/, url)
    assert_includes rest, "(2 redirects)"
    title = rest.split("title: ", 2).last
    assert_operator title.bytesize, :<=, 256
    cut = Rho::WebTools::Render::Rendering.new(kind: :markdown, text: "t", title: nil, cut: 1_048_576)
    page = page.with(bytes: 3_145_728, redirects: 1)
    assert_equal "http://x/#{"a" * 2000}".then { |u| Rho::WebTools.shorten(u, 512) } + " — 200 text/html; 3.0MB fetched, rendered the first 1.0MB of 3.0MB, 1B markdown (1 redirect)",
      Fetch.status_line(page, cut)
  end

  # The bytes answer names the final URL by the same rule as the status
  # line: a same-site redirect can make it as long as the server likes.
  def test_the_bytes_answer_caps_the_final_url_by_the_status_lines_rule
    with_tool_env do |env, _root|
      result = fetch(env, "#{@site}/long-image")
      refute_predicate result, :is_error
      assert_equal "#{Rho::WebTools.shorten("#{@site}/pixel.png?#{"q" * 2000}", 512)} — 200 image/png; " \
                   "#{Fetch.size(WebToolsTest::FixtureApp::PNG.bytesize)} saved to #{result.files.fetch(0)}", result.content
    end
  end

  def test_redirects_are_followed_on_the_same_site_and_reported_across
    with_tool_env do |env, _root|
      result = fetch(env, "#{@site}/same")
      refute_predicate result, :is_error
      assert result.content.start_with?("#{@site}/page.html — 200 text/html;")
      assert_includes result.content.lines.first, "(1 redirect)"
      assert_equal "#{@site}/same", result.structured_content.fetch("url")
      assert_equal "#{@site}/page.html", result.structured_content.fetch("final_url")
      assert_equal 1, @log.lines.find { |_, event, _| event == "web.fetch" }[2][:redirects]

      direct = fetch(env, "#{@site}/page.html")
      assert_equal direct.content.lines[2..], result.content.lines[2..], "the 302's body reached the rendering"

      away = fetch(env, "#{@site}/away")
      assert_predicate away, :is_error
      assert_equal "redirect: #{@site}/away → #{@other}/page.html (302); web_fetch follows redirects on the same " \
                   "site only — call web_fetch with the new url to follow it", away.content
      assert_equal 302, away.structured_content.fetch("status")
      assert_equal "#{@other}/page.html", away.structured_content.fetch("final_url")

      malformed = fetch(env, "#{@site}/malformed/0")
      assert_predicate malformed, :is_error
      assert_equal "redirect: #{@site}/malformed/0 → \"http://exa mple.com/x\" (302); the server's Location is not a " \
                   "valid URL, so web_fetch cannot follow it", malformed.content
      assert_equal 302, malformed.structured_content.fetch("status")
      assert_nil malformed.structured_content.fetch("final_url")

      loop_result = fetch(env, "#{@site}/loop")
      assert_predicate loop_result, :is_error
      assert_includes loop_result.content, "3 redirects"

      gone = fetch(env, "#{@site}/gone")
      assert_predicate gone, :is_error
      assert_equal "#{@site}/gone answered 300 Multiple Choices\n\nNothing here to choose from.\nsecond line", gone.content
    end
  end

  # A HOSTILE REDIRECT stays under the budget: the huge `Location` shortened
  # in the sentence the model reads, no `final_url` it could not fetch.
  def test_a_huge_location_reaches_the_model_shortened_and_leaves_no_final_url
    with_tool_env do |env, _root|
      { "/huge/cross" => Rho::WebTools::Client::URL_ACTIONABLE_BYTES + 512, "/huge/malformed" => 1024 }.each do |path, bound|
        result = fetch(env, "#{@site}#{path}")
        assert_predicate result, :is_error
        assert_operator result.content.bytesize, :<, bound, path
        assert_match(/ …\(\d+ more bytes\) \(302\); /, result.content, path)
        assert_equal 302, result.structured_content.fetch("status")
        assert_nil result.structured_content.fetch("final_url"), path
      end
    end
  end

  # A same-site hop whose Retry-After is not seconds or an HTTP date is a
  # redirect reported with the URL it names, never a failed task.
  def test_a_malformed_retry_after_is_a_refusal_the_model_reads
    with_tool_env do |env, _root|
      result = fetch(env, "#{@site}/retry-after")
      assert_predicate result, :is_error
      assert_equal "redirect: #{@site}/retry-after → #{@site}/notes.txt; the server's Retry-After is not a number of " \
                   "seconds or an HTTP date, so web_fetch cannot follow it — call web_fetch with the new url to read it",
        result.content
      assert_nil result.structured_content.fetch("status")
      assert_equal "#{@site}/notes.txt", result.structured_content.fetch("final_url")
      assert_equal "redirect", @log.lines.find { |_, event, _| event == "web.refused" }[2][:reason]
    end
  end

  def test_a_404_and_a_too_large_answer_are_data
    with_tool_env do |env, _root|
      missing = fetch(env, "#{@site}/missing")
      assert_predicate missing, :is_error
      assert_equal "#{@site}/missing answered 404 Not Found\n\nno such page\nsecond line", missing.content
      assert_equal 404, missing.structured_content.fetch("status")

      big = fetch(env, "#{@site}/big")
      assert_predicate big, :is_error
      assert_includes big.content, "6.0MB"
      assert_includes big.content, "5.0MB"
      assert_equal 0, big.structured_content.fetch("bytes")
      assert_equal "#{@site}/big", big.structured_content.fetch("url")
      assert_equal %w[url final_url status content_type bytes truncation], big.structured_content.keys
      assert_equal "too_large", @log.lines.find { |_, event, _| event == "web.refused" }[2][:reason]
    end
  end

  # THE REFUSALS THE MODEL READS: every one a `Result.error` with the
  # rule's sentence; the credentials sentence names nothing of them; the
  # private sentence holds under the lift for a metadata address; the
  # log carries a host or nothing, never a URL.
  def test_the_refusals_are_data_with_the_rules_sentences
    with_tool_env do |env, _root|
      assert_equal Rho::WebTools::UrlRule::SCHEME, fetch(env, "ftp://x").content
      credentials = fetch(env, "http://u:p@127.0.0.1/")
      assert_predicate credentials, :is_error
      assert_equal Rho::WebTools::UrlRule::CREDENTIALS, credentials.content
      refute_match(/u:|p@/, credentials.content)
      canonical = fetch(env, @site.sub("127.0.0.1", "LOCALHOST") + "/page.html")
      assert_equal Rho::WebTools::UrlRule.not_canonical("LOCALHOST"), canonical.content
      assert_equal Rho::WebTools::UrlRule::NOT_A_URL, fetch(env, "#{@site}/Köln").content
      # A rule refusal whose SPELLING carries the word is still `url`.
      spelled = fetch(env, "http://private.corp./")
      assert_equal Rho::WebTools::UrlRule.not_canonical("private.corp."), spelled.content
      metadata = fetch(env, "http://169.254.169.254/latest/meta-data/")
      assert_predicate metadata, :is_error
      assert_includes metadata.content, "169.254.169.254 resolves to a private or reserved address"
      assert_equal 0, @app.seen.length, "a refused URL opened a socket"
      refused = @log.lines.select { |_, event, _| event == "web.refused" }
      assert_equal 6, refused.length
      assert_equal %w[url url url url url private_address], refused.map { |line| line[2][:reason] }
      refute_match(/page\.html|meta-data|K.ln/, @log.lines.inspect)
    end
  end

  # A standalone runner has no `web` table to judge, so it gets the default.
  def test_the_default_settings_refuse_the_loopback_fixture
    Rho::WebTools.settings = nil
    with_tool_env do |env, _root|
      result = fetch(env, "#{@site}/page.html")
      assert_predicate result, :is_error
      assert_equal Rho::WebTools::Client.new.private_sentence("127.0.0.1"), result.content
    end
  end

  def test_an_unreachable_host_is_data_and_logged_as_failed
    Rho::WebTools.instance_variable_set(:@log, @log)
    closed = TCPServer.new("127.0.0.1", 0)
    port = closed.addr[1]
    closed.close
    with_tool_env do |env, _root|
      result = fetch(env, "http://127.0.0.1:#{port}/x?token=SECRET")
      assert_predicate result, :is_error
      assert_equal "127.0.0.1 refused the connection", result.content
      failed = @log.lines.find { |_, event, _| event == "web.failed" }
      assert_equal "Rho::WebTools::Unreachable", failed[2][:error_class]
      refute_match(/SECRET/, @log.lines.inspect)
    end
  end

  def test_the_schema_refuses_a_call_without_a_url_before_the_handler
    validator = Rho::Runner::InputSchema.compile(Fetch::SCHEMA)
    refute_nil Rho::Runner::InputSchema.refusal(validator, {})
    assert_nil Rho::Runner::InputSchema.refusal(validator, { "url" => "https://example.com/" })
  end
end
