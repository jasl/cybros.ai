module Rho
  module Extensions
    module Environment
      module Tools
        # THE HIDDEN RUNNER TOOL: how a host ELSEWHERE tells this runner slot a conversation's
        # root set over the executor relay — a one-task standalone loop addressed to this
        # runner, the conversation id on the input (a request loop has no conversation of its
        # own), judged by this runner's own rules on the path. `world_restore`'s posture: served
        # on the runner address, `DESCRIPTION` nil (announced schema-less, offered to no model),
        # hidden by NAME from every declaration (`LoopRequest.undeclared`). AN HONEST PROFILE: a
        # runner-state write is a write in the kernel's vocabulary, so the capture hook exempts
        # it BY NAME (`Checkpoints::EXEMPT`, a string in rho-runner pinned from here) rather
        # than the profile lying; `intrinsic` idempotency is the kernel's word for a whole
        # replacement. No
        # `TIMEOUT_MS`: the row rides the announced park, so a runner back after a restart still
        # finds the row waiting.
        #
        # It reaches the daemon the settled way (`Todo::Write.bind`): the
        # daemon's environment tables as a late-bound member of
        # `Extensions::Host`, dereferenced when the tool runs; nil under a
        # loader with no daemon, which answers an error the relay's caller
        # reads.
        class Bind
          NAME = "environment_bind".freeze
          DESCRIPTION = nil
          SCHEMA = Ractor.make_shareable({
            "type" => "object",
            "properties" => {
              "conversation_public_id" => { "type" => "string", "minLength" => 1,
                                            "description" => "The conversation whose root set this is" },
              "root" => { "type" => "string", "minLength" => 1, "description" => "Where relative paths resolve" },
              "directories" => { "type" => "array", "items" => { "type" => "string", "minLength" => 1 },
                                 "description" => "The rest of the root set" },
              "anchor" => { "type" => "string", "description" => "The conversation whose live members this binding shares" },
            },
            "required" => %w[conversation_public_id root],
            "additionalProperties" => false,
          })
          EFFECT_PROFILE = {
            "kind" => "write", "destructive" => false, "world" => "closed",
            "idempotency" => "intrinsic", "reconciliation" => "none",
          }.freeze

          UNAVAILABLE = "environment_unavailable: this runner holds no environment tables (no daemon)".freeze

          class << self
            attr_reader :environments, :log

            # Bound at registration: a callable answering the daemon's
            # `Environments` (nil under a loader with no daemon) and its log.
            def bind(environments:, log:)
              @environments = environments
              @log = log
            end
          end

          def initialize(env:)
            @env = env
          end

          # Validates the root set as the host's door does — a protected
          # root is refused as data in every mode; an absent one applies
          # with `resolved: false` — writes the received table, and answers
          # `{applied, resolved, booted_at}`: the runner's process life, the
          # host's re-assertion key.
          def call(args)
            environments = self.class.environments&.call
            return Rho::Runner::Result.error(UNAVAILABLE) if environments.nil?

            conversation = args.fetch("conversation_public_id")
            binding = Rho::Runner::Environment::Binding.new(
              root: File.expand_path(args.fetch("root")),
              directories: Array(args["directories"]).map { |path| File.expand_path(path) },
              anchor: args["anchor"] || conversation
            )
            refused = [binding.root, *binding.directories].find { |path| environments.refusal_for(path) == "protected_root" }
            return Rho::Runner::Result.error("protected_root: #{refused} is under a protected root on this runner") if refused

            resolved = environments.receive(conversation, binding)
            structure = { "applied" => true, "resolved" => resolved, "booted_at" => environments.booted_at }
            Rho::Runner::Result.ok(sentence(binding, resolved), structure, title: "environment bound")
          end

          private

            def sentence(binding, resolved)
              extra = binding.directories.empty? ? "" : " (+ #{binding.directories.join(", ")})"
              return "environment bound to #{binding.root}#{extra}" if resolved

              "environment bound to #{binding.root}#{extra}; not a directory on this host, so relative paths resolve " \
                "against the runner's default root until it exists"
            end
        end
      end
    end
  end
end
