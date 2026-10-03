module Nexus
  module Compose
    # A model-authored script is a pure function whose only effect is its
    # return value, so the isolate is granted nothing: no fs, network, console,
    # clock or randomness. Runs from a job; script failures fail that one task.
    class Evaluator
      TIMEOUT_MS = 1_000
      MAX_MEMORY_BYTES = 128 * 1024 * 1024
      # A script long enough to exceed this is not authoring a round.
      MAX_SOURCE_BYTES = 64 * 1024

      # `steps` is the placed tree in the door's wire shape; `lines` mirrors
      # it, one line per placed step and a `{line, members}` per group.
      Result = Data.define(:outcome, :value, :steps, :lines, :refusal, :detail) do
        class << self
          def built(steps, lines) = new(outcome: :steps, value: nil, steps:, lines:, refusal: nil, detail: nil)
          def returned(value) = new(outcome: :value, value:, steps: [], lines: [], refusal: nil, detail: nil)
          def refused(code, detail = nil) = new(outcome: :refused, value: nil, steps: [], lines: [], refusal: code, detail:)
        end

        def built? = refusal.nil?
        def value? = outcome == :value
        def steps? = outcome == :steps
      end

      # Beside this file, not Rails.root: a probe drives the shipped evaluator
      # against a real model without booting the application.
      LIBRARY = File.expand_path("builder.js", __dir__).freeze
      # Loaded after the builder: the run that compiles a script and reads it
      # against the builder, and the entry points called below.
      RUN_LIBRARY = File.expand_path("run.js", __dir__).freeze

      # A positioned parse reads the source as the builder compiles it — a
      # stage as a body of (g, params, results), a compose script as a body
      # of (g, params) or as the expression asFunction returns, alone on its
      # lines — behind a `throw` that V8 reaches only after parsing the whole
      # text: a source that closes the wrapper early is parsed and never run.
      Reading = Data.define(:prefix, :suffix) do
        def line_offset = prefix.count("\n")
      end
      STAGE_READING = Reading.new(prefix: "throw 0;\n(function (g, params, results) {\n\"use strict\";\n", suffix: "\n})")
      BODY_READING = Reading.new(prefix: "throw 0;\n(function (g, params) {\n\"use strict\";\n", suffix: "\n})")
      FUNCTION_READING = Reading.new(prefix: "throw 0;\n(function (g, params) {\n\"use strict\";\nreturn (\n", suffix: "\n);\n})")
      PARSE_FILENAME = "script".freeze
      PARSE_POSITION = /\A(?:Uncaught )?(?<message>.+) at #{PARSE_FILENAME}:(?<line>\d+):(?<column>\d+)\z/
      # Where a reading stopped, in the author's own source: `line` 1-based,
      # `column` V8's 0-based count of UTF-16 code units on that line.
      Failure = Data.define(:message, :line, :column) do
        def beyond?(other) = ([line, column] <=> [other.line, other.column]).positive?
      end
      # The same line terminators V8 counts lines by.
      LINE_BREAK = /\r\n|[\n\r\u2028\u2029]/
      SNIPPET_CHARS = 60
      DETAIL_CHARS = 400
      STAGE_SCRIPT = "the g.script stage's script".freeze
      # What a source that stops open means. V8 places it on the reading's own
      # text past the source and names that text's token, which the author
      # never wrote.
      UNFINISHED = "SyntaxError: the script ends before it is complete: a parenthesis, bracket, brace or " \
        "string it opens is never closed, or its last statement is unfinished".freeze
      # The two ways a script builds nothing the kernel can run, each refused
      # whole: a step placed after the script returned (the rest of an async
      # function past its first `await`, a `.then` callback) reached no graph,
      # and a compose script that placed no step leaves nothing to run.
      DEFERRED = "a script that awaits or defers builds nothing the kernel can see: write the steps as " \
        "statements, in order; the kernel runs them.".freeze
      NO_STEP = "the script built no step: write the steps as statements, in order; the kernel runs them.".freeze
      # A script that is ONE string or template literal — the model quoted
      # the whole script, or encoded it twice — builds no step because its
      # statements are only text. Said so, around the no-step words, which
      # every reader of those keeps matching.
      QUOTED = "the script is one quoted string, so nothing inside it ran; #{NO_STEP} " \
        "Write them as code, not inside quotes.".freeze
      QUOTED_SCRIPT = /\A\s*(?:"(?:[^"\\]|\\.)*+"|'(?:[^'\\]|\\.)*+'|`(?:[^`\\]|\\.)*+`)\s*;?\s*\z/m

      class << self
        def call(...) = new(...).call
        def stage(**options) = new(**options, stage: true).call
      end

      # `tool_names` are the round's declared tools; the first one is the
      # example a nameless `g.tool` is told to write.
      def initialize(script:, params: {}, tool_names: [], results: [], stage: false)
        @script = script.to_s
        @params = params
        @tool_names = Array(tool_names)
        @results = results
        @stage = stage
      end

      def call
        return Result.refused(:script_required) if @script.strip.empty?
        return Result.refused(:script_too_large) if @script.bytesize > MAX_SOURCE_BYTES

        evaluate
      end

      private

        def evaluate
          context = MiniRacer::Context.new(
            timeout: TIMEOUT_MS, max_memory: MAX_MEMORY_BYTES
          )
          context.eval(File.read(LIBRARY), filename: "nexus:compose/builder")
          context.eval(File.read(RUN_LIBRARY), filename: "nexus:compose/run")
          outcome = run(context)
          deferred(context) || outcome
        rescue MiniRacer::ScriptTerminatedError
          Result.refused(:script_timed_out, "exceeded #{TIMEOUT_MS}ms")
        rescue MiniRacer::V8OutOfMemoryError
          Result.refused(:script_out_of_memory)
        rescue MiniRacer::ParseError => error
          Result.refused(:script_syntax_error, first_line(error))
        rescue MiniRacer::Error => error
          Result.refused(:script_error, first_line(error))
        ensure
          context&.dispose
        end

        # What the script placed or returned, or the refusal its own error
        # names — read before the deferred check, which outranks both.
        def run(context)
          built = if @stage
            context.call("__nexusScript", @script, @params, @results, @tool_names.first)
          else
            context.call("__nexusCompose", @script, @params, @tool_names.first)
          end
          steps = Array(built["steps"])
          if built["outcome"] == "value"
            Result.returned(built["value"])
          elsif steps.empty?
            Result.refused(:script_error, @script.match?(QUOTED_SCRIPT) ? QUOTED : NO_STEP)
          else
            Result.built(steps, Array(built["lines"]))
          end
        rescue MiniRacer::RuntimeError => error
          # The script's own error (a throw, a bad builder call, a reach for the
          # clock) travels verbatim — it is the most useful thing the model can be
          # handed. A malformed script lands here too: `new Function` compiles inside the run.
          detail = first_line(error)
          if detail.start_with?("SyntaxError")
            syntax_refusal(context, detail)
          else
            Result.refused(:script_error, detail)
          end
        end

        # A continuation runs after the run returned, even one that threw, so
        # a step it placed reached no graph and the script is refused whole —
        # over what it placed in time and over the error it threw, since the
        # await is the mistake to repair. The builder notes each late call;
        # the queue is drained first, so none is still pending when read.
        def deferred(context)
          context.perform_microtask_checkpoint
          Result.refused(:script_error, DEFERRED) if context.call("__nexusDeferred")
        end

        # `new Function`'s SyntaxError carries no position, and a SyntaxError the
        # running script raises (JSON.parse on a tool's output, a RegExp built
        # from data) is the data's failure, not the author's syntax. The
        # builder's own compile decides which, built and never called; the
        # positioned parse only places the author's mistake. Rescued here, so
        # nothing either raises can escape the refusal it serves.
        def syntax_refusal(context, detail)
          if context.call("__nexusCompiles", @script, @stage)
            Result.refused(:script_error, detail)
          else
            failure = parse_failure(context)
            Result.refused(:script_syntax_error, failure ? located(failure) : detail)
          end
        rescue MiniRacer::Error
          Result.refused(:script_error, detail)
        end

        # Where the builder's compile failed. The builder reports a compose
        # script's body reading, unless the function reading gets further into
        # the source: then the author wrote the function asFunction reads
        # (`function (g, params) {` is no statement) and the mistake is inside
        # it. nil when the body reading parses: `new Function` also refuses a
        # source that closes its wrapper early, which no wrapped parse can place.
        def parse_failure(context)
          body = reading_failure(context, @stage ? STAGE_READING : BODY_READING)
          if @stage || body.nil?
            body
          else
            function = reading_failure(context, FUNCTION_READING)
            function&.beyond?(body) ? function : body
          end
        end

        # V8's placed failure for one reading, nil for a reading that parses:
        # the guard's own throw is the ordinary outcome.
        def reading_failure(context, reading)
          context.eval("#{reading.prefix}#{@script}#{reading.suffix}", filename: PARSE_FILENAME)
          nil
        rescue MiniRacer::ParseError => error
          match = PARSE_POSITION.match(error.message.to_s.lines.first.to_s.strip)
          match && Failure.new(message: match[:message], line: match[:line].to_i - reading.line_offset,
            column: match[:column].to_i)
        rescue MiniRacer::Error
          nil
        end

        # The author's own line and 1-based column, with that line's text, so
        # the repair starts where the mistake is. V8 names a line past the
        # source when something the source opened is never closed: that is
        # the end of the author's last line. The text is read as UTF-8 whatever
        # the caller labelled it, so a mislabelled source cannot fail the
        # refusal it is being located for.
        def located(failure)
          lines = String.new(@script, encoding: Encoding::UTF_8).scrub.split(LINE_BREAK, -1)
          if failure.line.between?(1, lines.length)
            line = lines[failure.line - 1]
            placed(failure.message, failure.line, line, characters(line, failure.column))
          else
            last = lines.rindex { |text| !text.strip.empty? } || (lines.length - 1)
            placed(UNFINISHED, last + 1, lines[last], lines[last].rstrip.length)
          end
        end

        def placed(message, number, line, column)
          "#{message} at line #{number}#{" of #{STAGE_SCRIPT}" if @stage}, column #{column + 1}: #{snippet(line, column)}"[0, DETAIL_CHARS]
        end

        # V8 counts a column in UTF-16 code units, so a character outside the
        # Basic Multilingual Plane (an emoji) counts twice; the author's line
        # is read in characters. A column inside a surrogate pair counts its
        # half as one replaced character, never raises.
        def characters(line, units)
          line.encode(Encoding::UTF_16LE).byteslice(0, units * 2).encode(Encoding::UTF_8, invalid: :replace).length
        end

        # About SNIPPET_CHARS of the line around the column, marked where cut.
        def snippet(line, column)
          start = (column - (SNIPPET_CHARS / 2)).clamp(0, [line.length - SNIPPET_CHARS, 0].max)
          text = line[start, SNIPPET_CHARS]
          "#{"…" if start.positive?}#{text}#{"…" if start + SNIPPET_CHARS < line.length}".strip
        end

        # Plain Ruby (no ActiveSupport): this file must load without the application.
        def first_line(error) = error.message.to_s.lines.first.to_s.strip[0, DETAIL_CHARS]
    end
  end
end
