module Rho
  module Extensions
    module Handoff
      # THE TREE-SYNC WARNING (borrowed from Claude Code's teleport checkout check). A handoff replays nothing and moves no
      # tree — the transcript is in Nexus, the code moves by git — so the
      # verb compares the OLD binding's and the NEW target's announced
      # environment (root, branch, worktree) and
      # says in ONE line exactly which differ. Display only, never a
      # refusal: nothing when they match, and nothing a side cannot say —
      # an unknown runner, or a field it never announced.
      module TreeSync
        FIELDS = %w[branch root worktree].freeze
        SUFFIX = " — the tree is not synced".freeze

        class << self
          # `old` and `new` are discovery documents (or nil for unknown).
          def warning(old:, new:)
            return nil if old.nil? || new.nil?

            differing = FIELDS.select { |field| differs?(old.environment, new.environment, field) }
            return nil if differing.empty?

            "#{side("old", old, differing)}, #{side("new", new, differing)}#{SUFFIX}"
          end

          private

            # A field one side never announced is unknown, not different.
            def differs?(theirs, ours, field)
              return false if theirs[field].nil? || ours[field].nil?

              theirs[field] != ours[field]
            end

            def side(label, document, fields)
              "#{label} runner #{document.public_id}" +
                fields.map { |field| phrase(field, document.environment[field]) }.join
            end

            def phrase(field, value)
              case field
              when "branch" then " on branch #{value}"
              when "root" then " at #{value}"
              else value ? " in a linked worktree" : " in the main worktree"
              end
            end
        end
      end
    end
  end
end
