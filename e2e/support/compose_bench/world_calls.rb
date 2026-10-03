require "fileutils"
require "open3"
require_relative "shape"

module E2E
  module ComposeBench
    module Worlds
      # WHAT ONE CALL ANSWERS in a rehearsal's world, mixed into `Worlds::Run`, which holds the files and
      # the variant. The tools answer by the harness's contract (`Tools`): `read_file` (and `read`,
      # rho's name for it) the file's text; `grep` the matching lines as `file:line: text`, its pattern a
      # Ruby `Regexp`, one file searched; `edit` one exact passage replaced, which must occur once;
      # `write` the file written; `probe_host` its host's `bin/probe` text. `bash` runs the
      # environment's own stand-in when the command is one (`bin/probe|rubocop|rails|srb|fetch <args>`,
      # the arguments the shell words that follow it, run by `sh` as the shell would run it, a fetch
      # spelled `curl -s https://<name>.example/feed` by the eval's own conversion), its `sleep`
      # returning at once. A stand-in followed by a shell operator is the `compound_command` dimension;
      # anything else is refused and logged in every world, never answered with an invented success.
      # A model answers its world's text. Every refusal here is the world's own: `is_error`, the
      # reason as the output.
      module Calls
        # A stand-in at the head of a command — as `bin/x`, `./bin/x`, or run by a named shell — and
        # the rest of the line.
        STAND_IN = %r{\A(?:(?:sh|bash)\s+)?(?:\./)?(bin/(?:probe|rubocop|rails|srb|fetch))(?=\s|\z)(.*)\z}m
        FETCH = %r{\Acurl[ \t]+-s[ \t]+https://(\w+)\.example/feed(?=\s|\z)(.*)\z}m
        # One trailing redirection of stderr into stdout, which the answer merges anyway.
        MERGED = /\s+2>&1\s*\z/
        # What makes a command compound where it follows the stand-in's words: a pipe, a list — a
        # newline among its separators — a background `&`, or a redirection: `<`, `>`, or one naming a
        # descriptor, `2>`, which is never an argument.
        OPERATOR = /\A[ \t]*(?:\d*[<>]|[|&;\n])/
        # One argument word the shell hands the stand-in as written: plain characters, or a quoted
        # passage with nothing in it the shell would expand. A word ends at a blank or an operator;
        # anything else there — a glob, a variable, a substitution — is no word the rehearsal can run.
        WORD = /\A[ \t]*((?:[\w.:\/=@+,%^-]+|'[^']*'|"[^"$`\\]*")+)(?=[ \t|&;<>\n]|\z)/
        QUOTED = /'([^']*)'|"([^"]*)"/
        # A command the rehearsal can run: its stand-in, the arguments the shell would hand it, and
        # whether a shell operator follows them.
        Command = Data.define(:script, :arguments, :compound)
        PROBE = "bin/probe".freeze
        # A stand-in run by the shell that defines its `sleep`: a function, found before any `sleep` on
        # PATH, that returns at once and notes how long it was asked to sleep in `REHEARSAL_SLEEPS`. The
        # stand-in is sourced with the call's arguments as its own, so it runs in that one shell.
        SHELL = 'sleep() { echo "$1" >> "$REHEARSAL_SLEEPS"; }; . "./$REHEARSAL_STAND_IN"'.freeze
        UNRUN = ": not run by the rehearsal world".freeze

        # One stand-in run in `directory`: its merged output, less the final newline, and its exit status.
        def self.execute(directory, script, arguments, sleeps: File::NULL)
          env = { "REHEARSAL_SLEEPS" => sleeps, "REHEARSAL_STAND_IN" => script }
          output, status = Open3.capture2e(env, "sh", "-c", SHELL, "sh", *arguments, chdir: directory)
          [output.chomp, status.exitstatus]
        end

        def call(name, input)
          case name
          when "read_file", "read" then read(input)
          when "grep" then grep(input)
          when "edit" then edit(input)
          when "write" then write(input)
          when "bash" then bash(input.fetch("command", "").to_s)
          when "probe_host" then probe(input.fetch("host", "").to_s)
          else refused_unrun(name.to_s)
          end
        end

        # A model answers its world's text whatever it read — O7's in the record format the variant
        # spells — and, where its world declares what the task does to the files, an editing model
        # (one whose tools include `Shape::EDITS`: its own `tools`, else what its branch inherits) does
        # it under `model_effect`.
        def model(body)
          touch("record_format") unless world.records.nil?
          if world.effects.any? && (body["tools"] || tool_names).intersect?(Shape::EDITS)
            touch("model_effect")
            world.effects.each { |path, passages| affect(path, passages) } if spelled?("model_effect")
          end
          done(spelled?("record_format") && world.records ? world.records : world.text)
        end

        # How long a step takes by the race's clock: the seconds its stand-in sleeps, zero for
        # anything else.
        def duration(verb, body)
          script, arguments = verb == "tool" ? timed(body.fetch("name"), body["input"] || {}) : nil
          script.nil? ? 0 : Worlds.slept(world.environment, script, arguments)
        end

        private

          def answer(verb, body)
            case verb
            when "tool" then call(body.fetch("name"), body["input"] || {})
            when "model" then model(body)
            else done("ok") # an ask or a wait, answered
            end
          end

          def read(input)
            path = input.fetch("path", "").to_s
            file = file_at(path)
            file.nil? ? refused("#{path}: no such file") : done(File.read(file, encoding: "UTF-8"))
          end

          def grep(input)
            path = input.fetch("path", "").to_s
            file = file_at(path)
            pattern = regexp(input.fetch("pattern", "").to_s)
            if file.nil?
              refused("#{path}: no such file")
            elsif pattern.nil?
              refused("#{input["pattern"]}: not a valid pattern")
            else
              shown = spelled?("matched_path") ? File.basename(path) : path
              lines = File.readlines(file, chomp: true, encoding: "UTF-8").each_with_index
                .filter_map { |text, index| "#{shown}:#{index + 1}: #{text}" if pattern.match?(text) }
              touch(lines.empty? ? "no_match" : "matched_path")
              done(lines.empty? && spelled?("no_match") ? "No matches found in #{path}" : lines.join("\n"))
            end
          end

          def regexp(source)
            Regexp.new(source, timeout: 1)
          rescue RegexpError
            nil
          end

          def edit(input)
            path = input.fetch("path", "").to_s
            file = file_at(path)
            passage = input.fetch("old_text", "").to_s
            text = file && File.read(file, encoding: "UTF-8")
            if text.nil?
              refused("#{path}: no such file")
            elsif passage.empty? || text.scan(passage).length != 1
              refused("#{path}: old_text must occur exactly once")
            elsif passage == input["new_text"].to_s
              refused("#{path}: the edit changes nothing")
            else
              at = text.index(passage)
              File.write(file, text.sub(passage) { input["new_text"].to_s })
              edited << path unless edited.include?(path)
              touch("runner_detail")
              detail = { "replacements" => 1, "first_changed_line" => text[0, at].count("\n") + 1 }
              done("Replaced one passage in #{path}.", structured: (detail if spelled?("runner_detail")))
            end
          end

          def write(input)
            path = input.fetch("path", "").to_s
            target = File.expand_path(path, files)
            if target.start_with?("#{files}/") && !File.directory?(target)
              FileUtils.mkdir_p(File.dirname(target))
              File.write(target, input.fetch("content", "").to_s)
              edited << path unless edited.include?(path)
              done("Wrote #{path}.")
            else
              refused("#{path}: not a file in the repository")
            end
          end

          # A stand-in followed by a shell operator is a compound command: refused, or its head alone.
          def bash(command)
            found = stand_in(command)
            touch("compound_command") if found&.compound
            if found.nil? || !File.file?(File.join(files, found.script)) || (found.compound && !spelled?("compound_command"))
              refused_unrun(command)
            else
              ran(found.script, found.arguments)
            end
          end

          # The stand-in a command runs; nil for none, and for a line the rehearsal cannot run in any
          # world. A fetch's conversion takes no arguments of its own.
          def stand_in(command)
            line = command.strip.sub(MERGED, "")
            head = STAND_IN.match(line)
            fetch = FETCH.match(line)
            if head
              words(head[1], head[2])
            elsif fetch
              words("bin/fetch", fetch[2], [fetch[1]]) if fetch[2].strip.empty? || fetch[2].match?(OPERATOR)
            end
          end

          # The shell words after a stand-in, quotes taken off, up to the end of the line or its first
          # operator; nil when something else follows them.
          def words(script, rest, arguments = [])
            word = WORD.match(rest)
            if rest.strip.empty? || rest.match?(OPERATOR)
              Command.new(script: script, arguments: arguments, compound: !rest.strip.empty?)
            elsif word
              words(script, word.post_match, [*arguments, word[1].gsub(QUOTED) { Regexp.last_match.captures.compact.first }])
            else
              nil
            end
          end

          # A stand-in's exit status is plain output unless the variant spells rho's runner detail.
          def ran(script, arguments)
            output, code = execute(script, arguments)
            touch("runner_detail") unless code.zero?
            if code.zero? || !spelled?("runner_detail")
              done(output)
            else
              line = "Command exited with code #{code}"
              Worlds.envelope(status: "completed", is_error: true, output: output.empty? ? line : "#{output}\n\n#{line}",
                structured: { "exit_status" => code })
            end
          end

          def probe(host)
            if !host.match?(/\A[\w.-]+\z/) || !File.file?(File.join(files, PROBE))
              refused("#{host}: no such host")
            else
              output, code = execute(PROBE, [host])
              code.zero? ? done(output) : refused(output)
            end
          end

          # The stand-in and arguments a tool call would run in this variant, for the race's clock.
          def timed(name, input)
            case name
            when "bash"
              found = stand_in(input.fetch("command", "").to_s)
              [found.script, found.arguments] if found && (!found.compound || spelled?("compound_command"))
            when "probe_host" then [PROBE, [input.fetch("host", "").to_s]]
            else nil
            end
          end

          def execute(script, arguments) = Calls.execute(files, script, arguments)

          def affect(path, passages)
            file = file_at(path)
            text = passages.reduce(File.read(file, encoding: "UTF-8")) { |changed, (from, to)| changed.sub(from) { to } }
            File.write(file, text)
          end

          def files = File.join(root, "files")

          # A file of the run's copy, never a path outside it.
          def file_at(path)
            target = File.expand_path(path, files)
            target if target.start_with?("#{files}/") && File.file?(target)
          end

          def spelled?(dimension) = variant.include?(dimension)

          def touch(dimension) = (touched << dimension unless touched.include?(dimension))

          def done(output, structured: nil) = Worlds.envelope(status: "completed", output: output, structured: structured)

          def refused(reason) = Worlds.envelope(status: "completed", output: reason, is_error: true)

          def refused_unrun(command)
            unknown << command
            refused("#{command}#{UNRUN}")
          end
      end
    end
  end
end
