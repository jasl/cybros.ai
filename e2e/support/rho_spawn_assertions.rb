module E2E
  # Shared assertions for the spawned-conversation journeys.
  module RhoSpawnAssertions
    private

      # ---- the mock's script ----

      # `!mock tool_call=<name>:<args>,… -- <remainder>`: one scripted call
      # per round, each with its own url-encoded arguments, then the fake
      # speaks the remainder. A nested brief is a whole script inside the
      # `prompt` argument, escaped with it.
      def script(calls, remainder, reply: nil)
        spelled = calls.map { |name, arguments| "#{name}:#{CGI.escape(JSON.generate(arguments))}" }
        answer = "reply=#{CGI.escape(reply)} " if reply
        "!mock #{answer}tool_call=#{spelled.join(",")} -- #{remainder}"
      end

      def sleep_arguments(seconds) = { "command" => "sleep #{seconds}" }

      # The speaker envelope's opening line (`SpeakerEnvelope.render`): the
      # author's handle, kind and id, and the conversation the row was sent from.
      def envelope_opening(handle, profile, sender)
        %(<message from="@#{handle}" kind="agent" user="#{profile}" conversation="#{sender}">)
      end

      # ---- the rho half ----

      def rho_do(prompt)
        output, status = @daemon.cli("do", prompt, "--model", self.class::MODEL, "--dir", @world.project)
        assert_predicate status, :success?, "rho do failed:\n#{output}"
        ids = %w[conversation turn run].map { |line| output[/^#{line}:\s+(\S+)/, 1] }
        refute_includes ids, nil, "rho do printed fewer than three ids:\n#{output}"
        ids
      end

      def rho_say(conversation, text, mode: nil)
        arguments = ["say", conversation, text]
        arguments += ["--mode", mode] if mode
        said, status = @daemon.cli(*arguments)
        assert_predicate status, :success?, "rho say failed:\n#{said}"
        input_id = said[/^queued:\s+(\S+)/, 1]
        refute_nil input_id, "rho say printed no input id:\n#{said}"
        input_id
      end

      # A home's profile and handle as `rho status` prints them, once its
      # runner has announced and its profile is declared — the second is the
      # engine a conversation or a child needs before its first head.
      def rho_identity(daemon)
        cached = daemon.equal?(@daemon) ? [@world.profile, @world.handle] : [@world.peer_profile, @world.peer_handle]
        return cached if cached.first

        daemon.await("rho never announced its tools") do
          runner = daemon.control(:get, "/runner")["runner"]
          runner if runner && runner["announced"] == runner.fetch("tools").length
        end
        daemon.await("rho never declared its profile") do
          daemon.log_lines.find { |line| line["event"] == "profile.declared" }
        end
        printed, status = daemon.cli("status")
        assert_predicate status, :success?, "rho status failed:\n#{printed}"
        ids = [printed[/^profile:\s+(\S+)/, 1], printed[/^handle:\s+@(\S+)/, 1]]
        refute_includes ids, nil, "rho status printed no profile or handle line:\n#{printed}"
        if daemon.equal?(@daemon)
          @world.profile, @world.handle = ids
        else
          @world.peer_profile, @world.peer_handle = ids
        end
        ids
      end

      # HOME B: a second full rho under the same steward and the same room
      # address — one more device grant, spent once per file. Answers the
      # daemon and its identity.
      def peer_home
        unless @world.peer_daemon
          home = Dir.mktmpdir("rho-spawn-peer-e2e")
          daemon = E2E::RhoDaemon.new(base_url: @base_url, home: home, env: { "RHO_WORKSPACE" => @room })
          @world.peer_home = home
          @world.peer_daemon = daemon
          daemon.start
          E2E::Ceremony.confirm(actor: @world.actor, started: daemon.start_ceremony, status: -> { daemon.status })
          adopted = self.class.await_workspace_adopted(daemon)
          assert_equal @room, adopted, "home B adopted the same room under the knob"
        end
        [@world.peer_daemon, *rho_identity(@world.peer_daemon)]
      end

      # ---- the SDK half ----

      # The first child under `chat` carrying the label the spawn gave it,
      # off the parent's children door.
      def await_child(chat, label:)
        await("no child labelled #{label} under #{chat.public_id}", every: self.class::POLL) do
          chat.children.items.find { |row| row.parent&.label == label }
        end
      end

      def await_reply(chat, after:)
        await("no reply settled past position #{after} on #{chat.public_id}", every: self.class::POLL) do
          newer = chat.turns.list.items.select { |turn| turn.position > after && turn.role == "assistant" }
          failed = newer.find { |turn| turn.status == "failed" }
          flunk "the reply failed: #{failed.to_h.inspect}" if failed
          newer.find { |turn| turn.status == "completed" }
        end
      end

      # The assistant turn past `after` that is RUNNING with its loop minted.
      def await_running_turn(chat, after:)
        await("no running turn past position #{after} on #{chat.public_id}", every: self.class::POLL) do
          chat.turns.list.items.find do |turn|
            turn.position > after && turn.role == "assistant" && turn.status == "running" &&
              turn.active_variant&.run_public_id
          end
        end
      end

      # ---- the member plane, as the steward ----

      def agent_api(path)
        uri = URI.join(@base_url, path)
        request = Net::HTTP::Get.new(uri)
        request["Authorization"] = "Bearer #{@steward.member_token}"
        response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
        JSON.parse(response.body.force_encoding(Encoding::UTF_8))
      end

      def loop_path(loop) = "/agent_api/v1/workspaces/#{@room}/runs/#{loop}"

      def loop_row(loop)
        document = agent_api(loop_path(loop))
        document.fetch("run") { flunk "the loop read was refused: #{document.inspect}" }
      end

      # A task's result as the model read it: `output` is the body's own
      # text and `content` the same body's blocks (`task_detail`), so the
      # blocks are read only when the kernel wrote no `output`.
      # The row's result once the row SETTLED: `spawn` creates the child in
      # its own transaction and settles its row in a later one (three
      # durable steps), so a read that follows the child's appearance can
      # land on a row whose output is not yet written — the same bytes,
      # read after the settle.
      def task_result(loop, task_key)
        task = await("the task #{task_key} of #{loop} never settled", every: self.class::POLL) do
          document = agent_api("#{loop_path(loop)}/tasks/#{task_key}")
          row = document.fetch("task") { flunk "the task read was refused: #{document.inspect}" }
          row if TERMINAL_TASK_STATUSES.include?(row["status"])
        end
        task["output"] || Array(task["content"]).map { |block| block["text"] }.compact.join
      end

      TERMINAL_TASK_STATUSES = %w[completed failed canceled timed_out uncertain skipped].freeze

      # Every string the sealed request of a round carries, whatever the
      # wire's shape (a user part, a tool result's output): what the model
      # was shown, searchable as text.
      def sealed_texts(loop, task_key)
        document = agent_api("#{loop_path(loop)}/tasks/#{task_key}/request")
        entries = document.dig("request", "entries")
        refute_nil entries, "round #{task_key} of #{loop} has no sealed request: #{document.inspect}"
        texts_of(entries)
      end

      def texts_of(value)
        case value
        when String then [value]
        when Array then value.flat_map { |item| texts_of(item) }
        when Hash then value.values.flat_map { |item| texts_of(item) }
        else []
        end
      end

      def await_run_status(loop, status)
        await("the loop #{loop} never reached #{status}", every: self.class::POLL) do
          row = loop_row(loop)
          row if row["status"] == status
        end
      end

      # The slow tool dispatched or running: r1 is sealed and the window open.
      def await_tool_running(loop)
        await("the slow tool never started on #{loop}", every: self.class::POLL) do
          row = loop_row(loop)
          row if row.fetch("tasks").any? { |task| task["kind"] == "tool_task" && %w[dispatched running].include?(task["status"]) }
        end
      end

      def feed(conversation)
        items = []
        after = nil
        loop do
          page = agent_api("/agent_api/v1/workspaces/#{@room}/conversations/#{conversation}/events" \
            "?limit=200#{after ? "&after=#{after}" : ""}")
          rows = Array(page["events"])
          items.concat(rows)
          after = page.dig("pagination", "next_after")
          break if after.nil? || rows.empty?
        end
        items
      end

      def await_feed(conversation, message)
        await(message, every: self.class::POLL) { yield(feed(conversation)) }
      end

      # Every turn the feed opened on a loop other than `except`, in feed
      # order — the drain's own order, which the mail cases read.
      def new_turns(items, except:)
        items.select do |item|
          item["type"] == "turn_status" && item.dig("payload", "status") == "running" &&
            !except.include?(item.dig("payload", "run_public_id"))
        end.sort_by { |item| item.fetch("sequence") }
      end

      # The materialization that opened a turn: the input it drained.
      def materialized(items, opened)
        items.find { |item| item["type"] == "input_materialized" && item.dig("payload", "turn_public_id") == opened.dig("payload", "turn_public_id") } ||
          flunk("no materialization named the turn #{opened.inspect}: #{items.map { |item| item["type"] }.inspect}")
      end

      def summarize(row)
        row.fetch("tasks").map do |task|
          "#{task.fetch("key")}(#{task.fetch("kind")}/#{task.fetch("status")}#{task["tool_name"] ? ":#{task["tool_name"]}" : ""})"
        end.join(" ")
      end

      def await(message, every:)
        latest = nil
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + self.class::AWAIT_SECONDS
        loop do
          latest = yield
          return latest if latest
          flunk "#{message}; last seen #{latest.inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          sleep every
        end
      end

      LOG_TAIL_LINES = 80

      def warn_log(path, label)
        return unless path && File.file?(path)

        tail = File.read(path, encoding: Encoding::UTF_8).scrub.lines.last(LOG_TAIL_LINES).join
        warn "#{label} (last #{LOG_TAIL_LINES} lines):\n#{E2E::SecretHygiene.redact(tail)}"
      end
  end
end
