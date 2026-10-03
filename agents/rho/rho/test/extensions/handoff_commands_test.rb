require "test_helper"

# THE HANDOFF VERBS, as the dispatcher invokes them: `rho
# runners` renders the daemon's listing with its marks and the kernel's
# presence word; `rho runners use ID|--none` writes the settings' `runner`
# key through the daemon's settings owner after
# the daemon vouched for the id; `rho handoff HOST EXECUTOR` drives the
# verb and prints the three-state runner slot.
class HandoffCommandsTest < Minitest::Test
  include RhoTest::CliHarness

  def commands(verb, *args, **options) = Rho::Extensions::Handoff::Commands.public_send(verb, cli, args, options)

  def runner_row(public_id, **extra)
    { "public_id" => public_id, "display_name" => "Elsewhere", "presence" => "online", "last_seen_at" => nil,
      "root" => "/srv/elsewhere", "tools" => %w[slow_read slow_write], "own" => false, "selected" => false,
      "bound_hosts" => [], "conflict" => nil }.merge(extra)
  end

  def test_runners_prints_one_line_per_runner_with_the_marks_and_the_legend
    seen = (Time.now - 185).utc.iso8601
    announce(endpoint: routed_endpoint("GET /runners" => [[200, {
      "runners" => [
        runner_row("0199-runner", "display_name" => "Helper", "root" => "/home/rho", "tools" => %w[bash read write],
          "own" => true, "bound_hosts" => %w[c-3]),
        runner_row("0199-h", "presence" => "offline", "last_seen_at" => seen, "selected" => true,
          "bound_hosts" => %w[c-1 al-2]),
        runner_row("0199-k", "display_name" => "Other", "presence" => "not_yet_seen", "conflict" => "read"),
      ],
      "selection" => "0199-h",
    }]]))

    rows = commands(:runners)

    assert_equal %w[0199-runner 0199-h 0199-k], rows.map { |row| row["public_id"] }
    assert_equal [
      "= 0199-runner  Helper  online  root /home/rho  tools 3  bound: c-3",
      "* 0199-h  Elsewhere  offline (last seen 3m ago)  root /srv/elsewhere  tools 2  bound: c-1, al-2",
      "  0199-k  Other  not yet seen  root /srv/elsewhere  tools 2  conflict: read",
      "* selected in settings  = this machine's own",
    ], @out.string.lines.map(&:chomp)
  end

  def test_runners_says_when_none_is_eligible
    announce(endpoint: routed_endpoint("GET /runners" => [[200, { "runners" => [], "selection" => nil }]]))

    assert_empty commands(:runners)
    assert_equal ["(no runner is eligible for this profile)"], @out.string.lines.map(&:chomp)
  end

  # The daemon validates the runner choice before the CLI saves it through
  # the same settings owner the browser uses.
  def test_runners_use_saves_the_settings_key_after_the_daemon_vouched_for_the_id
    seen = []
    announce(endpoint: recording_routed_endpoint(seen,
      "GET /runners" => [[200, { "runners" => [runner_row("0199-h")], "selection" => nil }]],
      "PATCH /settings" => [[200, { "settings" => {} }]]))
    File.write(home.settings_path, JSON.generate("default_model" => "m/x"))

    commands(:runners, "use", "0199-h")

    saves = -> { seen.grep(/\APATCH \/settings/).map { |request| JSON.parse(request.split("\r\n\r\n", 2).last) } }
    assert_equal [{ "runner" => "0199-h" }], saves.call
    assert_match(/^runner: 0199-h \(new conversations start on it\)$/, @out.string)

    error = assert_raises(Rho::Error) { commands(:runners, "use", "0199-zz") }
    assert_equal "0199-zz is not a runner this profile may address; `rho runners` lists them", error.message
    assert_equal [{ "runner" => "0199-h" }], saves.call, "a refused id writes nothing"

    commands(:runners, none: true)
    assert_equal [{ "runner" => "0199-h" }, { "runner" => nil }], saves.call, "--none explicitly clears the saved choice"
    assert_equal({ "default_model" => "m/x" }, JSON.parse(File.read(home.settings_path)), "only the daemon owns the live file write")
    assert_match(/^runner: none \(this machine's own runner when it has one\)$/, @out.string)
  end

  def test_runners_use_without_an_id_is_refused
    announce(endpoint: routed_endpoint("GET /runners" => [[200, { "runners" => [], "selection" => nil }]]))

    error = assert_raises(Rho::Error) { commands(:runners, "use") }
    assert_match(/rho runners use ID/, error.message)
  end

  def test_handoff_prints_the_move_and_the_runner_slot
    seen = []
    announce(endpoint: recording_endpoint(seen, 200, {
      "host" => { "type" => "conversation", "public_id" => "c-1" },
      "runner" => { "executor_public_id" => "0199-h", "display_name" => "Elsewhere", "presence" => "offline",
                    "last_seen_at" => (Time.now - 125).utc.iso8601 },
      "previous" => "0199-runner",
      "warning" => "old runner 0199-runner at /home/rho, new runner 0199-h at /srv/elsewhere — the tree is not synced",
    }))

    answer = commands(:handoff, "c-1", "0199-h")

    assert_equal "0199-h", answer.dig("runner", "executor_public_id")
    assert_match(%r{\APOST /handoff }, seen.grep(%r{/handoff}).first)
    assert_match(/"public_id":"c-1"/, seen.join)
    assert_match(/"executor_public_id":"0199-h"/, seen.join)
    assert_equal ["handed off: c-1 → 0199-h (was 0199-runner)",
                  "warning:   old runner 0199-runner at /home/rho, new runner 0199-h at /srv/elsewhere — the tree is not synced",
                  "runner:    0199-h offline (last seen 2m ago) — tool calls wait for it; rho handoff moves them"],
      @out.string.lines.map(&:chomp), "the tree-sync line once, between the move and the slot"

    @out = StringIO.new
    announce(endpoint: recording_endpoint([], 200, {
      "host" => { "type" => "agent_loop", "public_id" => "al-4" },
      "runner" => { "executor_public_id" => "0199-h", "presence" => "online" }, "previous" => nil,
    }))
    commands(:handoff, "al-4", "0199-h")
    assert_equal ["handed off: al-4 → 0199-h (was none)"], @out.string.lines.map(&:chomp),
      "online and no warning: nothing more is printed"
  end

  # The collision is one sentence and exit 1 — the daemon's own words.
  def test_handoff_relays_the_daemons_refusal_as_one_sentence
    announce(endpoint: recording_endpoint([], 409, {
      "error" => { "code" => "declaration_conflict",
                   "message" => "read is declared with different bytes by this rho and by 0199-k; " \
                                "a handoff would offer the model two readings of one name" },
    }))

    error = assert_raises(Rho::Error) { commands(:handoff, "c-1", "0199-k") }

    assert_match(/read is declared with different bytes/, error.message)
  end
end
