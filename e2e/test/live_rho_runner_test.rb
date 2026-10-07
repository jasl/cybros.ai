require "test_helper"
require "support/live_journey"
require "support/coding_task"
require "json"
require "shellwords"
require "stringio"

# A SEPARATE RUNNER, LIVE: an AGENT-mode rho — the shipped set under `RHO_MODE=agent`, one address,
# no runner row — names a RUNNER-mode rho on a second home by `rho do --runner`, and a real model
# does `live_agent_run`'s coding turn on it: the file is written and run WHERE THE RUNNER IS, every
# tool row is addressed to the runner-mode rho and its own log carries the claims; the agent's log
# carries none, because it serves nothing.
#
# AND THE CAPTURE PATH: a second turn NAMES `browser_screenshot`; the runner-mode rho loads
# rho-browser from ITS home's settings.json with the driver in ITS env; the PNG is a CAPTURE the
# result names with a `resource_link`; `rho fetch` (exe/rho) prints its bytes and the SDK reads the
# same bytes; and the NEXT sealed request carries the picture the way the loop's CATALOG ROW selects
# — the images rider's two halves ride the two floors. A text-only row (`deepseek/deepseek-flash`)
# gets the RULED line in the picture's place, the part degraded where the segments are built; an
# image row (`openrouter/z-ai/glm-5.3-flash`: the broker lists image input) gets the `upload` part
# itself. The lane reads the row's `input_modalities` off the member plane (`client.models`, the
# kernel's own listing of what this account can run) and asserts the half the row names; the model
# ANSWERING from the picture is `live_capture`'s.
#
# Paid, local, opt-in: E2E_LIVE=1. The capture turn is cents.
class LiveRhoRunnerTest < Minitest::Test
  MODEL = ENV.fetch("E2E_LIVE_MODEL") { E2E::LiveJourney.default_model }.freeze
  DRIVER = ENV.fetch("RHO_BROWSER_PLAYWRIGHT_CLI", "npx -y playwright-core@1.62.1").freeze
  TROUBLE = /runner_task_failed|runner_submit_refused/
  PNG_MAGIC = "\x89PNG\r\n\x1a\n".b.freeze
  NOT_SHOWN = "image content omitted: this model does not support image input".freeze

  include E2E::LiveJourney

  def setup = start_live_journey!(MODEL, home_prefix: "rho-live-rho-runner-e2e", daemon_env: { "RHO_MODE" => "agent" })
  def teardown = finish_live_journey!

  def test_an_agent_mode_rho_does_the_coding_turn_on_a_runner_mode_rho_it_named
    connect_and_open_lane!
    assert_equal "agent", @daemon.status["mode"]
    assert_nil @daemon.status.dig("identity", "runner_executor_public_id"),
      "an agent-mode rho registers no runner row: #{@daemon.status["identity"].inspect}"
    # THE EXTENSION IS THE RUNNER HOME'S: named in its settings, the driver
    # in its env — the agent's home loads neither.
    runner_id = start_runner_rho!(home_prefix: "rho-live-rho-runner-runner-e2e",
      daemon_env: { "RHO_BROWSER_PLAYWRIGHT_CLI" => DRIVER }, settings: { "settings_version" => 1, "plugins" => { "rho.browser" => { "enabled" => true } } })

    # THE TREE IS THE RUNNER'S: pointed before the turn, so the agent's
    # first discovery read of the runner names it.
    project = File.join(@runner_home, "project")
    FileUtils.mkdir_p(project)
    @runner.control(:post, "/environment", body: { root: project })

    output, status = @daemon.cli("do", E2E::CODING_TASK,
      "--model", MODEL, "--dir", project, "--runner", runner_id)
    assert_predicate status, :success?, "rho do failed:\n#{output}"
    refute_match(/^runner:/, output, "the runner-mode rho is online: the slot is silent\n#{output}")
    loop_id = output[/^run:\s+(\S+)/, 1]
    refute_nil loop_id, output

    watched, status = rho_watch(loop_id, "--timeout", "600")
    assert_predicate status, :success?, watched
    completed = await_loop_completion(loop_id)
    report(completed, runner_id)
    assert_equal "completed", completed.fetch("status"), "the loop did not finish: #{summarize(completed)}"

    # THE PROOF IS ON DISK, where the runner is.
    written = File.join(project, "fizzbuzz.rb")
    assert_path_exists written, "the tools were pointed at #{project} and the work landed somewhere else"
    assert_match(/def fizzbuzz/, File.read(written))
    printed = `ruby #{Shellwords.escape(written)} 2>&1`
    assert_equal %w[1 2 Fizz 4 Buzz Fizz 7 8 Fizz Buzz 11 Fizz 13 14 FizzBuzz],
      printed.split("\n").map(&:strip), "the program it wrote does not do the job"

    # THE PROOF OF WHERE: every tool row addressed to the runner-mode rho,
    # its log carrying the write and the bash; the agent's log empty.
    tools = completed.fetch("tasks").select { |task| task.fetch("kind") == "tool_task" }
    tools_used = tools.map { |task| task.fetch("tool_name") }
    assert_includes tools_used, "write"
    assert_includes tools_used, "bash", "it never ran what it wrote"
    tools.each do |task|
      assert_equal runner_id, task.dig("addressed_to", "executor_public_id"), "addressed elsewhere: #{task.inspect}"
    end
    claimed = @runner.claims.map { |claim| claim["tool"] }
    assert_includes claimed, "write", "the runner-mode rho's log carries no write: #{@runner.claims.inspect}"
    assert_includes claimed, "bash", "the runner-mode rho's log carries no bash: #{@runner.claims.inspect}"
    assert_empty @daemon.claimed_keys, "an agent-mode rho holds no runner row and claims nothing"
    refute_match TROUBLE, @runner.log_text, "the runner-mode rho met a refusal or a failure"
    refute_match TROUBLE, @daemon.log_text, "the agent-mode rho met a refusal or a failure"

    capture_turn!(project, runner_id)
  end

  private

    # THE CAPTURE PATH, END TO END, on the separated runner: the
    # instruction names the tool, the runner-mode rho serves it, the
    # result names the PNG, two readers read the same bytes through the
    # one read, and the next request carries the half the row selects.
    def capture_turn!(project, runner_id)
      client = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
      takes_pictures = row_takes_pictures?(client)

      url = "#{@base_url}/session/new"
      task = "Take a screenshot of #{url} with `browser_screenshot` and tell me its path. Do nothing else."
      output, status = @daemon.cli("do", task, "--model", MODEL, "--dir", project, "--runner", runner_id)
      assert_predicate status, :success?, "rho do failed:\n#{output}"
      loop_id = output[/^run:\s+(\S+)/, 1]
      refute_nil loop_id, output

      watched, status = rho_watch(loop_id, "--timeout", "600")
      assert_predicate status, :success?, watched
      completed = await_loop_completion(loop_id)
      report_capture(completed, runner_id, takes_pictures)
      assert_equal "completed", completed.fetch("status"), "the capture turn did not finish: #{summarize(completed)}"

      # IT CAPTURED, on the runner, and the call was not an error.
      shot = completed.fetch("tasks").find do |t|
        t.fetch("kind") == "tool_task" && t["tool_name"] == "browser_screenshot" &&
          t.fetch("status") == "completed" && t.dig("result", "is_error") != true
      end
      refute_nil shot, "it never took the screenshot: #{summarize(completed)}"
      assert_equal runner_id, shot.dig("addressed_to", "executor_public_id"), "addressed elsewhere: #{shot.inspect}"
      assert_includes @runner.claims.map { |claim| claim["tool"] }, "browser_screenshot",
        "the runner-mode rho's log carries no screenshot claim: #{@runner.claims.inspect}"

      # THE RESULT NAMES THE CAPTURE beside its byte-stable sentence.
      detail = client.workspace(workspace_public_id).runs.run(loop_id).task(shot.fetch("key"))
      # The sentence, byte-stable; a reset notice may lead it on the
      # browser's first page (`noticed`), so no anchor.
      assert_match(/Saved a screenshot of \S+ to \S+\.png/, detail.output.to_s, "the tool's own sentence is the model's channel")
      link = Array(detail.content).find { |block| block.fetch("type") == "resource_link" }
      refute_nil link, "the screenshot is a capture the result names: #{detail.content.inspect}"
      assert_equal "image/png", link.fetch("mimeType")
      assert_match(/\Abrowser-\h{16}\.png\z/, link.fetch("name"))
      upload_id = link.fetch("uri").delete_prefix("nexus://uploads/")

      # TWO READERS, ONE READ: `rho fetch` driven through exe/rho, and the SDK.
      bytes, fetch_status = @daemon.cli_bytes("fetch", upload_id)
      assert_predicate fetch_status, :success?, bytes.dup.force_encoding(Encoding::UTF_8).scrub
      assert_equal PNG_MAGIC, bytes[0, 8], "`rho fetch` prints the PNG whole"
      assert_equal link.fetch("size"), bytes.bytesize, "the link's size is the bytes'"
      io = StringIO.new
      assert_equal 200, client.uploads.bytes(upload_id, io).status
      assert_equal bytes, io.string.b, "the SDK reads the same bytes"

      # THE NEXT REQUEST: the half the row selects — the ruled line in the
      # picture's place on a text-only row, the `upload` part on an image row.
      rounds = completed.fetch("tasks").select { |t| t.fetch("kind") == "model_task" }.map { |t| t.fetch("key") }
      request, status = @daemon.cli("request", loop_id, rounds.last)
      assert_predicate status, :success?, request
      entries = JSON.parse(request.split("entries:\n", 2).fetch(1))
      parts = entries.flat_map { |entry| Array(entry["parts"]) }
      if takes_pictures
        assert_picture_taken(parts, entries, upload_id)
      else
        assert_ruled_line(parts, entries, request, upload_id)
      end
    end

    # THE ROW'S OWN WORD ON PICTURES: the member plane's listing carries the
    # catalog's `input_modalities` for every model this account can run —
    # the same fact the kernel reads where it builds the segments, read
    # through the same door an agent would, never a second copy of the
    # catalog under the lane.
    def row_takes_pictures?(client)
      row = client.models.list.find { |model| model.ref == MODEL }
      refute_nil row, "the loop's model is not in the account's listing: #{MODEL}"
      Array(row.capabilities["input_modalities"]).include?("image")
    end

    # THE FLOOR'S HALF: the ruled line stands in the part's place, no
    # `upload` part on the row, no upload id anywhere in the request.
    def assert_ruled_line(parts, entries, request, upload_id)
      line = parts.find { |part| part["type"] == "text" && part["text"].to_s.include?(NOT_SHOWN) }
      refute_nil line, "the floor takes no picture: the ruled line stands in the part's place: #{entries.inspect}"
      assert_match(%r{\A\[Attachment: browser-\h{16}\.png \(image/png, [\d,]+ bytes\) — #{Regexp.escape(NOT_SHOWN)}\]\z}, line["text"])
      refute(parts.any? { |part| part["type"] == "upload" }, "no upload part on a row that cannot take it")
      refute_includes request, upload_id, "no upload id reaches the model"
    end

    # THE IMAGE ROW'S HALF: the capture rides as the `upload` part naming
    # the screenshot's own upload, no ruled line anywhere, and the id
    # reaches the model only as that part — never as words.
    def assert_picture_taken(parts, entries, upload_id)
      picture = parts.find { |part| part["type"] == "upload" }
      refute_nil picture, "the row takes pictures: the capture rides as an upload part: #{entries.inspect}"
      assert_equal upload_id, picture["upload_public_id"], "the upload part names the screenshot's upload"
      refute(parts.any? { |part| part["type"] == "text" && part["text"].to_s.include?(NOT_SHOWN) },
        "no ruled line on a row that takes the picture: #{entries.inspect}")
      words = entries.reject { |entry| Array(entry["parts"]).any? { |part| part.equal?(picture) } }
      refute_includes JSON.generate(words), upload_id, "no upload id reaches the model as words"
    end

    def report_capture(row, runner_id, takes_pictures)
      shot = row.fetch("tasks").find { |t| t["tool_name"] == "browser_screenshot" }
      puts "\n--- live rho runner: capture --------------------------------------"
      puts "model:  #{MODEL}"
      puts "runner: #{runner_id} (runner-mode rho, rho-browser from its home)"
      puts "status: #{row.fetch("status")}"
      puts "tools:  #{summarize(row)}"
      puts "shot:   #{shot ? "#{shot.fetch("key")} #{shot.fetch("status")}" : "none"}"
      puts "picture: #{takes_pictures ? "taken" : "ruled line"} (the row's input_modalities)"
      puts "---------------------------------------------------------------"
    end

    def report(row, runner_id)
      puts "\n--- live rho runner -------------------------------------------"
      puts "model:  #{MODEL}"
      puts "runner: #{runner_id} (runner-mode rho)"
      puts "status: #{row.fetch("status")}"
      puts "rounds: #{row.fetch("tasks").count { |t| t.fetch("kind") == "model_task" }}"
      puts "tools:  #{summarize(row)}"
      puts "claims: #{@runner.claims.map { |c| "#{c["task"]}:#{c["tool"]}" }.join(" ")}"
      puts "---------------------------------------------------------------"
    end
end
