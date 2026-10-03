require "rho"
require "rho/acp"
require_relative "settings"
require_relative "children"

module Rho
  module AcpClient
    # THE VERBS, the words of one registered command
    # `acp-agents` (rho-mcp's `Commands#run` pattern; the core verb `acp`
    # is the agent surface's): `rho acp-agents` prints the rows from the
    # settings file as THIS process parses them — the launch line
    # redacted, the switch, a fault's sentence, the env NAMES masked — and
    # the daemon's live children under each (`GET /acp`); `probe NAME`
    # spawns the row from the CLI process in its own group, prints
    # `agentInfo`, the capabilities and each auth method's type, and
    # exits — prints and stores nothing; `enable|disable NAME` write the
    # row's switch through the shared Core settings operation; `sessions` lists the
    # daemon's table; `kill SESSION` goes through the daemon's `POST
    # /acp/kill` (the child is the daemon's, Core-shaped: `core.post`);
    # `logs SESSION` prints the session's capture, whose path the daemon's
    # document names.
    module Commands
      USAGE = "acp-agents | acp-agents probe NAME | acp-agents enable NAME | acp-agents disable NAME | " \
              "acp-agents sessions | acp-agents kill SESSION | acp-agents logs SESSION".freeze
      DESCRIPTION = "List the ACP agents `delegate_agent` can hand work to (settings.json#acp_agents) and the " \
                    "daemon's live children; `probe NAME` spawns one from here and prints what it declares; " \
                    "`enable NAME` / `disable NAME` save the row's switch and apply it to a running daemon; " \
                    "`sessions`, `kill SESSION`, `logs SESSION` read and end the daemon's children".freeze
      NO_DAEMON = "no daemon running — `rho acp-agents probe NAME` connects from here".freeze
      NOTHING_TO_LIST = "no daemon running — nothing to list".freeze
      Methods = Rho::Acp::Methods

      module_function

      def run(cli, args, _options)
        case args
        in [] then list(cli)
        in ["probe", name] then probe(cli, name)
        in ["enable", name] then switch(cli, name, true)
        in ["disable", name] then switch(cli, name, false)
        in ["sessions"] then sessions(cli)
        in ["kill", session] then kill(cli, session)
        in ["logs", session] then logs(cli, session)
        else refuse("usage: rho #{USAGE}")
        end
      end

      def refuse(sentence) = raise(Rho::Error, sentence)

      # ---- rho acp-agents ----

      def list(cli)
        daemon = cli.core.running_daemon
        document = daemon ? cli.core.parse(cli.core.get(daemon, "/acp")) : nil
        cli.out.puts NO_DAEMON if document.nil?
        live = document ? document.fetch("sessions").group_by { |session| session.fetch("agent") } : {}
        rows(cli).each do |row|
          print_row(cli.out, row, live.fetch(row.key, []))
        end
        document
      end

      def print_row(out, row, sessions)
        if row.fault?
          out.puts "agent:     #{row.key}  down: config: #{row.sentence}"
          return
        end

        redact = Rho::Runner::Redact.new(row.secrets)
        word = row.enabled? ? "enabled" : "disabled — `rho acp-agents enable #{row.key}`"
        out.puts "agent:     #{row.key}  #{escape(redact.call(row.launch))}  #{row.permissions}  #{seconds(row.timeout_ms)}s  " \
                 "#{escape(row.description)}  #{word}"
        out.puts "  env:     #{row.env.keys.map { |name| "#{name}=#{Rho::Runner::Redact::MASK}" }.join("  ")}" unless row.env.empty?
        sessions.each do |session|
          out.puts "  session: #{session_word(session)}"
        end
      end

      def session_word(session)
        "#{session.fetch("session")}  conversation #{session["conversation"]}  pid #{session["pid"]}  pgid #{session["pgid"]}  " \
          "calls #{session["calls"]}  cwd #{escape(session["cwd"])}"
      end

      def seconds(timeout_ms)
        value = timeout_ms / 1000.0
        value == value.to_i ? value.to_i.to_s : value.to_s
      end

      # The PERSON'S table as THIS process reads it: the test seam, else
      # rho's `Config` (the only reader of the file).
      def person_table(cli)
        table = Rho::AcpClient.settings_table
        return table unless table.nil?

        config = Rho::Config.load(cli.home.settings_path)
        (config.respond_to?(:acp_agents) ? config.acp_agents : nil) || {}
      end

      def rows(cli) = Settings.parse(person_table(cli), env: Rho::AcpClient.settings_env)

      # ---- rho acp-agents probe NAME ----

      def probe(cli, name)
        raw = person_table(cli)[name]
        refuse("no acp agent named #{name.inspect} in #{cli.home.settings_path}") if raw.nil?

        row = Settings.parse({ name => raw }, env: Rho::AcpClient.settings_env).fetch(0)
        if row.fault?
          cli.out.puts "agent:     #{name}  down: config: #{row.sentence}"
          return nil
        end

        probe_row(cli, row)
      end

      # The child is this verb's own — its own group, no capture, the
      # ladder in an `ensure` — connected in the working directory.
      def probe_row(cli, row)
        redact = Rho::Runner::Redact.new(row.secrets)
        shown = ->(text) { escape(redact.call(text.to_s)) }
        child = Children::Child.new(row, conversation: nil, redact: redact, log: nil, clock: -> { Time.now })
        begin
          child.spawn!(env: Rho::AcpClient.child_env(row), cwd: Dir.pwd)
          child.handshake!(deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + (row.timeout_ms / 1000.0))
        rescue Unavailable, Refused => error
          cli.out.puts "agent:     #{row.key}  #{shown.call(row.launch)}  down: #{shown.call(error.message)}"
          return nil
        end
        print_probe(cli.out, row, child, shown)
        child
      ensure
        child&.stop!
      end

      def print_probe(out, row, child, shown)
        info = child.agent_info
        out.puts "agent:     #{row.key}  #{shown.call(row.launch)}  connected (pid #{child.pid}, pgid #{child.group_pid})  " \
                 "protocol #{Methods::PROTOCOL_VERSION}  #{shown.call(info["name"] || "(unnamed)")} #{shown.call(info["version"])}".rstrip
        out.puts "  capabilities: #{capabilities_word(child.capabilities)}"
        methods = child.auth_methods.map { |method| "#{shown.call(method["id"])} (#{shown.call(method["type"] || Methods::AuthMethodType::AGENT)})" }
        out.puts "  auth methods: #{methods.empty? ? "(none)" : methods.join(", ")}"
        out.puts "  env:     #{row.env.keys.map { |name| "#{name}=#{Rho::Runner::Redact::MASK}" }.join("  ")}" unless row.env.empty?
      end

      def capabilities_word(capabilities)
        prompt = Hash.try_convert(capabilities["promptCapabilities"]) || {}
        mcp = Hash.try_convert(capabilities["mcpCapabilities"]) || {}
        session = Hash.try_convert(capabilities["sessionCapabilities"]) || {}
        prompts = ["text", *Methods::PROMPT_CAPABILITY_KEYS.select { |key| prompt[key] == true }]
        mcps = Methods::MCP_CAPABILITY_KEYS.select { |key| mcp[key] == true }
        [
          "loadSession=#{capabilities["loadSession"] == true}",
          "prompt=#{prompts.join("+")}",
          "mcp=#{mcps.empty? ? "none" : mcps.join("+")}",
          "session=#{session.empty? ? "none" : session.keys.sort.join("+")}",
        ].join(", ")
      end

      # ---- rho acp-agents enable NAME / disable NAME ----

      def switch(cli, name, enabled)
        person = person_table(cli)
        refuse("no acp agent named #{name.inspect} in #{cli.home.settings_path}") unless person.key?(name)
        if enabled?(person.fetch(name)) == enabled
          cli.out.puts "#{name} is already #{enabled ? "enabled" : "disabled"}"
          return nil
        end

        row = (Hash.try_convert(person[name]) || {}).merge(Settings::ENABLED => enabled)
        table = person.merge(name => row)
        cli.core.update_settings("acp_agents" => table)
        cli.out.puts "#{enabled ? "enabled" : "disabled"} #{name}"
        table
      end

      def enabled?(raw) = Hash.try_convert(raw)&.fetch(Settings::ENABLED, true) == true

      # ---- rho acp-agents sessions / kill SESSION / logs SESSION ----

      def sessions(cli)
        document = daemon_document(cli)
        document.fetch("sessions").each do |session|
          cli.out.puts "session:   #{session.fetch("session")}  #{session["agent"]}  conversation #{session["conversation"]}  " \
                       "pid #{session["pid"]}  pgid #{session["pgid"]}  calls #{session["calls"]}  cwd #{escape(session["cwd"])}  " \
                       "capture #{escape(session["capture"])}"
        end
        document
      end

      def kill(cli, session)
        daemon = cli.core.running_daemon || refuse(NOTHING_TO_LIST)
        answer = cli.core.parse(cli.core.post(daemon, "/acp/kill", { "session" => session }, budget: Rho::Core::Budget::LOCAL))
        refuse(answer.dig("error", "message").to_s) if answer["error"]
        cli.out.puts "killed #{answer["session"]} (#{answer["agent"]}, pid #{answer["pid"]})"
        answer
      end

      def logs(cli, session)
        document = daemon_document(cli)
        row = document.fetch("sessions").find { |candidate| candidate["session"] == session }
        refuse("no session #{session} on this daemon") if row.nil?

        path = row["capture"].to_s
        refuse("session #{session} has no capture") if path.empty? || !File.file?(path)

        cli.out.write(File.read(path, encoding: Encoding::UTF_8))
        path
      end

      def daemon_document(cli)
        daemon = cli.core.running_daemon || refuse(NOTHING_TO_LIST)
        cli.core.parse(cli.core.get(daemon, "/acp"))
      end

      # Zero-width and bidi characters read one way to a terminal and
      # another to a model; every C0/C1 control byte likewise.
      INVISIBLE = /[​-‏ -‮⁠-⁤﻿ ---]/

      def escape(text)
        text.to_s.gsub(/[\n\t\r]|#{INVISIBLE}/) do |char|
          case char
          when "\n" then "\\n"
          when "\t" then "\\t"
          when "\r" then "\\r"
          else format("\\u{%X}", char.ord)
          end
        end
      end
    end
  end
end
