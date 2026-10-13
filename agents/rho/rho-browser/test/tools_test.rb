require "test_helper"
require "digest"
require "support"

# THE SIX, over a fake page: what each sends to the page and what it
# answers, plus the errors a model can actually act on.
class ToolsTest < Minitest::Test
  include BrowserTest::Helpers

  TREE = "- heading \"Sign in\" [ref=e1]\n- textbox \"Email\" [ref=e2]\n- button \"Go\" [ref=e3]".freeze

  def setup
    @page = BrowserTest::FakePage.new(url: "http://app.test/login", title: "Login", tree: TREE)
    Rho::Browser.driver_factory = -> { BrowserTest::FakeDriver.new(page: @page) }
  end

  def teardown = Rho::Browser.reset!

  def tool(klass, env) = klass.new(env: env)

  def page_content(result)
    result.content.delete_prefix(Rho::Browser::Tools::Base::NEW_TAB_NOTICE)
  end

  def test_a_first_tab_is_announced_without_claiming_a_previous_tab_was_reset
    with_tool_env do |env, _root|
      snapshot = tool(Rho::Browser::Tools::Snapshot, env)
      result = snapshot.call({})
      assert_match(/\ANOTE: this loop has a new browser tab;/, result.content)
      assert_match(/any refs from an earlier tab are invalid/, result.content)
      refute_match(/was reset|since your last/, result.content)
      refute_match(/\ANOTE:/, snapshot.call({}).content)
    end
  end

  def test_snapshot_renders_url_title_and_the_ai_tree
    with_tool_env do |env, _root|
      result = tool(Rho::Browser::Tools::Snapshot, env).call({})
      refute_predicate result, :is_error
      assert_includes result.content, "Page: http://app.test/login"
      assert_includes result.content, "Title: Login"
      assert_includes result.content, "[ref=e2]"
      assert_includes @page.calls, [:aria_snapshot, "ai"]
    end
  end

  # An action answers with the page that results, so the model does not
  # spend a round asking for it.
  def test_navigate_goes_there_and_returns_the_page
    with_tool_env do |env, _root|
      result = tool(Rho::Browser::Tools::Navigate, env).call("url" => "http://app.test/next")
      assert_equal [:goto, "http://app.test/next"], @page.calls.first
      assert_includes result.content, "Page: http://app.test/next"
    end
  end

  def test_click_resolves_the_ref_through_the_aria_ref_engine_with_a_short_action_timeout
    with_tool_env do |env, _root|
      result = tool(Rho::Browser::Tools::Click, env).call("ref" => "e3")
      refute_predicate result, :is_error
      assert_includes @page.calls, [:locator, "aria-ref=e3"]
      assert_includes @page.calls, [:click, "aria-ref=e3", Rho::Browser::Tools::ACTION_TIMEOUT_MS]
    end
  end

  def test_valid_snapshot_refs_work_when_locator_count_cannot_read_the_ref_map
    assert_equal 0, @page.locator("aria-ref=e2").count
    with_tool_env do |env, _root|
      snapshot = tool(Rho::Browser::Tools::Snapshot, env).call({})
      assert_includes snapshot.content, "[ref=e2]"
      result = tool(Rho::Browser::Tools::Type, env).call("ref" => "e2", "text" => "hello")

      refute_predicate result, :is_error, result.content
      assert_includes @page.calls, [:fill, "aria-ref=e2", "hello", Rho::Browser::Tools::ACTION_TIMEOUT_MS]
      assert_equal [[:query_selector, "aria-ref=e2"], [:dispose, "aria-ref=e2"]],
        @page.calls.select { |call| %i[query_selector dispose].include?(call.first) }
    end
  end

  # A ref from an older snapshot is said to be stale AT ONCE, in the words
  # the guidelines use — not after thirty seconds of "waiting for locator".
  def test_a_ref_that_is_not_on_the_page_is_refused_immediately_and_legibly
    with_tool_env do |env, _root|
      result = tool(Rho::Browser::Tools::Click, env).call("ref" => "e42")
      assert_predicate result, :is_error
      assert_match(/ref e42 is not on the current page/, result.content)
      assert_match(/call browser_snapshot/, result.content)
      refute_includes @page.calls.map(&:first), :click
    end
  end

  # A missing required argument is the model's to fix: an error result it
  # reads, not a failed task that takes the round's failure policy.
  def test_a_missing_required_argument_is_an_error_result_not_a_raise
    with_tool_env do |env, _root|
      { Rho::Browser::Tools::Navigate => "url", Rho::Browser::Tools::Click => "ref",
        Rho::Browser::Tools::Type => "ref", Rho::Browser::Tools::Evaluate => "expression" }
        .each do |klass, key|
        result = tool(klass, env).call({})
        assert_predicate result, :is_error, klass.name
        assert_match(/#{key} is required/, result.content)
      end
      assert_empty @page.calls, "an argument mistake must not touch the page"
    end
  end

  # The same GET a click performs is declared the same way.
  def test_navigate_declares_the_worst_honest_case_like_click
    assert_equal Rho::Browser::Tools::ACTS_ON_PAGE, Rho::Browser::Tools::Navigate::EFFECT_PROFILE
  end

  # The common mistake, answered with the expected shape rather than
  # whatever the driver would say about an unknown selector engine.
  def test_a_selector_where_a_ref_belongs_is_refused_legibly
    with_tool_env do |env, _root|
      result = tool(Rho::Browser::Tools::Click, env).call("ref" => "button.primary")
      assert_predicate result, :is_error
      assert_match(/handle from browser_snapshot such as e12/, result.content)
      refute_includes @page.calls.map(&:first), :click
    end
  end

  def test_type_fills_and_optionally_submits
    t = Rho::Browser::Tools::ACTION_TIMEOUT_MS
    with_tool_env do |env, _root|
      tool(Rho::Browser::Tools::Type, env).call("ref" => "e2", "text" => "me@x.test")
      assert_includes @page.calls, [:fill, "aria-ref=e2", "me@x.test", t]
      refute_includes @page.calls.map(&:first), :press

      tool(Rho::Browser::Tools::Type, env).call("ref" => "e2", "text" => "x", "submit" => true)
      assert_includes @page.calls, [:press, "aria-ref=e2", "Enter", t]
    end
  end

  # Clearing a field is typing nothing; `text` may be empty.
  def test_type_with_empty_text_clears_the_field
    with_tool_env do |env, _root|
      result = tool(Rho::Browser::Tools::Type, env).call("ref" => "e2", "text" => "")
      refute_predicate result, :is_error
      assert_includes @page.calls.map { |c| c.first(3) }, [:fill, "aria-ref=e2", ""]
    end
  end

  # NAMED BY CONTENT: the sentence names the path, so two shots of an unchanged page must be one
  # path — a random name would read as a new result every time. The shot lands on a temporary path
  # and is renamed to its PNG's digest.
  def test_screenshot_is_named_by_its_content_under_the_artifacts_dir
    with_tool_env do |env, _root|
      first = tool(Rho::Browser::Tools::Screenshot, env).call("full_page" => true)
      second = tool(Rho::Browser::Tools::Screenshot, env).call({})
      paths = [first, second].map { |r| r.content[/to (\S+\.png)/, 1] }
      expected = File.join(env.artifacts_dir, "browser-#{Digest::SHA256.hexdigest("PNG")[0, 16]}.png")
      assert_equal [expected, expected], paths, "two shots of an unchanged page are one path"
      assert_path_exists expected
      assert_equal [File.basename(expected)], Dir.children(env.artifacts_dir), "no temporary left behind"
      shot = @page.calls.find { |call| call.first == :screenshot }
      assert shot[1].start_with?(env.artifacts_dir), "shot under artifacts: #{shot[1]}"
      assert shot[2], "the first shot was of the full page"
      # THE CAPTURE beside the sentence: the same path, for the
      # run to upload and link; the sentence's bytes unchanged.
      assert_equal [expected], first.files
      assert_equal "Saved a screenshot of http://app.test/login to #{expected}", page_content(first)
    end
  end

  def test_evaluate_returns_json
    with_tool_env do |env, _root|
      result = tool(Rho::Browser::Tools::Evaluate, env).call("expression" => "document.title")
      assert_equal({ "echo" => "document.title" }, JSON.parse(page_content(result)))
    end
  end

  # A cyclic page value — `window`, a React fiber — is a real Ruby cycle
  # by the time it arrives; it must read back, not overflow the stack.
  def test_evaluate_survives_a_cyclic_value
    cyclic = { "name" => "window" }
    cyclic["self"] = cyclic
    cyclic["list"] = [cyclic, 1]
    def @page.evaluate(_expr) = @cyclic
    @page.instance_variable_set(:@cyclic, cyclic)
    with_tool_env do |env, _root|
      result = tool(Rho::Browser::Tools::Evaluate, env).call("expression" => "window")
      refute_predicate result, :is_error, result.content
      parsed = JSON.parse(page_content(result))
      assert_equal "window", parsed["name"]
      assert_equal "[circular]", parsed["self"]
      assert_equal ["[circular]", 1], parsed["list"]
    end
  end

  # An absent `text` is a mistake, not a clear: it would erase somebody's
  # half-written input silently. An empty string is a clear, and is sent.
  def test_type_without_text_is_refused_rather_than_clearing_the_field
    with_tool_env do |env, _root|
      result = tool(Rho::Browser::Tools::Type, env).call("ref" => "e2")
      assert_predicate result, :is_error
      assert_match(/text is required/, result.content)
      refute_includes @page.calls.map(&:first), :fill
    end
  end

  # The element was there when checked and gone when acted on: the model
  # needs the word "re-rendered" and the remedy, not "Timeout exceeded".
  def test_an_element_that_vanished_between_check_and_action_reads_as_stale
    require "playwright"
    @page.stale_after_query = Playwright::TimeoutError.new(message: "Timeout 10000ms exceeded")
    with_tool_env do |env, _root|
      result = tool(Rho::Browser::Tools::Click, env).call("ref" => "e3")
      assert_predicate result, :is_error
      assert_match(/changed before the action/, result.content)
      assert_match(/take a new browser_snapshot/, result.content)
      refute_match(/Timeout 10000ms/, result.content)
    end
  end

  # A dropped tab is announced ONCE, to the loop it belonged to, on its
  # next result — and never to another loop, whose tab is fine. The
  # notice rides the block, not the shared tool instance.
  def test_the_reset_notice_reaches_only_the_loop_whose_tab_was_dropped
    with_tool_env do |env, _root|
      snapshot = tool(Rho::Browser::Tools::Snapshot, env)
      in_loop("loop-a") { snapshot.call({}) }
      in_loop("loop-b") { snapshot.call({}) }
      Rho::Browser.session.with_page("loop-a") { |page, _r| page.close! }

      told = in_loop("loop-a") { snapshot.call({}) }
      assert_match(/\ANOTE: this loop has a new browser tab;/, told.content)
      assert_match(/Use the current page's snapshot before acting on a ref/, told.content)
      quiet = in_loop("loop-b") { snapshot.call({}) }
      refute_match(/new browser tab/, quiet.content)
      again = in_loop("loop-a") { snapshot.call({}) }
      refute_match(/new browser tab/, again.content, "the notice must be given once")
    end
  end

  def in_loop(run_id, &)
    context = Rho::Runner::ExecutionContext.new(run_public_id: run_id)
    Rho::Runner::ExecutionContext.with(context, &)
  end

  # JSON has no NaN: the page's `0/0` reads back as null, not as an error
  # about a format the model never chose.
  def test_evaluate_maps_non_finite_numbers_to_null
    def @page.evaluate(_expr) = { "w" => Float::NAN, "list" => [1.5, Float::INFINITY], "ok" => 2 }
    with_tool_env do |env, _root|
      result = tool(Rho::Browser::Tools::Evaluate, env).call("expression" => "x")
      refute_predicate result, :is_error
      assert_equal({ "w" => nil, "list" => [1.5, nil], "ok" => 2 }, JSON.parse(page_content(result)))
    end
  end

  # The driver failing is a message the model reads, not a dead task.
  def test_a_driver_that_cannot_start_answers_an_error_the_model_can_read
    Rho::Browser.reset!
    Rho::Browser.driver_factory = -> { BrowserTest::FakeDriver.new(fail_starts: 99) }
    with_tool_env do |env, _root|
      result = tool(Rho::Browser::Tools::Snapshot, env).call({})
      assert_predicate result, :is_error
      assert_match(/driver unavailable/, result.content)
    end
  end

  def test_cancellation_propagates_rather_than_becoming_an_error_result
    context = Rho::Runner::ExecutionContext.new
    context.cancel
    env = Rho::Runner::ToolEnv.new(root: Dir.tmpdir, artifacts_dir: File.join(Dir.tmpdir, "a"))
    Rho::Runner::ExecutionContext.with(context) do
      assert_raises(Rho::Runner::ExecutionContext::Cancelled) do
        tool(Rho::Browser::Tools::Snapshot, env).call({})
      end
    end
  end

  # The notice rides an ERROR answer too: a navigate that fails after a
  # drop must still say the refs are gone. The replacement tab is shaped
  # through the driver, not fetched — fetching it would be an acquire,
  # and an acquire is what consumes the notice.
  def test_the_reset_notice_rides_an_error_result
    Rho::Browser.reset!
    driver = BrowserTest::FakeDriver.new(page: @page)
    Rho::Browser.driver_factory = -> { driver }
    with_tool_env do |env, _root|
      in_loop("loop-a") { tool(Rho::Browser::Tools::Snapshot, env).call({}) }
      Rho::Browser.session.with_page("loop-a") { |page, _r| page.close! }
      def driver.new_page
        BrowserTest::FakePage.new.tap { |fresh| def fresh.goto(_url) = raise("net::ERR_NAME_NOT_RESOLVED") }
      end

      result = in_loop("loop-a") { tool(Rho::Browser::Tools::Navigate, env).call("url" => "http://nowhere.test") }
      assert_predicate result, :is_error
      assert_match(/\ANOTE: this loop has a new browser tab;/, result.content)
      assert_match(/ERR_NAME_NOT_RESOLVED/, result.content)
    end
  end
end
