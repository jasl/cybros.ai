module Rho
  module Acp
    class Agent
      # WHAT `initialize` TOLD US: the client's name
      # (the deny reason names it; the port's `client`) and the capabilities the surface acts on — `fs.readTextFile` /
      # `fs.writeTextFile` (the port is registered only for flags the
      # client advertised), `elicitation.form` (the ask as a form),
      # `elicitation.url` (the ceremony as a card), `auth.terminal` (the
      # `connect` auth method is offered). Remembered per connection, read
      # from any thread after the handshake.
      class Client
        DEFAULT_NAME = "the client".freeze

        attr_reader :name, :title, :version

        def initialize
          @name = DEFAULT_NAME
          @title = nil
          @version = nil
          @fs_read = false
          @fs_write = false
          @form = false
          @url = false
          @terminal = false
        end

        def remember(params)
          info = Hash.try_convert(params["clientInfo"]) || {}
          @name = info["name"].to_s.empty? ? DEFAULT_NAME : info["name"].to_s
          @title = info["title"]
          @version = info["version"]
          capabilities = Hash.try_convert(params["clientCapabilities"]) || {}
          fs = Hash.try_convert(capabilities["fs"]) || {}
          @fs_read = fs["readTextFile"] == true
          @fs_write = fs["writeTextFile"] == true
          # The schema spells a supported elicitation mode as `{}`
          # (presence); a boolean `true` is read the same way.
          elicitation = Hash.try_convert(capabilities["elicitation"]) || {}
          @form = offered?(elicitation["form"])
          @url = offered?(elicitation["url"])
          auth = Hash.try_convert(capabilities["auth"]) || {}
          @terminal = auth["terminal"] == true
          self
        end

        def offered?(value) = value == true || !Hash.try_convert(value).nil?
        private :offered?

        def fs_read? = @fs_read
        def fs_write? = @fs_write
        def fs? = @fs_read || @fs_write
        def elicitation_form? = @form
        def elicitation_url? = @url
        def auth_terminal? = @terminal
      end

      # ONE TOOL CALL AS THE CLIENT SAW IT: what the first sight's
      # `Core#task` read answered — the title, the ACP kind, the raw input
      # — and the last status sent, so a later frame is an update and the
      # park's `session/request_permission` names the call without a
      # second read.
      ToolCall = Struct.new(:title, :kind, :input, :status, :tool_name, keyword_init: true)

      # THE PER-TURN COUNTERS: `message` is the `messageId`
      # suffix, bumped on every `stream_reset` so a replacement never
      # merges into the discarded reply; `transcript` the bounded reply
      # already sent, against which a re-join's snapshot is reconciled;
      # `tasks` the calls sent, by key.
      class TurnState
        attr_accessor :message, :run_public_id
        attr_reader :turn, :tasks, :transcript

        def initialize(turn:, run_public_id: nil)
          @turn = turn
          @run_public_id = run_public_id
          @message = 0
          @transcript = CybrosAgent::Api::TranscriptAccumulator.new
          @tasks = {}
        end

        def message_id = "#{@turn}:#{@message}"
      end

      # A HELD ASK: the model's question without a form — the NEXT
      # prompt is `Core#answer` on it, and the same turn is followed on.
      Hold = Data.define(:run_public_id, :key, :turn)

      # THE RE-ARM'S HOLD ON THE PROMPT SLOT: a `session/load` onto a held ask, with the form, claims the
      # session's one prompt slot BEFORE its card's thread starts and keeps
      # it until the card is answered and the turn followed to its end,
      # cancelled on the card, or cancelled by `session/cancel` — so a
      # `session/prompt` meanwhile is the drain's -32600 like any second
      # prompt, never a second thread working the same turn. Not an
      # inbound: nothing answers, fails or cancels it, and no reader of the
      # slot treats its holder as one.
      Rearm = Data.define(:run_public_id, :key, :turn)

      # ONE SESSION (nothing of ACP's is stored — this table is the process's memory): the id IS the conversation's public id; the
      # mode and the model applied to the NEXT prompt; the held ask; the
      # in-flight prompt's holder (one per session); the root set
      # the client bound; whether servers were bound (the close sends
      # `mcp: []` only then); the requests this surface issued on the
      # session (permission, elicitation) so `session/cancel` can cancel
      # each; the current turn's counters; the models the picker learned.
      class Session
        attr_reader :id, :root, :directories
        attr_accessor :mode, :model, :held, :servers, :ended, :last_turn, :last_variant, :last_loop

        def initialize(id:, mode:, model:, root:, directories: [])
          @id = id
          @mode = mode
          @model = model
          @root = root
          @directories = directories
          @held = nil
          @servers = false
          @ended = false
          @last_turn = nil
          @last_variant = nil
          @last_loop = nil
          @lock = Mutex.new
          @prompt = nil
          @cancel_requested = false
          @outstanding = []
          @state = nil
          @models = []
        end

        # ---- the one prompt in flight ----

        # Claims the slot for `holder` — a prompt's inbound, or a `Rearm`;
        # false when another holds it. The claimant releases it, on the
        # way out of its own thread.
        def claim_prompt(holder)
          @lock.synchronize do
            next false unless @prompt.nil?

            @prompt = holder
            @cancel_requested = false
            true
          end
        end

        def release_prompt
          @lock.synchronize { @prompt = nil }
        end

        def prompt = @lock.synchronize { @prompt }
        def busy? = !prompt.nil?

        # ---- cancel ----

        def request_cancel!
          @lock.synchronize { @cancel_requested = true }
        end

        def cancel_requested? = @lock.synchronize { @cancel_requested }

        # A request this surface issued on the session, tracked while it
        # waits so a cancel reaches it; answers the block's value.
        def track(pending)
          @lock.synchronize { @outstanding << pending }
          yield
        ensure
          @lock.synchronize { @outstanding.delete(pending) }
        end

        # `$/cancel_request` for every outstanding request.
        def cancel_outstanding
          @lock.synchronize { @outstanding.dup }.each(&:cancel)
          nil
        end

        # ---- the turn's counters ----

        # The counters of `turn`, started over for a turn not yet seen.
        def turn_state(turn, run_public_id: nil)
          @lock.synchronize do
            @state = TurnState.new(turn: turn, run_public_id: run_public_id) if @state.nil? || @state.turn != turn
            @state.run_public_id ||= run_public_id
            @state
          end
        end

        # ---- the picker's models ----

        def models = @lock.synchronize { @models.dup }

        def learn_model(ref)
          @lock.synchronize { @models << ref unless @models.include?(ref) }
        end

        # Whether `path` sits under the session's root set (the port's
        # routing rule: a read is the session's whose roots hold the path).
        def holds?(path)
          [@root, *@directories].any? { |root| root && (path == root || path.start_with?("#{root}/")) }
        end
      end

      # THE TABLE, by conversation id, from any thread.
      class Sessions
        def initialize
          @lock = Mutex.new
          @rows = {}
        end

        def add(session)
          @lock.synchronize { @rows[session.id] = session }
          session
        end

        def [](id) = @lock.synchronize { @rows[id] }

        def delete(id) = @lock.synchronize { @rows.delete(id) }

        def each(&) = @lock.synchronize { @rows.values }.each(&)

        def empty? = @lock.synchronize { @rows.empty? }

        # THE PORT'S ROUTING: the daemon's read names a path
        # and no session — the session is the newest whose root set holds
        # the path, else the newest session at all (one editor window is
        # one process; several windows on one process are several roots).
        def for_path(path)
          rows = @lock.synchronize { @rows.values }
          rows.reverse.find { |session| session.holds?(path) } || rows.last
        end
      end
    end
  end
end
