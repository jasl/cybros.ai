module Rho
  # A REPOSITORY'S OWN RULES, AND THE PERSON'S, DELIVERED TO THE MODEL.
  # Every reference reads repo-resident instructions — AGENTS.md walking up
  # from where the work is to the root, and the nearest CLAUDE.md — because
  # a house rule the model never saw is a house rule it will break in its
  # first edit. This repository's own AGENTS.md forbids type probes in
  # every spelling; a loop that did not read it would add one. And every
  # reference reads ONE home-level file beside that walk (codex's
  # `~/.codex/AGENTS.md`, claude-code's `~/.claude/CLAUDE.md`, opencode's
  # `~/.config/opencode/AGENTS.md`): the person's standing rules for every
  # root this home works on. rho's is `$RHO_HOME/AGENTS.md` — the FARTHEST
  # section of the same block, the most general, the first the budget cuts.
  #
  # BYTE-BUDGETED, HONESTLY. The block sits in `instructions`, which is the
  # front of every cached prefix and is never compacted, so it cannot be
  # unbounded: 32 KiB total (codex's number), the nearest — the most
  # specific — paid for first so it is the one kept whole, and a
  # truncation notice that says which file was cut and by how much.
  #
  # STABLE ACROSS ROUNDS by construction: read once, at authoring, and
  # carried byte-identically by every continuation — the same discipline
  # the environment block already keeps.
  module Conventions
    FILENAMES = %w[AGENTS.md CLAUDE.md].freeze
    # The home's one file: the name rho reads first in every directory,
    # and one name only in a directory rho owns.
    HOME_FILENAME = "AGENTS.md".freeze
    BUDGET_BYTES = 32 * 1024
    MAX_DEPTH = 32

    Found = Data.define(:path, :text)

    module_function

    # The files, NEAREST FIRST: from `working_directory` up to and
    # including `root` (or the filesystem root when the two are
    # unrelated), then the home's — `<home>/AGENTS.md` when `home` (the
    # state root, `$RHO_HOME`) is given and the walk did not already pass
    # through it (a root under the home reads it once).
    def files(working_directory:, root:, home: nil)
      dirs = ancestors(working_directory, stop: root)
      walked = dirs.flat_map { |dir| FILENAMES.filter_map { |name| read(File.join(dir, name)) } }
      home_file = home && read(File.join(File.expand_path(home), HOME_FILENAME))
      return walked if home_file.nil? || walked.any? { |file| file.path == home_file.path }

      walked + [home_file]
    end

    # The file at `path` as a section, nil when it is not there or cannot
    # be read (a conventions file is never a reason a loop does not start).
    def read(path)
      return nil unless File.file?(path)

      Found.new(path: path, text: File.read(path, encoding: Encoding::UTF_8).scrub)
    rescue StandardError
      nil
    end

    # The block, or nil when there is nothing to say.
    def block(working_directory:, root:, home: nil, budget: BUDGET_BYTES)
      found = files(working_directory: working_directory, root: root, home: home)
      return nil if found.empty?

      sections = fit(found, budget)
      ["Repository conventions the operator asks you to follow, from the files below:", *sections].join("\n\n")
    end

    # THE NEAREST FILE IS PAID FOR FIRST, because it is the most specific
    # and the one that must survive whole; whatever budget remains goes to
    # the farther, more general ones, and the farthest is what gets cut.
    # The sections are then emitted general-first, nearest-last, which is
    # the order they read in.
    def fit(found, budget)
      room = budget
      found.map do |file|
        header = "--- #{file.path} ---\n"
        body = file.text.strip
        if header.bytesize + body.bytesize <= room
          room -= header.bytesize + body.bytesize
          header + body
        else
          # The notice's own width is reserved inside the room — measured
          # with the largest number it could carry — so the block never
          # overruns the budget it names.
          reserve = notice(body.bytesize, file, budget).bytesize
          keep = [room - header.bytesize - reserve, 0].max
          kept = body.byteslice(0, keep).scrub("")
          room = 0
          header + kept + notice(body.bytesize - kept.bytesize, file, budget)
        end
      end.reverse
    end

    def notice(omitted, file, budget)
      "\n[…#{omitted} more bytes of #{File.basename(file.path)} omitted: the conventions budget is #{budget} bytes]"
    end

    def ancestors(working_directory, stop:)
      dir = File.expand_path(working_directory.to_s)
      stop_at = stop && File.expand_path(stop)
      seen = []
      MAX_DEPTH.times do
        seen << dir
        break if dir == stop_at || dir == File.dirname(dir)

        dir = File.dirname(dir)
      end
      seen
    end
  end
end
