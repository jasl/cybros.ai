module Rho
  class Runner
    module Tools
      # A FILE'S BYTES, FOR A PERSON — the runner capability behind the
      # executor call_tool: a member asks this runner
      # for a file it holds, and the answer is ALWAYS A CAPTURE. The tool
      # names the file with its size and type and hands the path to the
      # run (`files:`), which uploads it on the executor plane and links it
      # in the commit; the person reads the bytes — whole, or a `Range` of
      # them — on the one member-plane bytes read. No inline bytes and no
      # `{offset, limit}` vocabulary of its own: a screenshot and a source
      # file take one path, and `result_too_large` is never in play.
      #
      # DESCRIBED TO NOBODY. `DESCRIPTION` is nil on purpose: the tool is
      # ANNOUNCED without a description or a schema (`Registry::Entry#
      # undescribed?`), so no agent that reads this runner through discovery
      # can author a declaration from it, and rho hides the name from every
      # model on its side besides. A model has `read`; this is the person's.
      # The `SCHEMA` still stands — it is what the run validates a call
      # against before the handler sees it.
      #
      # Resolves the path as `ToolEnv#resolve` does: no confinement (the
      # product, `tool_env.rb`); a missing file is an error the caller reads.
      class FilesBytes
        NAME = "files_bytes".freeze
        DESCRIPTION = nil
        # Pure filesystem read: `Read`'s own profile.
        EFFECT_PROFILE = Read::EFFECT_PROFILE
        SCHEMA = Ractor.make_shareable({
          "type" => "object",
          "properties" => {
            "path" => { "type" => "string", "description" => "Path to the file, absolute or relative to the root" },
          },
          "required" => ["path"],
        })

        def initialize(env:)
          @env = env
        end

        def call(args)
          ExecutionContext.current&.raise_if_cancelled!
          located = Files.locate(root: @env.root, path: args.fetch("path"))
          return Result.error(located.message) if located.is_a?(Files::Refusal)

          Result.ok("#{located.path} (#{located.type}, #{located.size} bytes)", files: [located.path])
        end
      end
    end
  end
end
