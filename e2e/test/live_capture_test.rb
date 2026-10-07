require "test_helper"
require "support/live_journey"
require "json"
require "stringio"

# THE VISION HALF OF THE IMAGES RIDER: ONE full-mode rho with rho-browser (`live_browser`'s shape)
# on an image-input model explicitly selected with `E2E_VISION_MODEL`, and ONE
# `browser_screenshot` turn. The PNG the tool saves is a CAPTURE the result names
# with a `resource_link`; the NEXT sealed request carries it as an `upload` part in ONE picture-only
# user message after the round's last result (this row takes pictures, so no ruled line); `rho
# fetch` prints the same bytes; and the model answers about the page — the sign-in form's two
# labelled inputs. The floor's half (the ruled line) is `live_rho_runner`'s.
#
# Paid, local, opt-in: E2E_LIVE=1; under the cost stop, its own patience
# $1 (`COST_STOP_USD`, or a smaller `E2E_LIVE_COST_STOP_USD`). Its own
# report line; out of the text sweep, whose selected models need not support images.
class LiveCaptureTest < Minitest::Test
  MODEL = ENV.fetch("E2E_VISION_MODEL", "").freeze
  DRIVER = ENV.fetch("RHO_BROWSER_PLAYWRIGHT_CLI", "npx -y playwright-core@1.62.1").freeze
  COST_STOP_USD = 1.0
  PNG_MAGIC = "\x89PNG\r\n\x1a\n".b.freeze
  NOT_SHOWN = "image content omitted: this model does not support image input".freeze

  include E2E::LiveJourney

  def setup
    skip "set E2E_VISION_MODEL to a model with image input" if MODEL.empty?
    start_live_journey!(MODEL, home_prefix: "rho-live-capture-e2e",
      daemon_env: { "RHO_BROWSER_PLAYWRIGHT_CLI" => DRIVER })
    # THE LANE'S PATIENCE IN MONEY: one screenshot turn on the strong tier
    # is cents; a dollar is the wall, never the bench's default.
    @cost_stop_usd = [@cost_stop_usd, COST_STOP_USD].compact.min
    File.write(File.join(@home, "settings.json"), JSON.generate(E2E::RhoDaemon.dev_settings(plugins: { "rho.browser" => { "enabled" => true } })), perm: 0o600)
  end

  def teardown = finish_live_journey!

  def test_a_screenshot_is_placed_as_a_picture_the_next_round_and_the_model_answers_from_it
    connect_and_open_lane!
    listed, status = @daemon.cli("runner")
    assert_predicate status, :success?, "rho runner failed:\n#{listed}"
    assert_match(/extension:\s+rho\.browser/, listed, "the browser extension did not load:\n#{listed}")
    refute_match(/FAILED:/, listed, "an extension failed to load:\n#{listed}")

    project = File.join(@home, "project")
    FileUtils.mkdir_p(project)
    @daemon.control(:post, "/environment", body: { root: project })

    url = "#{@base_url}/session/new"
    task = <<~TEXT.strip
      Open #{url} in the browser and take a screenshot of it with `browser_screenshot`.
      Then look at the screenshot you took and reply with the visible labels of the
      text or password inputs on the page, comma-separated, and nothing else.
    TEXT
    output, status = @daemon.cli("do", task, "--model", MODEL, "--dir", project)
    assert_predicate status, :success?, "rho do failed:\n#{output}"
    loop_id = output[/^run:\s+(\S+)/, 1]
    refute_nil loop_id, output

    watched, status = rho_watch(loop_id, "--timeout", "600")
    assert_predicate status, :success?, watched
    completed = await_loop_completion(loop_id)
    report(completed)
    assert_equal "completed", completed.fetch("status"), "the loop did not finish: #{summarize(completed)}"

    # IT CAPTURED, and the call was not an error.
    shot = completed.fetch("tasks").find do |t|
      t.fetch("kind") == "tool_task" && t["tool_name"] == "browser_screenshot" &&
        t.fetch("status") == "completed" && t.dig("result", "is_error") != true
    end
    refute_nil shot, "it never took the screenshot: #{summarize(completed)}"

    # THE RESULT NAMES THE CAPTURE; `rho fetch` prints its bytes.
    client = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    detail = client.workspace(workspace_public_id).runs.run(loop_id).task(shot.fetch("key"))
    link = Array(detail.content).find { |block| block.fetch("type") == "resource_link" }
    refute_nil link, "the screenshot is a capture the result names: #{detail.content.inspect}"
    assert_equal "image/png", link.fetch("mimeType")
    upload_id = link.fetch("uri").delete_prefix("nexus://uploads/")
    bytes, fetch_status = @daemon.cli_bytes("fetch", upload_id)
    assert_predicate fetch_status, :success?, bytes.dup.force_encoding(Encoding::UTF_8).scrub
    assert_equal PNG_MAGIC, bytes[0, 8], "`rho fetch` prints the PNG whole"
    assert_equal link.fetch("size"), bytes.bytesize

    # THE NEXT REQUEST PLACES THE PICTURE: results, then ONE picture-only
    # message with the `upload` part; no ruled line, no id in any words.
    rounds = completed.fetch("tasks").select { |t| t.fetch("kind") == "model_task" }.map { |t| t.fetch("key") }
    request, status = @daemon.cli("request", loop_id, rounds.last)
    assert_predicate status, :success?, request
    entries = JSON.parse(request.split("entries:\n", 2).fetch(1))
    picture = entries.find do |entry|
      entry["role"] == "user" && Array(entry["parts"]).any? { |part| part["upload_public_id"] == upload_id }
    end
    refute_nil picture, "the row takes pictures: the capture rides as an upload part: #{entries.inspect}"
    assert_equal [{ "type" => "upload", "upload_public_id" => upload_id }], picture["parts"],
      "ONE picture-only message: the part and nothing else"
    before = entries.take(entries.index(picture))
    assert_equal "function_call_output", before.last&.dig("payload", "type"),
      "the picture message follows the round's last result: #{entries.inspect}"
    refute_includes request, NOT_SHOWN, "no ruled line on a row that takes the picture"
    words = entries.reject { |entry| entry.equal?(picture) }
    refute_includes JSON.generate(words), upload_id, "no upload id reaches the model as words"

    # AND THE MODEL ANSWERS ABOUT THE PAGE.
    answer = client.workspace(workspace_public_id).runs.run(loop_id).task(rounds.last).output.to_s
    labels = answer.downcase
    assert_includes labels, "email", "the model did not name the page's fields: #{answer.inspect}"
    assert_includes labels, "password", "the model did not name the page's fields: #{answer.inspect}"
  end

  private

    def report(row)
      tools = row.fetch("tasks").select { |t| t.fetch("kind") == "tool_task" }
      puts "\n--- live capture ----------------------------------------------"
      puts "model:  #{MODEL}"
      puts "status: #{row.fetch("status")}"
      puts "rounds: #{row.fetch("tasks").count { |t| t.fetch("kind") == "model_task" }}"
      puts "calls:  #{tools.size} (#{tools.map { |t| t["tool_name"] }.tally.map { |n, c| "#{n}x#{c}" }.join(" ")})"
      puts "--------------------------------------------------------------"
    end
end
