require "uri"

module Rho
  module Extensions
    # Where this machine's tools are pointed and what it can do — the chip a
    # UI will render, debuggable from a terminal before that UI exists
    # — and THE CONVERSATION'S ENVIRONMENT:
    # rho's record
    # in the conversation's own store, read through one door, bound
    # through another, listed as the live table, and relayed to a runner
    # elsewhere through the hidden runner tool this extension serves.
    module Environment
      NAME = "rho.environment".freeze
      # THE RECORD'S TWO SPELLINGS: nothing reserves them
      # kernel-side, so rho pins them here — once — and every reader and
      # writer names the constants. The namespace IS the extension's name,
      # as `HostStore` notes are keyed.
      STORE_NAMESPACE = NAME
      STORE_KEY = "binding".freeze

      def self.register(api)
        # Telling a model where it is does not make it work there; pointing
        # the runner is what makes it true.
        api.register_route("GET", "/environment") { |_request, ctx| [200, Routes.document(ctx.environment)] }
        api.register_route("POST", "/environment") { |request, ctx| Routes.set(request, ctx) }
        # One loop per address: the runner's and the agent's own,
        # so "is it taking work?" is one whole answer per address.
        api.register_route("GET", "/runner") { |_request, ctx| [200, Routes.runner(ctx)] }
        # THE CONVERSATION'S RECORD: the read carries the
        # id on the query as rho's GET doors do; the write in the body.
        api.register_route("GET", "/conversations/environment") { |request, ctx| Routes.conversation(request, ctx) }
        api.register_route("POST", "/conversations/environment") { |request, ctx| Routes.bind(request, ctx) }
        api.register_route("GET", "/environments") { |_request, ctx| Routes.environments(ctx) }
        # THE RECEIVING TOOL, on every host serving the runner
        # address — a full-mode rho is somebody else's bound runner too;
        # agent mode serves no runner tool and registers none.
        if api.serves?(:runner)
          Tools::Bind.bind(environments: api.host&.environments, log: api.host&.log)
          api.register_tool(Tools::Bind, serves: :runner)
        end
        api.register_command("env", usage: "env [DIR]",
          description: "Show where this machine's tools are pointed, or point them somewhere",
          options: { clear: { type: :boolean, default: false,
                              desc: "Fall back to settings.json rather than a directory set here" } },
          &Commands.method(:env))
        api.register_command("runner",
          description: "Report what this machine can do, and what failed to load",
          &Commands.method(:runner))
      end

      module Routes
        class << self
          # `root` is where relative paths land; the rest is discovered from
          # it and absent when it cannot be — no checkout, no branch.
          def document(selection)
            # Unset is an honest answer: a daemon nobody has connected has
            # no identity work root to fall back to.
            return { environment: { source: "unset" } } if selection.root.nil?

            environment = Rho::Runner::Environment.local(root: selection.root)
            { environment: {
              root: environment.root,
              source: selection.source,
              branch: environment.branch,
              worktree: environment.worktree,
              platform: environment.platform,
            }.compact }
          end

          # `{"root": null}` clears back to the settings file, so a UI offers
          # "reset" without a second verb; the check and the rebuild of
          # placement zero are `repoint_tools`'.
          def set(request, ctx)
            body = ControlServer.json_body(request)
            clearing = body.key?("root") && body["root"].nil?
            selection = ctx.repoint_tools(clearing ? nil : body["root"].to_s)
            return selection if selection in Rho::Daemon::Refusal

            [200, document(selection)]
          end

          # "What can this machine do" is one question, and why a task parked
          # is the same one: the extensions and their failures ride the
          # runner address's snapshot beside the tools that loaded; the
          # agent address's own loop stands beside it (`agent`), and a slot
          # not placed answers nil.
          def runner(ctx)
            snapshots = ctx.runner_snapshot
            runner = snapshots.fetch(:runner)
            unless runner.nil?
              runner = runner.merge(
                extensions: ctx.inventory,
                extension_failures: ctx.failures.map do |failure|
                  { source: failure.source, error: failure.error_class, detail: failure.message }
                end
              )
            end
            { runner: runner, agent: snapshots.fetch(:agent) }
          end

          # ---- the conversation's environment ----

          # THE RECORD READ: the memo refreshed (`fetch`, else `list`, else
          # the walk), answered with the row's version and stamp, whether
          # this host can place it, and what the row's runner elsewhere was
          # last told. A row this daemon does not follow is 404.
          def conversation(request, ctx)
            public_id = ControlServer.query(request)["public_id"].to_s
            return Rho::Daemon::Refusal.malformed("public_id is required") if public_id.empty?

            ctx.member_plane(host_public_id: public_id) do |client, workspace_public_id|
              binding = ctx.host_binding(public_id)
              next Rho::Daemon::Refusal.not_followed(public_id, lane: :host, hint: "attach it first") if binding.nil?

              plane = MemberPlane.new(client: client, workspace_public_id: workspace_public_id)
              read = ctx.environments.read(public_id, plane: plane)
              [200, { environment: describe(ctx, public_id, binding, read, relayed: relayed_of(ctx, public_id, binding)) }]
            end
          end

          # THE BIND: `{public_id, root?, directories?, fs?, mcp?}` — ABSENT
          # = keep, `null`/`[]` = clear; `root`/`directories` validated (every
          # member a directory, none under a protected root) → the store's
          # read-compare-write with `anchor: public_id` → the memo → the
          # relay when the row's runner is not this machine's own; `fs:
          # {url, token, read, write, client}` →
          # the ports table under the record's anchor, `null` drops it;
          # `mcp: [...]` → the editor's servers under
          # the record's anchor on the AGENT slot, `[]` closes them.
          # 404 `not_followed`; 422 `not_a_directory`/`protected_root`/
          # `environment_unbound` (a port routes on a root set and a server
          # set is keyed by one: none, neither)/`mcp_unavailable` (no
          # registrar loaded); 409 `environment_contended`/`runner_elsewhere`
          # (the port is this daemon's loopback endpoint; a runner elsewhere
          # cannot reach it — the servers still land: they run
          # on the agent slot, which is here whatever the runner); the
          # kernel's own bounds as themselves.
          def bind(request, ctx)
            body = ControlServer.json_body(request)
            public_id = body["public_id"].to_s
            return Rho::Daemon::Refusal.malformed("public_id is required") if public_id.empty?

            fs = body.key?("fs") ? Port.validate(body["fs"]) : nil
            return fs if fs in Rho::Daemon::Refusal
            mcp = body.key?("mcp") ? Servers.validate(body["mcp"]) : nil
            return mcp if mcp in Rho::Daemon::Refusal

            ctx.member_plane(host_public_id: public_id) do |client, workspace_public_id|
              binding = ctx.host_binding(public_id)
              next Rho::Daemon::Refusal.not_followed(public_id, lane: :host, hint: "attach it first") if binding.nil?

              plane = MemberPlane.new(client: client, workspace_public_id: workspace_public_id)
              answer = write(ctx, public_id, body, plane, local: binding[:runner].nil? || ctx.own_runner?(binding[:runner]))
              next answer if answer in Rho::Daemon::Refusal

              relayed = nil
              if answer.binding && binding[:runner] && !ctx.own_runner?(binding[:runner])
                relayed = ctx.environments.assert_remote(public_id, binding[:runner], answer.binding, plane: plane)
              end
              if body.key?("fs")
                refused = Port.register(ctx, public_id, binding, answer, fs)
                next refused if refused
              end
              if body.key?("mcp")
                refused = Servers.bind(ctx, public_id, answer, mcp)
                next refused if refused
              end
              [200, { environment: describe(ctx, public_id, binding, answer, relayed: relayed&.to_h) }]
            end
          end

          # THE LIVE TABLE: every followed conversation's memo row — host
          # mode alone (a runner-mode rho holds no member plane, and says so).
          def environments(ctx)
            ctx.member_plane do |*|
              hosts = ctx.host_bindings.map { |binding| binding.fetch(:host) }.select(&:outlives_turn?)
              [200, { environments: ctx.environments.listing(hosts) }]
            end
          end

          private

            # The three shapes a body names: a null root clears the record;
            # a named root set (the root, or the kept one, and the
            # directories named or kept) is bound; nothing named reads.
            # `local`: the row's runner is this host's (or none), so the
            # set is this host's to stat; a runner elsewhere places it.
            def write(ctx, public_id, body, plane, local:)
              return ctx.environments.clear(public_id, plane: plane) if body.key?("root") && body["root"].nil?

              current = ctx.environments.read(public_id, plane: plane)
              root = body.key?("root") ? body["root"] : current.root
              directories = body.key?("directories") ? (body["directories"].nil? ? [] : body["directories"]) : current.directories
              return current unless body.key?("root") || body.key?("directories")
              if root.nil?
                return Rho::Daemon::Refusal.malformed("root is required: #{public_id} has no environment record to keep")
              end

              refusal = ctx.environments.validate(root, directories, local: local)
              return refusal if refusal

              ctx.environments.bind(public_id, root: root, directories: directories, plane: plane)
            end

            # `resolved` is this host's placement of the record: a root set
            # every member of which can be placed here, `refused` for one
            # under a protected root, false for one absent; the default is
            # always placed.
            def describe(ctx, public_id, binding, read, relayed:)
              environments = ctx.environments
              root = read.root || ctx.environment.root
              resolved =
                if read.binding.nil? then true
                elsif [read.root, *read.directories].any? { |path| environments.refusal_for(path) == "protected_root" } then "refused"
                else environments.resolved?(read.binding)
                end
              { root: root, directories: read.directories, anchor: read.anchor, source: read.source,
                lock_version: read.lock_version, updated_at: read.updated_at, resolved: resolved,
                relayed: relayed, runner: binding[:runner], conversation: public_id,
                fs: environments.port_description(read.anchor), mcp: environments.servers_report(read.anchor) }
            end

            def relayed_of(ctx, public_id, binding)
              runner = binding[:runner]
              return nil if runner.nil? || ctx.own_runner?(runner)

              assertion = ctx.environments.asserted(public_id, runner)
              assertion && { runner: runner, state: assertion.state, booted_at: assertion.booted_at, resolved: assertion.resolved }
            end
        end
      end

      # THE DOOR'S `fs:` MEMBER: the
      # surface's loopback endpoint and bearer, the two flags the client
      # advertised, the client's name — validated as a shape (a loopback
      # http URL, a token, boolean flags, a name), registered under the
      # record's anchor on a row this machine's own runner serves.
      module Port
        LOOPBACK_HOSTS = %w[127.0.0.1 localhost ::1].freeze

        class << self
          # The validated fields, or the refusal; `nil` for the typed null.
          def validate(fs)
            return nil if fs.nil?
            return Rho::Daemon::Refusal.malformed("fs must be an object {url, token, read, write, client}, or null") unless fs.is_a?(Hash)
            return Rho::Daemon::Refusal.malformed("fs.url must be a loopback http URL") unless loopback?(fs["url"])
            return Rho::Daemon::Refusal.malformed("fs.token is required") unless fs["token"].is_a?(String) && !fs["token"].empty?
            return Rho::Daemon::Refusal.malformed("fs.client must name the client") unless
              fs["client"].is_a?(String) && !fs["client"].empty?
            return Rho::Daemon::Refusal.malformed("fs.read and fs.write must be booleans") unless
              %w[read write].all? { |flag| [true, false, nil].include?(fs[flag]) }

            { url: fs["url"], token: fs["token"], read: fs["read"] == true, write: fs["write"] == true, client: fs["client"] }
          end

          # Registers under the record's anchor, or drops on the null;
          # answers a refusal, else nil.
          def register(ctx, public_id, binding, answer, fs)
            anchor = answer.anchor
            if fs.nil?
              ctx.environments.drop_port(anchor || public_id, reason: "cleared")
              return nil
            end
            if binding[:runner] && !ctx.own_runner?(binding[:runner])
              return Rho::Daemon::Refusal.new(status: 409, code: "runner_elsewhere",
                message: "#{public_id} runs on #{binding[:runner]}: a port is this daemon's loopback endpoint")
            end
            if anchor.nil?
              return Rho::Daemon::Refusal.new(status: 422, code: "environment_unbound",
                message: "#{public_id} has no root set: a port routes on one; bind a root first")
            end

            ctx.environments.register_port(anchor, **fs)
            nil
          end

          private

            def loopback?(url)
              return false unless url.is_a?(String)

              uri = URI.parse(url)
              uri.scheme == "http" && LOOPBACK_HOSTS.include?(uri.hostname.to_s) && !uri.port.nil?
            rescue URI::InvalidURIError
              false
            end
        end
      end

      # THE DOOR'S `mcp:` MEMBER: the editor's
      # `mcpServers` list in the ACP shape, exactly as received — a list of
      # server objects, `[]` the typed close — bound under the record's
      # anchor through the daemon's servers table; the registrar judges
      # each entry (its ArgumentError is the 400), the table judges the
      # names. A set that moved re-announces the agent slot (the table's
      # edge) and re-declares the union HERE, synchronously, so the next
      # turn on this daemon is offered the new names (the digest gate makes an unmoved union a no-op).
      module Servers
        class << self
          # The list as received, or the refusal.
          def validate(mcp)
            return Rho::Daemon::Refusal.malformed("mcp must be a list of server objects, or [] to close them") unless
              mcp.is_a?(Array) && mcp.all?(Hash)

            mcp
          end

          # Binds under the record's anchor, or closes on the empty list (a
          # conversation with no record closes under its own id, as `fs:
          # null` drops); answers a refusal, else nil.
          def bind(ctx, public_id, answer, mcp)
            anchor = answer.anchor
            if anchor.nil? && !mcp.empty?
              return Rho::Daemon::Refusal.new(status: 422, code: "environment_unbound",
                message: "#{public_id} has no root set: a server set is keyed by one; bind a root first")
            end

            servers = ctx.environments.servers
            before = servers.digest
            bound = ctx.environments.bind_servers(anchor || public_id, mcp)
            # The table's digest, not `bound.changed`: a list the registrar
            # refused (the 400 below) has already dropped the held set, and
            # the union must lose those names now.
            ctx.declare_union unless servers.digest == before
            bound if bound in Rho::Daemon::Refusal
          end
        end
      end

      module Commands
        class << self
          # `rho env [DIR] [--clear]`: the read and the move are the core's
          # two primitives (the ACP surface binds a session's cwd through the same doors); this verb is their lines.
          def env(cli, (directory), options)
            clear = options[:clear]
            return report_environment(cli, cli.core.environment) unless directory || clear

            report_environment(cli, cli.core.repoint_environment(clear ? nil : File.expand_path(directory)))
          end

          # An extension that did not load is a product fact, so it reads
          # here rather than in a log.
          def runner(cli, _args, _options)
            answer = cli.core.parse(cli.core.get(cli.core.require_daemon, "/runner"))
            document = answer.fetch("runner")
            agent = answer["agent"]
            if document.nil? && agent.nil?
              cli.out.puts "runner:    not started (no workspace adopted yet)"
              return nil
            end

            report_agent(cli, agent)
            if document.nil?
              cli.out.puts "runner:    not registered"
              return nil
            end

            cli.out.puts "tools:     #{Array(document["tools"]).sort.join(", ")}"
            cli.out.puts "claimed:   #{document["claimed"]}  swept: #{document["swept"]}  " \
                         "nudged: #{document["nudged"]}  canceled: #{document["canceled"]}  " \
                         "in flight: #{document["in_flight"]}"
            # What the kernel can address to this machine; none means the
            # announcement failed (the log says why) and every call parks
            # nowhere — it fails `tool_not_served`.
            announced = document["announced"]
            cli.out.puts "announced: #{announced.nil? ? "none (the announcement failed — see the log)" : announced}"
            report_extensions(cli, document)
            document
          end

          private

            # The agent address's own loop: what it announced, or nothing.
            def report_agent(cli, agent)
              if agent.nil?
                cli.out.puts "agent:     nothing"
              else
                cli.out.puts "agent:     #{Array(agent["tools"]).sort.join(", ")} (announced #{agent["announced"] || "none"})"
              end
            end

            # The `environment` document as the core answered it.
            def report_environment(cli, environment)
              root = environment["root"]
              cli.out.puts "tools:     #{root || "(nowhere yet — connect first, or set one)"}"
              cli.out.puts "source:    #{environment.fetch("source")}"
              cli.out.puts "branch:    #{environment["branch"]}" if environment["branch"]
              cli.out.puts "worktree:  linked" if environment["worktree"]
              environment
            end

            def report_extensions(cli, document)
              Array(document["extensions"]).each do |entry|
                tools = Array(entry["tools"]).map { |tool| tool.fetch("name") }
                cli.out.puts "extension: #{entry.fetch("name")} (#{tools.join(", ")})"
              end
              Array(document["extension_failures"]).each do |failure|
                cli.out.puts "FAILED:    #{failure.fetch("source")} — #{failure.fetch("detail")}"
              end
            end
        end
      end
    end
  end
end

require_relative "environment/bind"
require_relative "environment/fs_port"
