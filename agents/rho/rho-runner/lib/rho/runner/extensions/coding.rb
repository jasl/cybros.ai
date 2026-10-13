module Rho
  class Runner
    module Extensions
      # THE CODING TOOLS, AS AN EXTENSION — and the person's one beside them. This
      # is the dogfood rule the predecessor stated and `Toolset`'s comment
      # kept a placeholder for: the built-ins hold no privileged path into
      # the loop, because the door they come through is the door a third
      # party uses. A plane whose first consumer is somebody else's gem is
      # a plane nobody has tested.
      #
      # `files_bytes` is the runner's capability as a tool: the model's tools, then a file's bytes for a PERSON who asks
      # this runner through the call_tool — announced described to nobody.
      # `skill` is the runner's other undescribed name: the load the KERNEL addresses here for a skill this runner
      # announced under `documents` — the checkout's `SKILL.md` files, as
      # `Skills.scan` reads them — so the model's `skill` tool (the
      # kernel's, declared by the profile) reaches this runner's files.
      # The tool is the plane's; the READER is this extension's
      # (`load_document`): the body under the
      # frontmatter through `read`'s own window (never past the kernel's
      # result envelope; a truncated body carries `read`'s continuation
      # marker naming the file's own line offsets, so the model can `read`
      # the rest by path) plus one line naming the base directory,
      # opencode's, so relative paths in the instructions resolve. The root
      # is RE-SCANNED per load (two globs; cheaper than a cache that can go
      # stale): a skill deleted since the announcement is nobody's, and the
      # tool answers `skill_unknown`.
      #
      # It is a plain module answering `register(api)` — the entire
      # extension contract — so this file is also the worked example.
      module Coding
        NAME = "rho.coding".freeze

        TOOLS = [
          Tools::Read, Tools::Write, Tools::Edit,
          Tools::Bash, Tools::Grep, Tools::Find, Tools::Ls,
          Tools::FileImport, Tools::FilePublish, Tools::FilesBytes, Tools::Skill,
        ].freeze

        FILES_LINE = "Files for this skill are under %s; relative paths in the instructions are relative to it.".freeze
        WORKSPACE_TOOLS_PATH = "/usr/local/share/cybros/workspace-tools.md".freeze
        WORKSPACE_TOOLS_NAME = "workspace-tools".freeze
        WORKSPACE_TOOLS_DESCRIPTION = "Use the prepared coding runtimes, Office converters, Python document libraries, " \
                                      "fonts and browser tools in this workspace's environment.".freeze

        def self.register(api)
          TOOLS.each { |klass| api.register_tool(klass) }
          api.describe_environment { |environment| Report.call(environment) }
          api.describe_documents { |environment| documents(environment, log: api.log) }
          api.load_document { |name, env| load(name, env) }
        end

        # The installed guide is optional and follows the project's skills:
        # a checkout's own document wins a name in both discovery and loading.
        # Only the catalog line is announced; the body is read on demand.
        def self.documents(environment, log: nil, guide_path: WORKSPACE_TOOLS_PATH)
          documents = Skills.scan(root: environment.root, log: log).map do |skill|
            { "name" => skill.name, "description" => skill.description }
          end
          if File.file?(guide_path) && documents.none? { |row| row.fetch("name") == WORKSPACE_TOOLS_NAME }
            documents << { "name" => WORKSPACE_TOOLS_NAME, "description" => WORKSPACE_TOOLS_DESCRIPTION }
          end
          documents
        end

        # A project's skill takes precedence over the installed guide; a
        # name neither source holds returns nil (the tool's `skill_unknown`). THE
        # ANNOUNCED ROOT'S skills: a placement built
        # over a bound root carries `documents_root` — the default root
        # whose skills this runner announced — so what was announced loads
        # everywhere and a bound root's own `.agents/skills` is not seen.
        def self.load(name, env, guide_path: WORKSPACE_TOOLS_PATH)
          skill = Skills.scan(root: env.documents_root || env.root).find { |candidate| candidate.name == name }
          return load_workspace_tools(name, env, guide_path) if skill.nil?

          files_line = format(FILES_LINE, skill.dir)
          return Result.ok(files_line) if skill.body.empty?

          body = Tools::Read.new(env: env).call("path" => skill.path, "offset" => skill.body_line)
          return body if body.is_error

          Result.ok("#{body.content}\n\n#{files_line}", body.structured_content)
        end

        def self.load_workspace_tools(name, env, path)
          if name == WORKSPACE_TOOLS_NAME && File.file?(path)
            Tools::Read.new(env: env).call("path" => path)
          end
        end
        private_class_method :load_workspace_tools
      end
    end
  end
end
