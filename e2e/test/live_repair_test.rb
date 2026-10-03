require "test_helper"
require "support/live_journey"

# A LOOP THAT ACTUALLY HALTS, AND A PERSON WHO FIXES IT.
#
# Until the repair verbs shipped, `rho watch` could print `ASKING
# halt_failure` and then offer nothing: the kernel's three deciding verbs
# had no client, the ask has no clock, and the only exits were hand-rolled
# HTTP or throwing the whole run away with `rho stop`.
#
# The halt is authored deliberately, over the member plane, because no rho
# verb can create one on purpose: two awaits with a one-second clock and
# `on_failure: "halt"`, and a round that depends on both. They time out,
# the loop rests on an unresolved failure, and then the person works: one
# `rho abandon`, one `rho retry`, and the round it was gating runs.
#
# Paid, local, opt-in: E2E_LIVE=1.
class LiveRepairTest < Minitest::Test
  MODEL = ENV.fetch("E2E_LIVE_MODEL") { E2E::LiveJourney.default_model }.freeze

  include E2E::LiveJourney

  def setup = start_live_journey!(MODEL, home_prefix: "rho-live-repair-e2e")
  def teardown = finish_live_journey!

  def test_a_halted_loop_is_repaired_from_the_terminal_and_then_finishes
    connect_and_open_lane!
    loop_id = author_halting_loop!

    halted = await_halt(loop_id)
    report(halted)
    assert_equal "needs_attention", halted.fetch("status")
    assert_equal "halt_failure", halted.dig("attention", "reason")

    # BOTH GATES TIMED OUT, so the kernel's rule names two candidates and
    # the daemon refuses to guess between them.
    ambiguous, status = @daemon.cli("retry", loop_id)
    refute_predicate status, :success?, "two candidates must refuse:\n#{ambiguous}"
    assert_match(/gate-1/, ambiguous)
    assert_match(/gate-2/, ambiguous)

    # Give up on one, re-run the other. Both are the person's decision, and
    # the loop can move only once nothing unresolved is left.
    abandoned, status = @daemon.cli("abandon", loop_id, "gate-1")
    assert_predicate status, :success?, abandoned
    assert_match(/^abandoned:\s+gate-1$/, abandoned, abandoned)
    assert_match(/^status:\s+timed_out$/, abandoned, abandoned)

    retried, status = @daemon.cli("retry", loop_id)
    assert_predicate status, :success?, "one candidate left, so no key was needed:\n#{retried}"
    assert_match(/^retried:\s+gate-2$/, retried, retried)

    # `gate-2` is a fresh park now, so the loop is running again rather than
    # asking. Answer it with the token its receipt returned — an await a
    # CLIENT authored is answered by presenting that token, never by write
    # standing alone, and the kernel refuses `stale_claim` without it.
    answered, status = @daemon.cli("answer", loop_id, "gate-2", "go ahead",
      "--token", @gate_tokens.fetch("gate-2"))
    assert_predicate status, :success?, answered

    done = await_loop_completion(loop_id)
    report(done)
    assert_equal "completed", done.fetch("status"), summarize(done)
    keys = done.fetch("tasks").to_h { |task| [task.fetch("key"), task] }
    assert_equal "abandoned", keys.fetch("gate-1").fetch("failure_resolution")
    assert_equal "completed", keys.fetch("gate-2").fetch("status")
    assert_equal "completed", keys.fetch("work").fetch("status"),
      "the round both gates blocked ran once they were resolved"

    result, = @daemon.cli("result", loop_id)
    assert_match(/DONE/i, result, result)
  end

  private

    # Two one-second asks with `halt` in one fan, and a round placed after
    # them — it waits on both and reads their answers by position. Authored
    # over the member plane: this is the one shape rho cannot ask for.
    def author_halting_loop!
      path = "/agent_api/v1/workspaces/#{workspace_public_id}/agent_loops"
      gates = [1, 2].map do |n|
        { "ask" => { "key" => "gate-#{n}", "prompt" => "gate #{n}",
                     "timeout_ms" => 1000, "on_failure" => "halt" } }
      end
      body, status = agent_api_post(path, { "agent_loop" => {
        "steps" => [
          { "parallel" => gates },
          { "model" => { "key" => "work", "prompt" => "Reply with exactly DONE.",
                         "model" => { "model" => MODEL } } },
        ],
        "approval_mode" => "bypass",
      } })
      assert_equal 201, status, "authoring the halting loop: #{body}"
      loop_id = body.dig("agent_loop", "public_id")
      # THE ONLY PLACE A RESOLUTION TOKEN IS EVER RETURNED. A retry does not
      # rotate it, so the one from creation still answers the re-armed park.
      @gate_tokens = body.dig("receipt", "resolution_tokens") || {}
      assert_equal %w[gate-1 gate-2], @gate_tokens.keys.sort,
        "an authored await is minted a token and it rides out in the receipt"

      _, started = agent_api_post("#{path}/#{loop_id}/start", {})
      assert_equal 200, started, "starting the halting loop"
      @daemon.control(:post, "/loops/subscribe", body: { public_id: loop_id })
      loop_id
    end

    def report(row)
      puts "\n--- live repair ------------------------------------------------"
      puts "model:     #{MODEL}"
      puts "status:    #{row.fetch("status")}#{" / #{row.dig("attention", "reason")}" if row["attention"]}"
      puts "tasks:     #{row.fetch("tasks").map { |t| "#{t["key"]}=#{t["status"]}" }.join(" ")}"
      puts "--------------------------------------------------------------"
    end
end
