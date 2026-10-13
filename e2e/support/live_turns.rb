require "json"
require "support/live_journey"

module E2E
  # THE SMOKE LANES' SHARED READS (the smoke round before the paid window):
  # a turn opened through `rho do` and its three ids; the steward's SDK
  # client and a conversation's door through it (the member plane the
  # webui will read); the conversation's feed and the next turn it opened.
  # One implementation per mechanism, included beside `LiveJourney` (which
  # owns the daemon, the cost stop and the report line) by the lanes
  # `live_todo`, `live_grant`, `live_deliver_at`, `live_named_agent` and
  # `live_web_fetch` (the fetch's output through `task_output`).
  module LiveTurns
    NEXT_TURN_POLL_SECONDS = 3

    # `rho do TEXT --model MODEL --dir DIR *FLAGS`: the conversation every
    # verb addresses, its turn, and the loop the kernel reads.
    def rho_do_turn(text, *flags, model:, dir:)
      output, status = @daemon.cli("do", text, "--model", model, "--dir", dir, *flags)
      assert_predicate status, :success?, "rho do failed:\n#{output}"
      ids = %w[conversation turn run].map { |line| output[/^#{line}:\s+(\S+)/, 1] }
      refute_includes ids, nil, "rho do printed fewer than three ids:\n#{output}"
      ids
    end

    # THE STEWARD'S DOOR: the person who owns the work reads through the
    # SDK, as the webui will.
    def steward_client
      @steward_client ||= CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    end

    def conversation_door(conversation)
      steward_client.workspace(workspace_public_id).conversations.conversation(conversation)
    end

    # The member task read, whole: the row and its bodies.
    def task_detail(run_public_id, key) = agent_api("#{loop_path(run_public_id)}/tasks/#{key}").fetch("task")

    def task_input(run_public_id, key) = Hash.try_convert(task_detail(run_public_id, key)["tool_input"]) || {}

    def task_output(run_public_id, key) = task_detail(run_public_id, key)["output"].to_s

    # The conversation's whole feed, paged through the replay window.
    def feed(conversation)
      items = []
      after = nil
      loop do
        page = agent_api("/agent_api/v1/workspaces/#{workspace_public_id}/conversations/#{conversation}/events" \
          "?limit=200#{after ? "&after=#{after}" : ""}")
        rows = Array(page["events"])
        items.concat(rows)
        after = page.dig("pagination", "next_after")
        break if after.nil? || rows.empty?
      end
      items
    end

    # The loop backing the first turn the feed opened on none of `after`'s
    # loops; nil past `deadline` (a lane that expects no turn reads nil).
    def next_turn_loop(conversation, after:, deadline:)
      limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + deadline
      loop do
        found = feed(conversation).find do |item|
          item["type"] == "turn_status" && item.dig("payload", "run_public_id") &&
            !after.include?(item.dig("payload", "run_public_id"))
        end
        return found.dig("payload", "run_public_id") if found
        return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) > limit

        sleep NEXT_TURN_POLL_SECONDS
      end
    end

    def await_next_turn(conversation, after:, deadline: E2E::LiveJourney::LOOP_DEADLINE_SECONDS)
      next_turn_loop(conversation, after: after, deadline: deadline) ||
        flunk("the next turn on #{conversation} never started in #{deadline} s")
    end

    # The settled assistant reply on a conversation past `after`, through
    # the SDK; a failed one fails HERE with its row.
    def await_reply(chat, after:, deadline: E2E::LiveJourney::LOOP_DEADLINE_SECONDS)
      limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + deadline
      loop do
        newer = chat.turns.list.items.select { |turn| turn.position > after && turn.role == "assistant" }
        failed = newer.find { |turn| turn.status == "failed" }
        flunk "the reply on #{chat.public_id} failed: #{failed.to_h.inspect}" if failed
        done = newer.find { |turn| turn.status == "completed" }
        return done if done
        flunk "no reply settled past position #{after} on #{chat.public_id} in #{deadline} s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > limit

        sleep NEXT_TURN_POLL_SECONDS
      end
    end
  end
end
