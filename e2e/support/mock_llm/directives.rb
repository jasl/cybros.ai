require "cgi/escape"
require "json"

module E2E
  module MockLLM
    # THE `!mock` DIRECTIVE GRAMMAR, ported from the predecessor
    # (`app/controllers/mock_llm/v1/application_controller.rb`).
    #
    # A line beginning `!mock` is a script for the fake provider rather than something to echo.
    # Everything after the directives — either past a bare `--` on that line, or on the other lines
    # — is the prompt proper. That shape is the predecessor's and is kept, because the e2e journeys
    # that drive it are written against it — with ONE change: the fake reads the whole JOINED input,
    # and the LAST marker line is the round's. A system lead ahead of the prompt no longer hides the
    # marker; a continuation replays round one's prompt line and its script advances by the answers
    # already present, not by a second marker; a steer or a later prompt carrying its own line
    # overrides; and every marker line leaves the prompt as its inline remainder, so the echo —
    # which becomes the next turn's history — carries no directive for a later round to inherit. THE
    # SEED IS NOT THE ECHO: the kernel renders a reply turn's own input text into later history
    # verbatim, directive line and all, so a person's `!mock` line comes back inside every later
    # joined input. The LAST-marker rule keeps each person turn's own line authoritative; a
    # directive-less WOKEN turn (the kernel's receipt) reads the previous person line as its marker,
    # and the answer-count clock spends it — a `tool_call=` script whose calls are already answered
    # makes the woken round speak, as it does today. A seed carrying `slow=`/`error=`/`reply=` ahead
    # of a detached call is re-applied on the wake: the port's anchor row (rho_conversation_test)
    # writes `reply=` ahead of its spawn, so its woken turn speaks that remainder, which nothing
    # reads; no journey writes `slow=`/`error=` there. A bare `!mock --` clears every directive for
    # the round. THE CLOCK REWINDS UNDER A PRUNE (an accepted limitation): the fake's only clock is
    # the count of tool answers in the WHOLE input, so a compaction or prune that drops tool results
    # from the history rewinds it and the next round re-serves an earlier line of the script — a
    # journey that compacts a scripted loop reads its rounds by the kernel's keys, never by the
    # mock's position. `reply=<url-encoded text>` makes the fake SPEAK that text instead of echoing:
    # a request whose echo would be the size of what it read — a summarizer's — is one an echo can
    # prove nothing about. `raw_reply=<url-encoded text>` omits the usual `Mock: ` prefix, for
    # consumers that require a literal structured answer. Markers inside a JSON line's `text`
    # or `prompt` field use the same last-marker rule, so quoted source can script a provider answer.
    # `echo=images` limits the Responses echo to actual image parts, reporting their decoded
    # sizes through the ordinary image reader. `echo=content` omits system/developer messages
    # from the reply while retaining the conversation and tool results. `echo=request` reports
    # the received input, instructions and reasoning as JSON. All leave the full input in directive
    # selection and usage accounting.
    #
    module Directives
      # A directive line that parses to nothing usable is a caller mistake and
      # says so, rather than being silently treated as a prompt: a journey
      # whose `!mock error=500` typo quietly became a happy-path response
      # would pass while testing the opposite of its name.
      Invalid = Class.new(StandardError)

      DEFAULT_PROMPT = "Hello".freeze
      # The wall-clock a directive may buy, so a mistyped `slow=600` cannot
      # hang a suite. Overridable for the deliberate slow journeys.
      DEFAULT_MAX_SLOW_SECONDS = 0.2

      Controls = Data.define(
        :prompt, :reply, :raw_reply, :echo, :slow_seconds, :error_status, :error_message, :error_model,
        :error_includes_usage, :stream_chunk_delay_seconds, :usage, :reasoning,
        :tool_calls, :retry_after_seconds
      ) do
        def error? = !error_status.nil?

        # A provider may refuse one model while the same request succeeds on another.
        def error_for?(model) = error? && (error_model.nil? || error_model == model)

        # What the fake speaks: the scripted reply, else the echo.
        def spoken(echo: prompt) = reply || echo

        # WHICH CALLS THIS ROUND MAKES — a GROUP, the fan of one round —
        # chosen by how many answers the input already carries: the
        # groups are walked by their cumulative size, so a two-call group
        # is spent by two answers. Past the end of the script the fake
        # speaks, which is what ends the loop; a count inside a group (a
        # fan the kernel never pairs whole) speaks too.
        def tool_calls_at(answered)
          return nil if tool_calls.nil?

          before = 0
          tool_calls.each do |group|
            return group if answered == before

            before += group.length
          end
          nil
        end
      end

      # A SCRIPTED SEQUENCE OF TOOL CALLS, one GROUP per round. `tool_call=read,bash` makes the fake
      # ask for `read`, then — once it can see that call's answer — ask for `bash`, then speak. Each
      # element may carry its own arguments as `name:<url-encoded json>`; `tool_args=` supplies a
      # default for the ones that do not. An `&` joins a group: `tool_call=capture&capture,bash`
      # asks for BOTH captures in ONE round (a parallel fan with two images), then `bash` once both
      # are answered. `tool_calls` is the list of groups; a lone name is a group of one.
      #
      # WHICH ROUND IT IS, IS READ FROM THE INPUT, never from state: the
      # count of `function_call_output` items already present IS the index.
      # That keeps the fake stateless across the many processes that may
      # serve one loop, and it is also why the sequence ENDS — past the
      # last element there is nothing to call and the round speaks.
      #
      # WITHOUT A SEQUENCE, ONE ROUND WAS THE CEILING. The first cut
      # suppressed its single scripted call the instant any answer
      # appeared, so the deepest loop a deployed journey could reach was
      # model → tool → model. That is enough to prove a tool round and not
      # enough to prove an AGENT: nothing could show a model reading a
      # result and deciding what to do next, which is the whole behaviour
      # every long-session feature — compaction, memory — exists to serve.
      ToolCall = Data.define(:name, :arguments)

      class << self
        MARKER = /\A!mock\b/i

        def parse(prompt, max_slow_seconds: DEFAULT_MAX_SLOW_SECONDS)
          raw = prompt.to_s
          lines = raw.split(/\r?\n/, -1).flat_map { |line| quoted_directive_lines(line) }
          last = lines.rindex { |line| line.strip.match?(MARKER) }
          return plain(raw) if last.nil?

          controls = { error_includes_usage: false }
          kept = lines.each_with_index.filter_map do |line, index|
            next line unless line.strip.match?(MARKER)

            directive_part, inline = split(line.strip.sub(MARKER, "").strip)
            tokens(directive_part).each { |token| apply(token, controls) } if index == last
            inline unless inline.to_s.strip.empty?
          end

          build(controls, kept.join("\n"), max_slow_seconds)
        end

        # What the fake provider answers with when nothing scripted it. `!md`
        # is the predecessor's markdown mode, kept because the display
        # journeys assert against its exact shape.
        def content_for(prompt)
          text = prompt.to_s.strip
          text = DEFAULT_PROMPT if text.empty?
          return markdown(text.sub(/\A!md\b/i, "").strip) if text.match?(/\A!md\b/i)

          "Mock: #{text}"
        end

        # The predecessor's estimate: four characters to the token, rounded
        # up, on both sides. Deterministic and cheap — the point is that a
        # settlement test can predict it, not that it matches any tokenizer.
        # A reasoning round's thinking is output too, and the wire says how
        # much of it was reasoning (`output_tokens_details`).
        def usage_for(prompt_text, completion_text, reasoning: nil)
          prompt_tokens = (prompt_text.to_s.length / 4.0).ceil
          reasoning_tokens = (reasoning.to_s.length / 4.0).ceil
          completion_tokens = (completion_text.to_s.length / 4.0).ceil + reasoning_tokens
          usage = {
            "prompt_tokens" => prompt_tokens,
            "completion_tokens" => completion_tokens,
            "total_tokens" => prompt_tokens + completion_tokens,
          }
          reasoning ? usage.merge("output_tokens_details" => { "reasoning_tokens" => reasoning_tokens }) : usage
        end

        private

          # Quoted discussion prompts carry messages as JSON lines. The fixture
          # reads their text to find its own script; the production request stays
          # quoted. Ordinary JSON with no marker remains an ordinary echo.
          def quoted_directive_lines(line)
            return [line] unless line.lstrip.start_with?("{")

            source = JSON.parse(line)
            text = source.fetch("text") { source.fetch("prompt", "") }.to_s
            lines = text.split(/\r?\n/, -1)
            lines.any? { |value| value.strip.match?(MARKER) } ? lines : [line]
          rescue JSON::ParserError
            [line]
          end

          def plain(raw)
            Controls.new(
              prompt: raw.to_s.strip.empty? ? DEFAULT_PROMPT : raw.to_s.strip,
              reply: nil, raw_reply: nil, echo: nil, slow_seconds: nil, error_status: nil, error_message: nil, error_model: nil,
              error_includes_usage: false, stream_chunk_delay_seconds: nil,
              usage: nil, reasoning: nil, tool_calls: nil, retry_after_seconds: nil
            )
          end

          def build(controls, prompt, max_slow_seconds)
            Controls.new(
              prompt: prompt.to_s.strip.empty? ? DEFAULT_PROMPT : prompt.to_s.strip,
              reply: controls[:reply],
              raw_reply: controls[:raw_reply],
              echo: controls[:echo],
              slow_seconds: clamp(controls[:slow_seconds], max_slow_seconds),
              error_status: controls[:error_status],
              error_message: controls[:error_message],
              error_model: error_model!(controls),
              error_includes_usage: controls[:error_includes_usage],
              stream_chunk_delay_seconds: clamp(controls[:stream_chunk_delay_seconds], max_slow_seconds),
              usage: controls[:usage],
              reasoning: controls[:reasoning],
              tool_calls: tool_calls!(controls),
              retry_after_seconds: retry_after!(controls)
            )
          end

          # `retry_after` without `error` is a caller mistake and says so: a
          # header on a happy-path answer would floor nothing, and the
          # journey that typed it would pass while testing no floor.
          def retry_after!(controls)
            seconds = controls[:retry_after_seconds]
            raise Invalid, "retry_after needs error" if seconds && controls[:error_status].nil?

            seconds
          end

          def error_model!(controls)
            model = controls[:error_model]
            raise Invalid, "error_model needs error" if model && controls[:error_status].nil?

            model
          end

          # `tool_args` without `tool_call` is a caller mistake and says so,
          # for the same reason a mistyped `erorr=503` does: a journey whose
          # arguments silently vanished would pass while testing a call it
          # never made.
          def tool_calls!(controls)
            script = controls[:tool_call]
            if script.nil?
              raise Invalid, "tool_args needs tool_call" if controls[:tool_args]

              return nil
            end

            script
          end

          # `--` separates directives from an inline prompt. A body that opens
          # with it is all prompt and no directives.
          def split(body)
            text = body.to_s
            return ["", text.delete_prefix("--").lstrip] if text.start_with?("--")

            separator = text.match(/\s--(?:\s|\z)/)
            return [text.strip, ""] unless separator

            [text[0...separator.begin(0)].strip, text[separator.end(0)..].to_s]
          end

          def tokens(directive_part)
            return [] if directive_part.to_s.strip.empty?

            directive_part.split(/\s+/)
          end

          def apply(token, controls)
            key, value = token.split("=", 2)
            raise Invalid, "directive #{token.inspect} carries no value" if value.to_s.empty?

            case key.to_s.downcase
            when "slow" then controls[:slow_seconds] = decimal!(key, value)
            when "error", "fail" then controls[:error_status] = status!(key, value)
            when "fail_after_usage"
              controls[:error_status] = status!(key, value)
              controls[:error_includes_usage] = true
            when "message" then controls[:error_message] = value.to_s
            when "error_model" then controls[:error_model] = value
            # `retry_after=N` rides the scripted error as `Retry-After: N`
            # (the provider admission floor, 2026-09-15): the header the
            # kernel writes a lane's floor from. Needs `error=`.
            when "retry_after" then controls[:retry_after_seconds] = seconds!(key, value)
            when "stream_chunk_delay" then controls[:stream_chunk_delay_seconds] = decimal!(key, value)
            when "usage" then controls[:usage] = usage!(value)
            when "reasoning" then controls[:reasoning] = reasoning!(value)
            when "reply" then controls[:reply] = text!(key, value)
            when "raw_reply" then controls[:raw_reply] = text!(key, value)
            when "echo"
              raise Invalid, "echo takes images, content or request" unless %w[images content request].include?(value)

              controls[:echo] = value
            when "tool_call" then controls[:tool_call] = script!(key, value, controls)
            when "tool_args"
              controls[:tool_args] = arguments!(value)
              controls[:tool_call] = rearm(controls)
            else raise Invalid, "unknown directive #{key.inspect}"
            end
          end

          # The wire's own tool-name grammar, so a journey cannot script a
          # call the provider would have refused.
          NAME_SHAPE = /\A[a-zA-Z0-9_.-]{1,128}\z/

          # `name` or `name:<url-encoded json>`, comma-separated into
          # rounds and `&`-joined within one. Neither a comma nor an
          # ampersand can appear unencoded inside the arguments —
          # `arguments!` requires them url-encoded and CGI escapes both —
          # so splitting on them is unambiguous. NOT `+`: url-encoding
          # spells a SPACE as `+`, so `echo one` inside an element's
          # arguments would split the element.
          def script!(key, value, controls)
            groups = value.split(",", -1).map do |group|
              group.split("&", -1).map { |element| element!(key, element, controls) }
            end
            raise Invalid, "#{key} names no call" if groups.empty?

            groups
          end

          def element!(key, element, controls)
            name, encoded = element.split(":", 2)
            raise Invalid, "#{key} must be a tool name" unless NAME_SHAPE.match?(name)

            ToolCall.new(
              name: name,
              arguments: encoded ? arguments!(encoded) : (controls[:tool_args] || "{}")
            )
          end

          # A `tool_args` token that arrived AFTER `tool_call` on the
          # directive line still has to reach the calls it is the default
          # for — the line is order-free everywhere else and being
          # order-sensitive here is exactly the silent trap the grammar's
          # own header warns about.
          def rearm(controls)
            groups = controls[:tool_call]
            return nil if groups.nil?

            groups.map do |group|
              group.map { |call| call.arguments == "{}" ? call.with(arguments: controls[:tool_args]) : call }
            end
          end

          # URL-encoded, like `reasoning=`, because the directive line is
          # split on whitespace and a JSON object is full of it. It must
          # PARSE: arguments the wire could not have carried would make the
          # fake more permissive than the thing it stands in for.
          def arguments!(value)
            decoded = CGI.unescape(value.to_s)
            JSON.parse(decoded)
            decoded
          rescue JSON::ParserError
            raise Invalid, "tool_args must be url-encoded JSON"
          end

          def decimal!(key, value)
            raw = value.to_s
            raise Invalid, "#{key} takes a non-negative decimal, got #{raw.inspect}" unless
              raw.match?(/\A\d+(?:\.\d+)?\z/)

            raw.to_f
          end

          def seconds!(key, value)
            raw = value.to_s
            raise Invalid, "#{key} takes whole seconds, got #{raw.inspect}" unless raw.match?(/\A\d{1,6}\z/)

            raw.to_i
          end

          def status!(key, value)
            raw = value.to_s
            status = raw.to_i
            raise Invalid, "#{key} takes an HTTP status, got #{raw.inspect}" unless
              raw.match?(/\A\d{3}\z/) && status.between?(100, 599)

            status
          end

          def usage!(value)
            match = value.to_s.match(/\A(?<prompt>\d+):(?<completion>\d+)\z/)
            raise Invalid, "usage takes <prompt>:<completion>, got #{value.inspect}" unless match

            prompt_tokens = match[:prompt].to_i
            completion_tokens = match[:completion].to_i
            {
              "prompt_tokens" => prompt_tokens,
              "completion_tokens" => completion_tokens,
              "total_tokens" => prompt_tokens + completion_tokens,
            }
          end

          def reasoning!(value) = text!("reasoning", value)

          def text!(key, value)
            text = CGI.unescape(value.to_s)
            raise Invalid, "#{key} takes URL-encoded text" if text.strip.empty?

            text
          end

          def clamp(seconds, max)
            return nil if seconds.nil?

            [seconds.to_f, max.to_f].min
          end

          def markdown(body)
            body = DEFAULT_PROMPT if body.to_s.strip.empty?
            <<~MARKDOWN.strip
              # Mock Markdown

              **Prompt:** #{body}

              - This response is deterministic for E2E.
              - It includes markdown constructs: heading, bold, list, and code.

              ```txt
              mock_llm streaming: enabled
              ```
            MARKDOWN
          end
      end
    end
  end
end
