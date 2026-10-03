module Rho
  class Runner
    module Tools
      # Ported from pi's edit.ts + edit-diff.ts: exact text replacement with
      # a fuzzy-normalization ladder. Every edits[].oldText is matched
      # against the ORIGINAL file (never incrementally); matching tries exact
      # String#index first, then falls back to a fuzzy-normalized space
      # (NFKC, per-line trailing-whitespace strip, smart quotes/dashes/
      # spaces to ASCII). If any edit needed fuzzy, the whole operation runs
      # in fuzzy space and only the touched line ranges are overlaid back
      # onto the original lines, so untouched lines keep their original
      # bytes. Uniqueness is always checked by occurrence count in fuzzy
      # space, even when the exact match succeeded. A leading UTF-8 BOM and
      # the file's CRLF/LF line-ending style are preserved across the write.
      #
      # DELIBERATE DEVIATION: pi's display diff and unified patch
      # (details.diff/patch built with the diff library) are TUI render
      # sugar and are not ported — the UI owns rendering. rho
      # returns the replacement count plus the first changed line instead.
      #
      # THE SHAPE IS pi's `edits[].oldText/newText` ARRAY. The two references with text-replacement edits agree
      # on ONE pair — claude-code `old_string`/`new_string`/`replace_all`,
      # opencode `oldString`/`newString`(+`replaceAll`) — and ours differs
      # on purpose: several disjoint edits to one file land in ONE call
      # (one round, one lock, one write), each matched against the
      # ORIGINAL so no edit's offsets depend on another's; `replace_all`
      # is absent because uniqueness is the rule (a duplicate is an error
      # naming the count). The shape is model-facing and load-bearing, so
      # it is not re-worded by hand: `{path, old_string, new_string,
      # replace_all}` against `edits[]` is benched in the paid window on
      # the pack's style axis, and the winner is kept then. The schema
      # layer refuses a non-array before the handler, so `edits` is read
      # as declared.
      class Edit
        NAME = "edit"
        # Mutates file content in place.
        EFFECT_PROFILE = {
          "kind" => "write", "destructive" => true, "world" => "closed",
          "idempotency" => "none", "reconciliation" => "none",
        }.freeze

        SCHEMA = Ractor.make_shareable({
          "type" => "object",
          "properties" => {
            "path" => { "type" => "string", "description" => "Path to the file to edit (relative or absolute)" },
            "edits" => {
              "type" => "array",
              "description" =>
                "One or more targeted replacements. Each edit is matched against the original file, " \
                "not incrementally. Do not include overlapping or nested edits. If two changes touch " \
                "the same block or nearby lines, merge them into one edit instead.",
              "items" => {
                "type" => "object",
                "properties" => {
                  "oldText" => {
                    "type" => "string",
                    "description" =>
                      "Exact text for one targeted replacement. It must be unique in the original file " \
                      "and must not overlap with any other edits[].oldText in the same call.",
                  },
                  "newText" => { "type" => "string", "description" => "Replacement text for this targeted edit." },
                },
                "required" => ["oldText", "newText"],
              },
            },
          },
          "required" => ["path", "edits"],
        })

        DESCRIPTION =
          "Edit a single file using exact text replacement. Every edits[].oldText must match a unique, " \
          "non-overlapping region of the original file. If two changes affect the same block or nearby " \
          "lines, merge them into one edit instead of emitting overlapping edits. Do not include large " \
          "unchanged regions just to connect distant changes.".freeze

        PROMPT_SNIPPET =
          "Make precise file edits with exact text replacement, including multiple disjoint edits in one call".freeze

        PROMPT_GUIDELINES = Ractor.make_shareable([
          "Use edit for precise changes (edits[].oldText must match exactly)",
          "When changing multiple separate locations in one file, use one edit call with multiple entries " \
          "in edits[] instead of multiple edit calls",
          "Each edits[].oldText is matched against the original file, not after earlier edits are applied. " \
          "Do not emit overlapping or nested edits. Merge nearby changes into one edit.",
          "Keep edits[].oldText as small as possible while still being unique in the file. Do not pad " \
          "with large unchanged regions.",
        ])

        INVALID_INPUT_MESSAGE = "Edit tool input is invalid. edits must contain at least one replacement.".freeze
        OUTSIDE_BASE_MESSAGE = "Replacement range is outside the base content.".freeze

        # Internal control flow only: every raise is rescued in #call and returned as an error
        # Result (failure is data).
        Failure = Class.new(StandardError)

        EditPair = Data.define(:old_text, :new_text)
        FuzzyMatch = Data.define(:found, :index, :match_length, :used_fuzzy_match)
        Replacement = Data.define(:edit_index, :match_index, :match_length, :new_text)

        # Exact character classes from pi's normalizeForFuzzyMatch (edit-diff.ts).
        SMART_SINGLE_QUOTES = /[‘-‛]/
        SMART_DOUBLE_QUOTES = /[“-‟]/
        # U+2010 hyphen .. U+2015 horizontal bar, U+2212 minus.
        FUZZY_DASHES = /[‐-―−]/
        # U+00A0 NBSP, U+2002-U+200A spaces, U+202F narrow NBSP, U+205F medium math space, U+3000 ideographic.
        FUZZY_SPACES = /[  -   　]/
        # JS String#trimEnd strips Unicode whitespace (incl. U+1680, U+2028/29,
        # U+FEFF) that Ruby's rstrip does not; replicate its set for parity.
        TRAILING_WHITESPACE = /[\s   -     　﻿]+\z/

        def initialize(env:)
          @env = env
        end

        def call(args)
          ExecutionContext.current&.raise_if_cancelled!
          edits = args.fetch("edits")
          return Result.error(INVALID_INPUT_MESSAGE) if edits.empty?

          path = args.fetch("path")
          resolved = @env.resolve(path)
          # THE PORT BRANCH: routed
          # only when BOTH flags are advertised — one consistent view per
          # call, else the disk for both halves. The pre-read is the buffer
          # whole (existence is the port's answer; the disk gates are skipped), the ladder is unchanged over the port's text, the
          # write-back goes through the port under the same lock; and an
          # edit NEVER falls to disk after the port was asked.
          port = FsPort.routed(@env, resolved, :read, :write)
          @env.mutation_queue.with_lock(resolved) { locked_edit(resolved, path, edits, port) }
        rescue Failure => e
          Result.error(e.message)
        end

        private

        def locked_edit(resolved, path, edits, port)
          ExecutionContext.current&.raise_if_cancelled!
          raw = port && read_port_content(port, resolved, path)
          port = nil if raw.nil?
          raw ||= read_raw_content(resolved, path)
          bom, text = strip_bom(raw)
          ending = detect_line_ending(text)
          normalized = normalize_to_lf(text)
          new_content = apply_edits(normalized, edits, path)
          changed_line = first_changed_line(normalized, new_content)
          serialized = bom + restore_line_endings(new_content, ending)

          ExecutionContext.current&.raise_if_cancelled!
          port ? write_port_content(port, resolved, serialized) : File.binwrite(resolved, serialized)
          Result.ok(
            "Successfully replaced #{edits.length} block(s) in #{path}.",
            {
              "replacements" => edits.length,
              "first_changed_line" => changed_line,
            }
          )
        end

        # The buffer whole (`{path}`), nil for `not_found` — the disk for
        # both halves; a refusal names the client; an `Unavailable` (the
        # port already dropped) is the error: nothing was written.
        def read_port_content(port, resolved, path)
          content = FsPort.ask(port) { port.read_text(resolved, line: nil, limit: nil) }.dup.force_encoding(Encoding::UTF_8)
          raise Failure, invalid_encoding_message(path) unless content.valid_encoding?

          content
        rescue FsPort::NotFound
          nil
        rescue FsPort::Refused, FsPort::BeyondEof => error
          raise Failure, "#{port.client}: #{error.message}"
        rescue FsPort::Unavailable
          raise Failure, "#{port.client} did not answer the read; nothing was written"
        end

        def write_port_content(port, resolved, serialized)
          FsPort.ask(port) { port.write_text(resolved, serialized) }
        rescue FsPort::NotFound, FsPort::Refused, FsPort::BeyondEof => error
          raise Failure, "#{port.client}: #{error.message}"
        rescue FsPort::Unavailable
          raise Failure, "#{port.client} did not confirm the write; nothing was written"
        end

        def read_raw_content(resolved, path)
          raise Failure, could_not_edit_message(path, "ENOENT") unless File.exist?(resolved)

          unless File.readable?(resolved) && File.writable?(resolved)
            raise Failure, could_not_edit_message(path, "EACCES")
          end

          content = File.binread(resolved).force_encoding(Encoding::UTF_8)
          raise Failure, invalid_encoding_message(path) unless content.valid_encoding?

          content
        rescue SystemCallError => e
          raise Failure, could_not_edit_message(path, e.class.name.split("::").last)
        end

        # -- edit-diff.ts port ------------------------------------------------

        # applyEditsToNormalizedContent: match all edits against the same
        # original content, apply in reverse index order for stable offsets.
        def apply_edits(content, edits, path)
          pairs = edits.map do |edit|
            EditPair.new(old_text: normalize_to_lf(edit["oldText"]), new_text: normalize_to_lf(edit["newText"]))
          end
          pairs.each_with_index do |pair, index|
            raise Failure, empty_old_text_message(path, index, pairs.length) if pair.old_text.empty?
          end

          used_fuzzy = pairs.any? do |pair|
            check_cancellation!
            fuzzy_find(content, pair.old_text).used_fuzzy_match
          end
          base = used_fuzzy ? normalize_for_fuzzy(content) : content

          replacements = match_all(base, pairs, path)
          check_overlaps(replacements, path)

          new_content =
            if used_fuzzy
              overlay_touched_lines(content, base, replacements)
            else
              apply_replacements(base, replacements)
            end
          raise Failure, no_change_message(path, pairs.length) if new_content == content

          new_content
        end

        # Returns replacements sorted by match index (stable, like JS sort).
        def match_all(base, pairs, path)
          matched = pairs.each_with_index.map do |pair, index|
            check_cancellation!
            match = fuzzy_find(base, pair.old_text)
            raise Failure, not_found_message(path, index, pairs.length) unless match.found

            occurrences = count_occurrences(base, pair.old_text)
            raise Failure, duplicate_message(path, index, pairs.length, occurrences) if occurrences > 1

            Replacement.new(
              edit_index: index, match_index: match.index, match_length: match.match_length,
              new_text: pair.new_text
            )
          end
          matched.sort_by.with_index do |replacement, order|
            [replacement.match_index, order]
          end
        end

        def check_overlaps(sorted_replacements, path)
          sorted_replacements.each_cons(2) do |previous, current|
            next if previous.match_index + previous.match_length <= current.match_index

            raise Failure,
                  "edits[#{previous.edit_index}] and edits[#{current.edit_index}] overlap in #{path}. " \
                  "Merge them into one edit or target disjoint regions."
          end
        end

        # fuzzyFindText: exact String#index first, then both sides normalized.
        # Cancellation granularity note (here and below): the worst-case
        # latency bound is one uninterruptible primitive over the whole
        # content (index / unicode_normalize / gsub); checks between or after
        # such primitives cannot tighten it, so only per-pair loop heads and
        # normalize's entry carry checks.
        def fuzzy_find(content, old_text)
          exact_index = content.index(old_text)
          if exact_index
            return FuzzyMatch.new(found: true, index: exact_index, match_length: old_text.length,
                                  used_fuzzy_match: false)
          end

          fuzzy_old_text = normalize_for_fuzzy(old_text)
          fuzzy_index = normalize_for_fuzzy(content).index(fuzzy_old_text)
          if fuzzy_index.nil?
            return FuzzyMatch.new(found: false, index: -1, match_length: 0, used_fuzzy_match: false)
          end

          FuzzyMatch.new(found: true, index: fuzzy_index, match_length: fuzzy_old_text.length, used_fuzzy_match: true)
        end

        # countOccurrences: always counted in fuzzy-normalized space.
        def count_occurrences(content, old_text)
          normalized_content = normalize_for_fuzzy(content)
          normalized_old_text = normalize_for_fuzzy(old_text)
          normalized_content.split(normalized_old_text, -1).length - 1
        end

        def normalize_for_fuzzy(text)
          check_cancellation!
          normalized = text.unicode_normalize(:nfkc)
          lines = normalized.split("\n", -1).map do |line|
            line.sub(TRAILING_WHITESPACE, "")
          end
          normalized = lines.join("\n")
          normalized = normalized.gsub(SMART_SINGLE_QUOTES, "'")
          normalized = normalized.gsub(SMART_DOUBLE_QUOTES, "\"")
          normalized = normalized.gsub(FUZZY_DASHES, "-")
          normalized.gsub(FUZZY_SPACES, " ")
        end

        # applyReplacements: reverse order keeps earlier match offsets stable.
        def apply_replacements(content, sorted_replacements, offset = 0)
          sorted_replacements.reverse_each.reduce(content) do |current, replacement|
            check_cancellation!
            index = replacement.match_index - offset
            current[0...index] + replacement.new_text + current[(index + replacement.match_length)..]
          end
        end

        # applyReplacementsPreservingUnchangedLines: widen each replacement to
        # the lines it touches, rewrite those from the normalized base, and
        # copy every other line back from the original so unchanged lines keep
        # their original bytes.
        def overlay_touched_lines(original, base, replacements)
          original_lines = split_lines_with_endings(original)
          spans = line_spans(base)
          if original_lines.length != spans.length
            raise Failure, "Cannot preserve unchanged lines because the base content has a different line count."
          end

          cursor = 0
          pieces = group_by_touched_lines(spans, replacements).map do |group|
            check_cancellation!
            prefix = original_lines[cursor...group[:start_line]].join
            group_start = spans[group[:start_line]].first
            group_end = spans[group[:end_line] - 1].last
            cursor = group[:end_line]
            prefix + apply_replacements(base[group_start...group_end], group[:replacements], group_start)
          end
          (pieces + [original_lines[cursor..].join]).join
        end

        def group_by_touched_lines(spans, replacements)
          sorted = replacements.sort_by(&:match_index)
          sorted.reduce([]) do |groups, replacement|
            start_line, end_line = replacement_line_range(spans, replacement)
            last = groups.last
            if last && start_line < last[:end_line]
              merged = {
                start_line: last[:start_line],
                end_line: [last[:end_line], end_line].max,
                replacements: last[:replacements] + [replacement],
              }
              groups[0...-1] + [merged]
            else
              groups + [{ start_line:, end_line:, replacements: [replacement] }]
            end
          end
        end

        # Returns [start_line, exclusive_end_line] of the lines a replacement touches.
        def replacement_line_range(spans, replacement)
          range_start = replacement.match_index
          range_end = replacement.match_index + replacement.match_length

          start_line = spans.index do |line_start, line_end|
            range_start >= line_start && range_start < line_end
          end
          raise Failure, OUTSIDE_BASE_MESSAGE if start_line.nil?

          end_line = start_line
          end_line += 1 while end_line < spans.length && spans[end_line].last < range_end
          raise Failure, OUTSIDE_BASE_MESSAGE if end_line >= spans.length

          [start_line, end_line + 1]
        end

        def split_lines_with_endings(content)
          content.each_line("\n").to_a
        end

        def line_spans(content)
          offset = 0
          split_lines_with_endings(content).map do |line|
            span = [offset, offset + line.length]
            offset += line.length
            span
          end
        end

        # -- encoding preservation --------------------------------------------

        def strip_bom(content)
          content.start_with?("﻿") ? ["﻿", content[1..]] : ["", content]
        end

        # CRLF iff the first "\r\n" occurs before the first bare "\n".
        def detect_line_ending(content)
          lf_index = content.index("\n")
          return "\n" if lf_index.nil?

          crlf_index = content.index("\r\n")
          return "\n" if crlf_index.nil?

          crlf_index < lf_index ? "\r\n" : "\n"
        end

        def normalize_to_lf(text)
          text.gsub("\r\n", "\n").gsub("\r", "\n")
        end

        def restore_line_endings(text, ending)
          ending == "\r\n" ? text.gsub("\n", "\r\n") : text
        end

        # 1-indexed first line (in the new content) that differs from the
        # base. Stands in for pi's diffLines-derived firstChangedLine.
        def first_changed_line(base, new_content)
          base_lines = base.split("\n", -1)
          new_lines = new_content.split("\n", -1)
          limit = [base_lines.length, new_lines.length].max
          index = (0...limit).find { |i| base_lines[i] != new_lines[i] }
          index && index + 1
        end

        def check_cancellation!
          ExecutionContext.current&.raise_if_cancelled!
        end

        # -- error message shapes (edit.ts / edit-diff.ts wording) ------------

        def could_not_edit_message(path, code)
          "Could not edit file: #{path}. Error code: #{code}."
        end

        def invalid_encoding_message(path)
          "Could not edit file: #{path}. File content must be valid UTF-8."
        end

        def not_found_message(path, index, total)
          if total == 1
            "Could not find the exact text in #{path}. " \
              "The old text must match exactly including all whitespace and newlines."
          else
            "Could not find edits[#{index}] in #{path}. " \
              "The oldText must match exactly including all whitespace and newlines."
          end
        end

        def duplicate_message(path, index, total, occurrences)
          if total == 1
            "Found #{occurrences} occurrences of the text in #{path}. The text must be unique. " \
              "Please provide more context to make it unique."
          else
            "Found #{occurrences} occurrences of edits[#{index}] in #{path}. Each oldText must be unique. " \
              "Please provide more context to make it unique."
          end
        end

        def empty_old_text_message(path, index, total)
          return "oldText must not be empty in #{path}." if total == 1

          "edits[#{index}].oldText must not be empty in #{path}."
        end

        def no_change_message(path, total)
          if total == 1
            "No changes made to #{path}. The replacement produced identical content. " \
              "This might indicate an issue with special characters or the text not existing as expected."
          else
            "No changes made to #{path}. The replacements produced identical content."
          end
        end
      end
    end
  end
end
