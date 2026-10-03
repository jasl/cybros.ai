require "rho/runner"

module Rho
  module Extensions
    # Refuses the handful of effects no snapshot can undo (`rm -rf /`, a
    # force push, `curl | sh`…) as DATA the model reads. Denylist-only, no
    # permission algebra; not path confinement.
    # THE RUNNER FLOOR: a loop ANOTHER profile answers — a published definition spawned by
    # another install, any cross-install peer spawn — runs on this runner under ITS OWN
    # declaration's rules, so this install's incubation denies carry nothing there. The same
    # roots the denies ride (`Rho.protected_roots`, the ONE list: the program roots and the
    # home's enumerated members, never the work root) and the same two shapes: `write|edit`
    # whose `path` resolves under a root, `bash|start_process` whose `command` names one —
    # vetoed on EVERY task this runner serves, with the incubation reason. Whatever the
    # denies do not exempt, the floor does not either: a path resolving under the home's
    # work root meets no root and passes; the members around it are refused. A handle with
    # no home protects the program roots alone.
    module Guard
      NAME = "rho.guard".freeze

      # A pattern over the whole command, and the reason the model reads.
      # Deliberately literal about the dangerous spelling: a model that
      # reformulates around one has decided to, which is not a typo.
      RULES = [
        [/\brm\s+(-[a-zA-Z]*r[a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*r)\b[^|;&]*\s(\/|~|\$HOME|\/\*)(\s|$)/,
         "recursive delete of a root directory"],
        [/\bgit\s+push\b[^|;&]*(--force\b|--force-with-lease\b|\s-f\b)/,
         "force push rewrites history others may hold; a person can run it"],
        [/\b(curl|wget)\b[^|;&]*\|\s*(sudo\s+)?(ba|z|da)?sh\b/,
         "piping a download into a shell runs code nobody has read"],
        [/(^|[;&|]\s*)sudo\b/, "elevation is not available to an unattended loop"],
        [/\bmkfs(\.\w+)?\b/, "formatting a filesystem"],
        [/\bdd\b[^|;&]*\bof=\/dev\//, "writing raw bytes to a device"],
        [/\b(shutdown|reboot|halt|poweroff)\b/, "powering the machine off"],
        [/:\(\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:/, "a fork bomb"],
        [/\bchmod\s+(-R\s+)?[0-7]*777\s+\/(\s|$)/, "opening the root filesystem to everyone"],
      ].freeze

      # The two tools that run a command. Same key, same rules: a server
      # started with `rm -rf /` in front of it is still `rm -rf /`.
      GUARDED_TOOLS = %w[bash start_process].freeze
      # The two tools that write a file by `path` (`LoopRequest::EDIT_TOOLS`
      # is the rule grammar's spelling of the same fact).
      EDIT_TOOLS = %w[write edit].freeze

      def self.register(api)
        home = api.host&.home
        api.on(:tool_call) do |name, arguments|
          reason = refusal(name, arguments, home)
          reason && Rho::Runner::Extensions::Hooks::Veto.new(extension: NAME, reason: reason)
        end
      end

      # The command rules, then the floor — one answer per call, nil for
      # a call the guard has no opinion on: a command by the text naming
      # a root, a path by resolving under one.
      def self.refusal(name, arguments, home)
        if GUARDED_TOOLS.include?(name)
          command = arguments["command"].to_s
          refusal_for(command) ||
            floor_refusal(name, command, Rho.protected_roots(home)) { |root| command.include?(root) }
        elsif EDIT_TOOLS.include?(name)
          path = arguments["path"].to_s
          resolved = resolve(path)
          return nil if resolved.nil?

          floor_refusal(name, path, Rho.protected_roots(home)) { |root| Rho.under?(resolved, root) }
        end
      end

      # THE RESOLVED SPELLING: an
      # absolute or `~` spelling as it stands; a relative one through the
      # CONTEXT's placement env — the conversation's root, bound on the
      # worker before the chain runs — so `..` out of a bound root into a
      # protected one is judged; with no context (a probe) a relative path
      # is the runner's to resolve, as the denies' raw-input rule mirrors.
      # The kernel's deny rules keep judging the raw input.
      def self.resolve(path)
        return Rho.spelled(path) if absolute?(path)

        env = Rho::Runner::ExecutionContext.current&.tool_env
        env && Rho.spelled(env.resolve(path))
      end

      def self.absolute?(path) = path.start_with?("/", "~")

      def self.refusal_for(command)
        RULES.each do |pattern, reason|
          return "#{reason} (refused: #{excerpt(command)})" if command.match?(pattern)
        end
        nil
      end

      # THE FLOOR'S SENTENCE: which tool, under which root, the incubation
      # reason, and the offending text — data the model reads.
      def self.floor_refusal(name, text, roots)
        root = roots.find { |candidate| yield(candidate) }
        root && "#{name} under #{root} is refused: #{Rho::LoopRequest::INCUBATION} (refused: #{excerpt(text)})"
      end

      def self.excerpt(command)
        line = command.lines.find { |l| RULES.any? { |pattern, _| l.match?(pattern) } } || command
        line.strip.byteslice(0, 120).scrub("")
      end
    end
  end
end
