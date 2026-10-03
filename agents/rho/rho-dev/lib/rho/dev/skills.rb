module Rho
  module Dev
    # SKILLS FROM A TERMINAL: the
    # kernel rows on the two rungs a skill may take, through the two
    # memory doors that own them (the person's, the room's own) — `push`
    # is the one place the SKILL.md dialect lives on the agent side (the
    # runner's own parser), `show` the body, `rm` the row; the listing
    # prints the rungs, never the merge (the merge is the kernel's, read
    # as the seed's bytes by `rho request`).
    module Skills
      SKILLS_USAGE = "`rho skills`, `rho skills push DIR --scope user|workspace`, " \
                     "`rho skills show NAME --scope user|workspace`, `rho skills rm NAME --scope user|workspace`".freeze
      SKILL_SCOPES = %w[user workspace].freeze

      def self.register(api)
        api.register_command("skills",
          usage: "skills | skills push DIR | skills show NAME | skills rm NAME",
          description: "The skills the kernel holds for this person (user/) and this daemon's workspace " \
                       "(workspace/): name and description; push a SKILL.md directory to a rung, print " \
                       "one skill's body, or remove one",
          options: {
            scope: { type: :string, default: "user",
                     desc: "The rung a push, show or rm names: user (this person's, from any workspace) or " \
                           "workspace (the room's own rows)" },
          },
          &method(:skills))
      end

      class << self
        # The rows on the two rungs. Mutations first observe their version. `push` reads the
        # SKILL.md HERE, with the runner's own parser (the same module the
        # runner scans a checkout with) — the directory is on the person's
        # disk, and the split is the one place the frontmatter dialect
        # lives on this side.
        def skills(cli, (verb, *rest), options)
          case verb
          when nil then list_skills(cli, options)
          when "push" then push_skill(cli, rest.first, options)
          when "show" then show_skill(cli, rest.first, options)
          when "rm" then remove_skill(cli, rest.first, options)
          else raise Rho::Error, "skills takes push, show or rm: #{SKILLS_USAGE}"
          end
        end

        private

          # Three sections, `user/`, `workspace/`, then `project` — what
          # this daemon's runner announces from its root. NOT the merge:
          # the merge is the kernel's, read as the seed's bytes through
          # `rho request`.
          def list_skills(cli, _options)
            skills = cli.core.skills
            print_skill_section(cli, "user/", skills.fetch("user"))
            print_skill_section(cli, "workspace/", skills.fetch("workspace"))
            project = skills["project"]
            if project.nil?
              cli.out.puts "project (no root set; `rho env ROOT` points the runner at one)"
            else
              print_skill_section(cli, "project (announced by this runner)", project)
            end
            skills
          end

          def print_skill_section(cli, heading, rows)
            cli.out.puts heading
            cli.out.puts "  (none)" if rows.empty?
            rows.each { |row| cli.out.puts "  #{row.fetch("name")}: #{row.fetch("description")}" }
          end

          def push_skill(cli, dir, options)
            raise Rho::Error, "skills push needs DIR, a directory holding SKILL.md" if dir.to_s.empty?

            scope = skill_scope(options)
            skill = Rho::Runner::Skills.read(File.expand_path(dir))
            raise Rho::Error, "#{skill.path}: #{skill.reason}" if skill in Rho::Runner::Skills::Skipped

            # The command explicitly replaces the remote document with this
            # local file. Capture once before sending; a conflict is not retried.
            snapshot = skill_for_push(cli, skill.name, scope: scope)
            row = cli.core.push_skill(name: skill.name, description: skill.description, content: skill.body,
              scope: scope, expected_public_id: snapshot&.fetch("public_id"),
              expected_lock_version: snapshot&.fetch("lock_version"))
            cli.out.puts "pushed:    #{row.fetch("path")} (#{row.fetch("bytesize")} bytes)"
            row
          end

          def skill_for_push(cli, name, scope:)
            cli.core.show_skill(name, scope: scope)
          rescue Rho::Core::Refused => error
            raise unless error.code == "memory_not_found"

            nil
          end

          def show_skill(cli, name, options)
            raise Rho::Error, "skills show needs NAME" if name.to_s.empty?

            row = cli.core.show_skill(name, scope: skill_scope(options))
            cli.out.puts row.fetch("content")
            row
          end

          # Prints nothing after deleting the version observed at command start.
          def remove_skill(cli, name, options)
            raise Rho::Error, "skills rm needs NAME" if name.to_s.empty?

            scope = skill_scope(options)
            snapshot = cli.core.show_skill(name, scope: scope)
            cli.core.remove_skill(name, scope: scope, expected_public_id: snapshot.fetch("public_id"),
              expected_lock_version: snapshot.fetch("lock_version"))
          end

          # `--scope` (user by default): the rung a push, show or rm names.
          def skill_scope(options)
            scope = options.fetch(:scope, "user").to_s
            raise Rho::Error, "--scope must be user or workspace: #{SKILLS_USAGE}" unless SKILL_SCOPES.include?(scope)

            scope
          end
      end
    end
  end
end
