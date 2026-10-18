module Rho
  class Runner
    module Tools
      # THE LOAD OF A DOCUMENT THIS ADDRESS ANNOUNCED: the kernel routes a model's
      # `skill {name}` call to the executor that announced `name` under
      # `documents` — this runner for the checkout's `SKILL.md` files, the
      # agent address for an http MCP server's prompts — and this tool
      # answers the row with the document's BODY as the address's LOADERS
      # answer it: the plane's `Registry#load_document` walk, in
      # registration order, the first `Result` winning (Coding's loader
      # reads a skill's markdown under the frontmatter through `read`'s
      # window plus one line naming the base directory; rho-mcp's answers a
      # prompt's text or a resource's contents). The tool holds no reader
      # of its own — it is the plane's, the one tool built with a second
      # constructor argument (`Registry#tool_for`).
      #
      # Runner declarations expose this schema under a target-qualified callable.
      # The kernel's own skill callable continues to serve member/workspace memory.
      # A route freezes this Runner as the document source for the call.
      #
      # A name no loader holds — a skill deleted since the announcement, a
      # prompt the server no longer lists — answers the error
      # `skill_unknown: <name>`, the same envelope shape the kernel's own
      # branch produces for a name it holds no row for — never a stale
      # copy; the announcement catches up at the next `rho env` or boot.
      class Skill
        NAME = "skill".freeze
        DESCRIPTION = "Load a skill document from this Runner by its announced name.".freeze
        # A pure filesystem read: `Read`'s own profile.
        EFFECT_PROFILE = Read::EFFECT_PROFILE
        SCHEMA = Ractor.make_shareable({
          "type" => "object",
          "properties" => {
            "name" => { "type" => "string", "description" => "The skill name, as this runner announced it" },
          },
          "required" => ["name"],
        })

        # `loaders` is the address's loader walk — a callable `(name, env)
        # -> Result | nil` (`Registry#load_document`); nil under a tool built
        # outside the plane, which then holds no document at all.
        def initialize(env:, loaders: nil)
          @env = env
          @loaders = loaders
        end

        def call(args)
          ExecutionContext.current&.raise_if_cancelled!
          name = args.fetch("name").to_s
          result = @loaders&.call(name, @env)
          result.nil? ? Result.error("skill_unknown: #{name}") : result
        end
      end
    end
  end
end
