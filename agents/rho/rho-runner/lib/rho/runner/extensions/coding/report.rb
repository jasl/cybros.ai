module Rho
  class Runner
    module Extensions
      module Coding
        # WHAT THE SEVEN TOOLS OPERATE ON, said plainly.
        #
        # It states facts and asks for nothing. Every field is optional
        # because the environment is a statement rather than a boundary —
        # a model working on one project from inside another is doing an
        # ordinary thing, and nothing here or anywhere else refuses it.
        #
        # THE ONE FACT THAT ALWAYS APPEARS is where a bare relative path
        # lands, because without it a model cannot predict what
        # `read("a.rb")` opens — and until recently it could not find out
        # afterwards either, since the answer echoed the argument.
        module Report
          module_function

          def call(environment)
            lines = ["Relative paths resolve against #{environment.root}."]

            unless environment.root_is_working_directory?
              lines << "You are working in #{environment.working_directory}, which is NOT that " \
                       "directory — use absolute paths there, or pass workdir to bash."
            end
            unless environment.directories.empty?
              lines << "Additional directories: #{environment.directories.join(", ")}."
            end
            lines << "Git branch: #{environment.branch}." if environment.branch
            lines << "This is a linked git worktree." if environment.worktree
            lines << "Absolute paths anywhere on this machine work; nothing is confined."

            lines.join("\n")
          end
        end
      end
    end
  end
end
