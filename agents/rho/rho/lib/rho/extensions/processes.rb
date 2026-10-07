require "rho/runner"
require_relative "../processes"
# `routes` first: the person's tool shares its body and its bounds.
require_relative "processes/routes"
require_relative "processes/tools"
require_relative "processes/remote"
require_relative "processes/commands"

module Rho
  module Extensions
    # The background task by the product's definition: something the person can see and
    # operate. One table, the daemon's, behind the model's tools and the person's routes; it
    # dies with the daemon, never past it — and with its CONVERSATION: the daemon releases a
    # conversation's processes when it ends here, and the validity sweep below is the
    # fallback for a group that died unnoticed.
    #
    # THE TABLE ELSEWHERE: a followed host whose runner is not
    # this process filled a table THERE. `list` and `log` below are the
    # person's two reads of any runner's table — this machine's own from
    # the table in hand, another's through ONE SDK request each (`Remote`)
    # — and the routes and verbs read through them, so `rho ps`/`rho logs`
    # show the rows wherever they live instead of an honest line about
    # where they are not.
    module Processes
      NAME = "rho.processes".freeze
      # One constant sentence: the block heads a cached prefix, and a pid
      # table in it would be stale by construction. The live facts ride list_processes.
      ENVIRONMENT_SENTENCE =
        "Processes started earlier (a dev server, say) may still be running: call " \
        "list_processes before starting one, and read_process to find its address.".freeze
      # The model's four, and the person's `process_log` beside them
      # (announced described to nobody).
      TOOLS = [
        Tools::StartProcess, Tools::ListProcesses, Tools::ReadProcess, Tools::StopProcess,
        Tools::ProcessLog,
      ].freeze

      # Bound at registration: a hook looking the table up at call time
      # would, with two daemons in one process, close the other's on
      # shutdown. Under the base handle and the CLI loader there is none; nil-safe.
      # The tools go to a host that serves the runner address (an agent-mode
      # rho serves none and keeps the verbs: its `rho ps` reads runners
      # elsewhere); the rest registers under every host.
      def self.register(api)
        table = api.host&.processes
        TOOLS.each { |klass| api.register_tool(klass) } if api.serves?(:runner)
        api.describe_environment { |_environment| table&.any_live? ? ENVIRONMENT_SENTENCE : nil }
        api.on(:tool_result) { |_name, result| with_notices(result, table) }
        api.on(:startup) { table&.sweep_orphans }
        api.on(:shutdown) { table&.close }
        api.background("#{NAME}.sweep") { sweep(table) }
        # THE WATCHER'S FRAMES: the table's pump posts every
        # live row's lines under its host for the daemon's life; it ends
        # with the table.
        api.background("#{NAME}.progress") { table&.progress&.run }
        Routes.register(api, table)
        register_commands(api)
      end

      # ---- the person's two reads, wherever the table lives ----

      # The rows of ONE runner's table: this machine's own (`runner` nil or
      # this daemon's runner row) from `table`; another's through the call_tool,
      # each row naming its runner. Raises `Remote::Unreachable` for a runner
      # that could not answer.
      def self.list(ctx, runner, table)
        return (table.nil? ? [] : table.snapshots.map(&:to_h)) if runner.nil? || ctx.own_runner?(runner)

        Remote.list(ctx, runner)
      end

      # One row's tail — `{process, path, lines}` — from this machine's table
      # (a dead group's remembered exit included) or from the runner named;
      # nil for an id nobody knows.
      def self.log(ctx, runner, id, lines, table)
        return Routes.read_log(table, id, lines) if runner.nil? || ctx.own_runner?(runner)

        Remote.log(ctx, runner, id, lines)
      end

      # THE VALIDITY SWEEP: on the daemon's reactor for its lifetime, a short sleep apart; it
      # ends when the table closes. The pump retires a dead group the moment its pipe closes,
      # so this removes only what that missed.
      def self.sweep(table)
        return if table.nil?

        loop do
          sleep Rho::Processes::Registry::SWEEP_SECONDS
          break if table.closed?

          table.sweep_dead!
        end
      end

      def self.register_commands(api)
        api.register_command("processes",
          description: "List the processes runs started: this machine's, and every followed host's runner's " \
                       "(--runner ID for one runner's table)",
          options: { runner: { type: :string, desc: "One runner's table alone, by its executor id" } },
          aliases: %w[procs ps], &Commands.method(:processes))
        api.register_command("kill", usage: "kill ID",
          description: "Stop a process a run started: TERM, then KILL", &Commands.method(:kill))
        api.register_command("logs", usage: "logs ID",
          description: "Print the latest output of a process a run started, here or on a followed host's runner",
          options: {
            tail: { type: :numeric, default: Commands::LOG_TAIL, desc: "How many of the latest lines" },
            runner: { type: :string, desc: "The runner whose table holds the id (default: this machine's, else " \
                                            "the one runner followed hosts are bound to)" },
          },
          &Commands.method(:logs))
      end

      # A process that ended without its run's say-so is announced to that
      # run once, so it neither restarts a server the person closed nor
      # keeps talking to one that is gone.
      def self.with_notices(result, table)
        context = Rho::Runner::ExecutionContext.current
        return nil if context&.run_public_id.nil? || table.nil?

        notices = table.take_notices(context.run_public_id, conversation: context.conversation_public_id)
        return nil if notices.empty?

        result.with(content: "#{result.content}\n\n#{notices.join("\n")}")
      end
    end
  end
end
