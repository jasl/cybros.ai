module E2E
  module Evals
    module Claims
      # One naming of a file and the words that speak about it: `lead` (the words before it and the
      # files sharing its predicate), `predicates` (the words after them — one in a sentence; in a
      # table the rest of its cell and every other cell of its row or column beside its label),
      # `scope` (the heading or lead-in its line sits under, nil when none), `bare` (a prose line,
      # where a naming with no words around it answers the question), `clause` (the text it came
      # from, for the reason), `later` (the clauses after it on its line that name no file but
      # speak of the last files named — "It also defines `run`.", "`run` as well." — empty when
      # none follow and in a table) and `before` (the whole clause before it, earlier files and
      # their predicates included — "bravo won over " before "alpha"; empty in a table).
      Naming = Data.define(:file, :lead, :predicates, :scope, :bare, :clause, :later, :before)

      # THE NAMINGS OF A REPLY, line by line: fenced code is dropped (a file's source is no claim),
      # a table is read by rows and columns, a `#` heading scopes the list items and table rows
      # under it to the next heading (a sentence under it has words of its own), a line ending in
      # ":" scopes the list items under it, and a prose line is cut into clauses.
      # Inside a clause, files joined by "and", "or", "nor" or a comma share one predicate; the words
      # between two predicates split at their last clause boundary — the part before it says
      # something about the earlier files, the part after it leads the later ones ("…defines `run`,
      # and so does bravo.rb").
      class Namings
        ITEM = /\A\s*(?:[-*+•]|\d+[.)])\s+/
        HEADING = /\A\s*#+\s+/
        TABLE = /\A\s*\|/
        FENCE = /\A\s*(?:```|~~~)/
        RULE = /\A:?-+:?\z/
        CLAUSE = /(?<=[.!?])\s+|;\s*/
        BOUNDARY = /,|;|:|\s[—–-]\s|\s(?:and|but|while|whereas)\s/i
        CONNECTOR = /\A[\s,`*_'"\/&]*(?:\b(?:and|or|nor)\b[\s`*_'"]*)?\z/i
        # A clause that names no file yet speaks of the last ones named opens on a pronoun or an
        # "also" ("It also defines `run`.", "Also `run`.").
        ANAPHOR = /\A[\s*_`'"]*(?:it|they|both|each|this|that|the\s+same|also|plus)\b/i

        # The reply's lines outside fenced code, the fences with them.
        def self.lines(reply)
          code = false
          reply.lines(chomp: true).reject do |line|
            fence = FENCE.match?(line)
            code = !code if fence
            fence || code
          end
        end

        def self.clauses(reply) = lines(reply).flat_map { |line| line.split(CLAUSE) }

        def initialize(question)
          @question = question
          @pattern = Regexp.union(question.files.map { |file| %r{(?<![\w.-])(?:[\w.-]+/)*#{Regexp.escape(file)}\b}i })
        end

        def call(reply)
          lead_in = nil
          heading = nil
          blocks(self.class.lines(reply)).flat_map do |block|
            line = block.first
            if TABLE.match?(line)
              table(block, lead_in || heading)
            elsif HEADING.match?(line)
              heading = line
              lead_in = nil
              prose(line, nil, bare: false)
            elsif ITEM.match?(line)
              found = prose(line.sub(ITEM, ""), lead_in || heading, bare: false)
              lead_in = line if lead_in?(line)
              found
            elsif line.strip.empty?
              []
            else
              lead_in = lead_in?(line) ? line : nil
              prose(line, nil, bare: true)
            end
          end
        end

        private

        # Consecutive table rows are one block; every other line is its own.
        def blocks(lines) = lines.slice_when { |a, b| !(TABLE.match?(a) && TABLE.match?(b)) }.to_a

        def lead_in?(line) = line.strip.sub(/[*_`\s]+\z/, "").end_with?(":")

        def prose(line, scope, bare:)
          clauses = line.split(CLAUSE)
          clauses.each_with_index.flat_map do |clause, index|
            later = clauses.drop(index + 1).take_while { |following| !@pattern.match?(following) && anaphoric?(following) }
            clause_namings(clause, scope, bare, later)
          end
        end

        # An anaphor, or the token with nothing else but an "as well" ("`run` as well.").
        def anaphoric?(clause) = ANAPHOR.match?(clause) || ELLIPSIS.match?(Claims.words(clause.gsub(@question.token_pattern, " ")))

        # The later clauses speak of the clause's last files, the ones nearest them.
        def clause_namings(clause, scope, bare, later)
          hits = clause.to_enum(:scan, @pattern).map { Regexp.last_match }
          groups = hits.slice_when { |a, b| !CONNECTOR.match?(clause[a.end(0)...b.begin(0)]) }.to_a
          groups.each_with_index.flat_map do |group, index|
            lead = index.zero? ? clause[0...group.first.begin(0)] : forward(clause[groups[index - 1].last.end(0)...group.first.begin(0)])
            following = groups[index + 1]
            tail = clause[group.last.end(0)...(following ? following.first.begin(0) : clause.size)]
            predicate = following ? backward(tail) : tail
            group.map do |hit|
              Naming.new(file: file_of(hit[0]), lead: lead, predicates: [predicate], scope: scope, bare: bare, clause: clause,
                later: following ? [] : later, before: clause[0...group.first.begin(0)])
            end
          end
        end

        def forward(segment)
          cut = last_boundary(segment)
          cut ? segment[cut.end(0)..] : ""
        end

        def backward(segment)
          cut = last_boundary(segment)
          cut ? segment[0...cut.begin(0)] : segment
        end

        def last_boundary(segment) = segment.to_enum(:scan, BOUNDARY).map { Regexp.last_match }.last

        # A cell is read with every other cell of its row, each beside its column's header; a file
        # named in the header (a transposed table) is read down its column, beside each row's label.
        def table(rows, scope)
          cells = rows.map { |row| row.strip.delete_prefix("|").delete_suffix("|").split("|").map(&:strip) }
          ruled = cells.index { |row| row.all? { |cell| RULE.match?(cell) } }
          header = ruled ? cells[ruled - 1] : nil
          body = cells.reject.with_index { |_row, index| ruled && index <= ruled }
          cells.each_with_index.flat_map do |row, index|
            row.each_with_index.flat_map do |cell, column|
              beside = header && index < ruled ? down(body, column) : across(row, header, column)
              cell.scan(@pattern).map do |name|
                Naming.new(file: file_of(name), lead: "", predicates: [cell.sub(name, " "), *beside], scope: scope, bare: false,
                  clause: rows[index], later: [], before: "")
              end
            end
          end
        end

        def across(row, header, column)
          row.each_index.reject { |other| other == column }.map { |other| "#{row[other]} #{header&.dig(other)}".delete("?") }
        end

        def down(body, column) = body.map { |row| "#{row[column]} #{row[0]}".delete("?") }

        def file_of(name) = @question.files.find { |file| name.casecmp?(file) || name.downcase.end_with?("/#{file.downcase}") }
      end
    end
  end
end
