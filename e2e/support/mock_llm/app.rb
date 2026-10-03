require "base64"
require "digest"
require "json"
require "securerandom"
require "stringio"
require_relative "directives"

module E2E
  module MockLLM
    # THE FAKE PROVIDER, as a standalone rack app.
    #
    # It answers the OpenAI-compatible wire the `dev` catalog lane declares,
    # which is why that lane needs no protocol or parser of its own: five
    # endpoints, one per shipped dev execution profile.
    #
    # POST /v1/responses text_generation (SSE) POST /v1/embeddings embedding POST
    # /v1/images/generations image_generation POST /v1/audio/speech speech_generation POST
    # /v1/audio/transcriptions transcription (multipart) GET /v1/models the catalogue, for probes
    #
    # **It is NOT mounted inside Nexus, and that is the point.** The
    # predecessor shipped this as eight controllers under
    # `app/controllers/mock_llm/`, so test-only endpoints rode in the
    # production image behind nothing but a route. Here it is a separate
    # process on its own loopback port, and the harness points the dev lane's
    # `base_url` at it through the ordinary catalog override seam — the same
    # seam an operator would use, exercised rather than bypassed.
    #
    # `/v1/chat/completions` is deliberately absent. The predecessor served it
    # because its dev lane used the chat wire; every alt2 dev text profile
    # rides `openai_responses`, so that endpoint would have no caller.
    class App
      SSE_HEADERS = {
        "content-type" => "text/event-stream",
        "cache-control" => "no-cache",
        "x-accel-buffering" => "no",
      }.freeze

      # Public fixture material: the management journey must install this through
      # Nexus before its keyed model will answer a request.
      API_KEY = "e2e-provider-key-for-mock-only".freeze

      MODELS = {
        "mock-text" => "text_generation",
        "mock-keyed-text" => "text_generation",
        # The text-only twin of `dev/mock-text`: the same wire, a row that declares no image
        # ingress, so a picture rides as the index line and the echo never sees an `input_image`
        # part.
        "mock-text-only" => "text_generation",
        "mock-unmetered" => "text_generation",
        "mock-priced" => "text_generation",
        "mock-embedding" => "embedding",
        "mock-image" => "image_generation",
        "mock-speech" => "speech_generation",
        "mock-transcription" => "transcription",
      }.freeze

      # A 1x1 PNG, so an image response carries bytes a decoder accepts rather
      # than a placeholder string that only looks like base64.
      PIXEL_PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==".freeze
      # A minimal RIFF/WAVE header plus silence: enough that a caller checking
      # the container gets the truth.
      SILENCE_WAV = "UklGRiQAAABXQVZFZm10IBAAAAABAAEAgD4AAAB9AAACABAAZGF0YQAAAAA=".freeze

      def initialize(max_slow_seconds: Directives::DEFAULT_MAX_SLOW_SECONDS, clock: Kernel)
        @max_slow_seconds = max_slow_seconds
        @clock = clock
      end

      def call(env)
        route(env)
      rescue Directives::Invalid => e
        # A bad directive is the CALLER's mistake, and it says so in the
        # provider's own error shape so the exercised path is a real 400.
        error_response(400, e.message, type: "invalid_request_error")
      rescue JSON::ParserError
        error_response(400, "request body is not JSON", type: "invalid_request_error")
      end

      private

        def route(env)
          method = env["REQUEST_METHOD"]
          path = env["PATH_INFO"]

          case [method, path]
          in ["GET", "/v1/models"] then models_response
          in ["POST", "/v1/responses"] then responses(env)
          in ["POST", "/v1/embeddings"] then embeddings(env)
          in ["POST", "/v1/images/generations"] then images(env)
          in ["POST", "/v1/audio/speech"] then speech(env)
          in ["POST", "/v1/audio/transcriptions"] then transcriptions(env)
          else error_response(404, "unknown endpoint #{method} #{path}", type: "invalid_request_error")
          end
        end

        # ---- text generation -------------------------------------------------
        #
        # The event shapes are the ones the vendored parser actually consumes
        # (`SimpleInference::Protocols::OpenAIResponses`): output-text deltas,
        # optional reasoning deltas, and ONE terminal `response.completed`
        # carrying the whole body. Usage is terminal-only on this wire — the
        # parser refuses to fabricate a zero — so it appears exactly once, on
        # that event.
        def responses(env)
          body = json_body(env)
          model = body["model"].to_s
          return unknown_model(model) unless MODELS[model] == "text_generation"
          if model == "mock-keyed-text" && env["HTTP_AUTHORIZATION"] != "Bearer #{API_KEY}"
            return error_response(401, "provider key is missing or incorrect", type: "authentication_error")
          end

          controls = Directives.parse(prompt_from_input(body["input"]), max_slow_seconds: @max_slow_seconds)
          # WHICH ROUND THIS IS, READ FROM THE INPUT. The directive lives
          # in the user message and that message rides EVERY round, so a
          # fake that simply re-read it would call the same tool forever
          # and no loop could ever complete. The count of answers already
          # present is the index into the script: it advances the sequence,
          # and past its end there is nothing to call and the round speaks.
          # Stateless, because one loop is served by however many processes
          # happen to claim its rounds. AND ONLY WHEN THE REQUEST DECLARES
          # TOOLS: every real provider refuses a call to a tool it was not
          # given, and the kernel's summarizer declares none while its
          # prompt carries the turn's own `!mock … tool_call=` line inside
          # the serialized history — a tool-less request with zero answers,
          # which without this gate would be answered with the script's
          # first call. The directive is still read; there is simply
          # nothing to call with, so the round speaks.
          calls = controls.tool_calls_at(answers_in(body["input"])) if declares_tools?(body)
          sleep_for(controls.slow_seconds)

          return responses_error(controls) if controls.error_for?(model)

          echo = echo_from_input(body["input"], controls)
          content = controls.raw_reply || Directives.content_for(controls.spoken(echo: echo))
          usage = controls.usage || Directives.usage_for(controls.prompt, content, reasoning: controls.reasoning)
          [200, SSE_HEADERS.dup, sse_stream(model, controls, content, usage, calls)]
        end

        # Fixtures can read the wire's content without copying fixed instructions
        # into every later reply. Controls and usage still read the whole request.
        def echo_from_input(input, controls)
          case controls.echo
          when "images" then prompt_from_input(input, images_only: true)
          when "content" then Directives.parse(prompt_from_input(input, content_only: true)).prompt
          else controls.prompt
          end
        end

        # `calls` is the round's GROUP (nil: the round speaks). ONE call_id
        # per call, minted once and used on BOTH the stream item and the
        # terminal body. Two ids reconciled positionally is a shape
        # production never produces, and a fake that is wrong in a way
        # production is not stops testing the thing it stands in for: the
        # id-matching arm of the parser's reconciliation would never run
        # under e2e, and a console correlating the live narration with the
        # fanned task by call id would mismatch here and only here.
        def sse_stream(model, controls, content, usage, calls = nil)
          response_id = "resp_#{SecureRandom.hex(8)}"
          minted = Array(calls).map { |call| [call, "call_#{SecureRandom.hex(6)}"] }
          Enumerator.new do |out|
            controls.reasoning&.then do |reasoning|
              chunks(reasoning).each do |delta|
                out << event("response.reasoning_text.delta", delta: delta, item_id: "#{response_id}_r")
                sleep_for(controls.stream_chunk_delay_seconds)
              end
            end

            if minted.any?
              minted.each_with_index do |(call, call_id), index|
                tool_call_events(response_id, call, call_id, index) { |frame| out << frame }
              end
            else
              chunks(content).each do |delta|
                out << event("response.output_text.delta", delta: delta, item_id: "#{response_id}_o")
                sleep_for(controls.stream_chunk_delay_seconds)
              end
            end

            out << event("response.completed",
              response: completed_body(response_id, model, content, usage, minted, reasoning: controls.reasoning))
            out << "data: [DONE]\n\n"
          end
        end

        # THE THREE FRAMES A TOOL CALL TAKES ON THIS WIRE, in the order the
        # parser reconciles them: the item announces itself, its arguments
        # stream, and the terminal body repeats the finished item. The
        # parser assembles calls from the STREAM and pairs them against the
        # body positionally, so emitting only one half would produce a call
        # with no id or no arguments — the shape a real provider never
        # sends and the reason this is written out rather than faked with a
        # single frame. A group's calls take consecutive output indexes
        # and their own item ids; the first keeps the id a lone call
        # always had.
        def tool_call_events(response_id, call, call_id, index = 0)
          item_id = call_item_id(response_id, index)
          yield event("response.output_item.added",
            output_index: index,
            item: { "id" => item_id, "type" => "function_call",
                    "call_id" => call_id,
                    "name" => call.name, "arguments" => "" })
          yield event("response.function_call_arguments.delta",
            item_id: item_id, output_index: index, delta: call.arguments)
          yield event("response.function_call_arguments.done",
            item_id: item_id, output_index: index, arguments: call.arguments)
        end

        def call_item_id(response_id, index) = index.zero? ? "#{response_id}_fc" : "#{response_id}_fc#{index}"

        # THE WIRE DECIDES THE SPELLING. `Directives.usage_for` and the
        # `usage=<prompt>:<completion>` directive both speak the chat dialect,
        # because that is the vocabulary the predecessor's grammar used and
        # journeys are written against it. The Responses family names the same
        # two numbers differently, and the difference is not cosmetic: the
        # gem's usage reader files an unrecognized key under DIAGNOSTICS rather
        # than quantities, so a chat-shaped body on this wire reports no input
        # or output tokens at all and every cost assertion downstream reads
        # empty. The predecessor translated at exactly this boundary
        # (`response_usage_payload`); the port had dropped it.
        RESPONSES_USAGE_KEYS = {
          "prompt_tokens" => "input_tokens",
          "completion_tokens" => "output_tokens",
        }.freeze

        def responses_usage(usage)
          usage.to_h { |key, value| [RESPONSES_USAGE_KEYS.fetch(key, key), value] }
        end

        # A REASONING ROUND ANSWERS AS A STATELESS PROVIDER DOES: the body
        # leads with the reasoning item — its summary and its encrypted blob,
        # the material a replay sends back — and the usage counts its tokens,
        # which is what the kernel prices a replayed blob by. The blob is the
        # summary's digest, so the same thought replays byte-identical.
        def completed_body(response_id, model, content, usage, minted = [], reasoning: nil)
          output = completed_output(response_id, content, minted)
          output = [reasoning_item(response_id, reasoning)] + output if reasoning
          {
            "id" => response_id,
            "object" => "response",
            "model" => model,
            "status" => "completed",
            "output" => output,
            "usage" => responses_usage(usage),
          }
        end

        def reasoning_item(response_id, reasoning)
          {
            "id" => "#{response_id}_r",
            "type" => "reasoning",
            "summary" => [{ "type" => "summary_text", "text" => reasoning }],
            "encrypted_content" => "mock-#{Digest::SHA256.hexdigest(reasoning)}",
          }
        end

        # A ROUND ANSWERS WITH TEXT OR WITH CALLS, never both — which is
        # the shape the Responses API itself takes when a tool is chosen,
        # and the shape the kernel's fan expects.
        def completed_output(response_id, content, minted)
          return text_output(response_id, content) if minted.empty?

          minted.each_with_index.map do |(call, call_id), index|
            {
              "id" => call_item_id(response_id, index),
              "type" => "function_call",
              "call_id" => call_id,
              "name" => call.name,
              "arguments" => call.arguments,
            }
          end
        end

        def text_output(response_id, content)
          [{
            "id" => "#{response_id}_o",
            "type" => "message",
            "role" => "assistant",
            "content" => [{ "type" => "output_text", "text" => content }],
          }]
        end

        # A scripted failure answers on the SSE channel when it was billed — the provider had
        # already started responding — and as a plain HTTP error when it was not. The harness needs
        # both to distinguish charged failures from unstarted refusals.
        def responses_error(controls)
          return scripted_error(controls) unless controls.error_includes_usage

          message = controls.error_message || "mock scripted failure"
          usage = controls.usage || Directives.usage_for(controls.prompt, "")
          stream = Enumerator.new do |out|
            out << event("response.failed", response: {
              "status" => "failed",
              "usage" => responses_usage(usage),
              "error" => { "message" => message, "type" => error_type(controls.error_status) },
            })
            out << "data: [DONE]\n\n"
          end
          [200, SSE_HEADERS.dup, stream]
        end

        # ---- the unary endpoints ---------------------------------------------

        def embeddings(env)
          body = json_body(env)
          model = body["model"].to_s
          return unknown_model(model) unless MODELS[model] == "embedding"

          inputs = Array(body["input"].is_a?(Array) ? body["input"] : [body["input"]])
          controls = Directives.parse(inputs.first.to_s, max_slow_seconds: @max_slow_seconds)
          sleep_for(controls.slow_seconds)
          return scripted_error(controls) if controls.error_for?(model)

          dimensions = (body["dimensions"] || 8).to_i
          json_response(200, {
            "object" => "list",
            "model" => model,
            "data" => inputs.each_with_index.map do |text, index|
              { "object" => "embedding", "index" => index, "embedding" => vector(text, dimensions) }
            end,
            "usage" => controls.usage || Directives.usage_for(inputs.join, ""),
          })
        end

        def images(env)
          body = json_body(env)
          model = body["model"].to_s
          return unknown_model(model) unless MODELS[model] == "image_generation"

          controls = Directives.parse(body["prompt"].to_s, max_slow_seconds: @max_slow_seconds)
          sleep_for(controls.slow_seconds)
          return scripted_error(controls) if controls.error_for?(model)

          count = [[(body["n"] || 1).to_i, 1].max, 4].min
          json_response(200, {
            "created" => 0,
            "data" => Array.new(count) { { "b64_json" => PIXEL_PNG } },
            "usage" => responses_usage(controls.usage || Directives.usage_for(controls.prompt, "")),
          })
        end

        def speech(env)
          body = json_body(env)
          model = body["model"].to_s
          return unknown_model(model) unless MODELS[model] == "speech_generation"

          controls = Directives.parse(body["input"].to_s, max_slow_seconds: @max_slow_seconds)
          sleep_for(controls.slow_seconds)
          return scripted_error(controls) if controls.error_for?(model)

          [200, { "content-type" => "audio/wav" }, [SILENCE_WAV.unpack1("m0")]]
        end

        # Multipart, because that is what the transcription lane sends: its
        # audio rides an attachments slot rather than being inlined, which is
        # exactly why the inline byte bound does not apply to it.
        def transcriptions(env)
          parts = multipart(env)
          model = parts["model"].to_s
          return unknown_model(model) unless MODELS[model] == "transcription"

          controls = Directives.parse(parts["prompt"].to_s, max_slow_seconds: @max_slow_seconds)
          sleep_for(controls.slow_seconds)
          return scripted_error(controls) if controls.error_for?(model)

          audio_bytes = parts["file"].to_s.bytesize
          json_response(200, {
            "text" => "Mock transcription of #{audio_bytes} bytes",
            "usage" => responses_usage(controls.usage || Directives.usage_for(controls.prompt, "")),
          })
        end

        def models_response
          json_response(200, {
            "object" => "list",
            "data" => MODELS.keys.map { { "id" => _1, "object" => "model", "owned_by" => "mock" } },
          })
        end

        # ---- plumbing --------------------------------------------------------

        # `tools` is a request fact (the kernel merges a round's definitions
        # onto the request, never a generation control), so its presence
        # is what a call is gated on.
        def declares_tools?(body)
          tools = body["tools"]
          tools.is_a?(Array) && !tools.empty?
        end

        # HOW MANY TOOL RESULTS this input already carries — the index
        # into a scripted sequence, and the only clock the fake has.
        def answers_in(input)
          case input
          when Array then input.sum { answers_in(_1) }
          when Hash
            return 1 if input["type"].to_s == "function_call_output"

            answers_in(input["content"] || input["input"] || [])
          else 0
          end
        end

        # The Responses wire nests its text; the parser upstream flattens the
        # same shapes, and this mirrors it rather than guessing.
        def prompt_from_input(input, images_only: false, content_only: false)
          case input
          when String then (input unless images_only)
          when Array
            parts = input.filter_map { prompt_from_input(_1, images_only: images_only, content_only: content_only) }
            parts.reject!(&:empty?) if images_only || content_only
            parts.join("\n")
          when Hash
            return "" if content_only && %w[system developer].include?(input["role"])
            return (input["text"].to_s unless images_only) if input.key?("text")
            return image_pointer(input) if input["type"].to_s == "input_image"

            # A TOOL RESULT WAS INVISIBLE HERE. A `function_call_output`
            # item carries `output`, not `content`/`input`/`text`, so it
            # contributed NOTHING to the prompt — which meant the fake
            # could not see a tool result at all, and no journey could
            # observe what the model was shown. That is the one thing the
            # whole tool protocol exists to deliver.
            prompt_from_input(input["content"] || input["input"] || input["output"] || "",
              images_only: images_only, content_only: content_only)
          else (input.to_s unless images_only)
          end
        end

        # AN IMAGE IS OBSERVABLE: an `input_image` part carries a data URL and no text, so it
        # contributed nothing to the echo and no journey could see that a picture left the process.
        # It echoes as its media type and DECODED size — the fake's second witness beside the
        # sealed-request door (the entries show the kernel's intent, `{type: upload}`; only the echo
        # shows a data URL was lowered) — and never a byte of the image. The line never starts with
        # `!mock`, so it is no directive.
        def image_pointer(part)
          url = part["image_url"]
          url = url["url"] if url.is_a?(Hash)
          media_type, payload = url.to_s.delete_prefix("data:").split(";base64,", 2)
          bytes = payload ? Base64.decode64(payload).bytesize : 0
          "[image #{media_type} #{bytes} bytes]"
        end

        def json_body(env)
          raw = env["rack.input"]&.read.to_s
          return {} if raw.strip.empty?

          parsed = JSON.parse(raw)
          parsed.is_a?(Hash) ? parsed : {}
        end

        # Enough multipart to read the named parts, which is all this wire
        # sends. A malformed body answers 400 rather than raising.
        def multipart(env)
          type = env["CONTENT_TYPE"].to_s
          boundary = type[/boundary=("?)([^";]+)\1/, 2]
          raise Directives::Invalid, "multipart request carries no boundary" if boundary.nil?

          raw = env["rack.input"]&.read.to_s
          raw.split("--#{boundary}").each_with_object({}) do |section, parts|
            head, body = section.split("\r\n\r\n", 2)
            name = head.to_s[/name="([^"]+)"/, 1]
            next if name.nil? || body.nil?

            parts[name] = body.sub(/\r\n\z/, "")
          end
        end

        def vector(text, dimensions)
          seed = text.to_s.each_byte.sum
          Array.new([[dimensions, 1].max, 3072].min) { |index| ((seed + index) % 100) / 100.0 }
        end

        def chunks(text) = text.to_s.scan(/.{1,18}/m)

        def event(type, **payload)
          "data: #{JSON.generate({ "type" => type }.merge(payload.transform_keys(&:to_s)))}\n\n"
        end

        def json_response(status, payload)
          [status, { "content-type" => "application/json" }, [JSON.generate(payload)]]
        end

        def unknown_model(model)
          error_response(404, "unknown model #{model.inspect}", type: "invalid_request_error",
                         code: "model_not_found")
        end

        def error_response(status, message, type: nil, code: nil, headers: {})
          error = { "message" => message, "type" => type || error_type(status) }
          error["code"] = code if code
          rack_status, rack_headers, body = json_response(status, { "error" => error })
          [rack_status, rack_headers.merge(headers), body]
        end

        # THE SCRIPTED FAILURE, on the plain HTTP arm every endpoint shares:
        # the status, the message, and `Retry-After` when the script named
        # one — the header the kernel floors a lane from.
        def scripted_error(controls)
          headers = controls.retry_after_seconds.nil? ? {} : { "retry-after" => controls.retry_after_seconds.to_s }
          error_response(controls.error_status, controls.error_message || "mock scripted failure", headers: headers)
        end

        def error_type(status)
          case status.to_i
          when 401 then "authentication_error"
          when 403 then "permission_error"
          when 429 then "rate_limit_error"
          when 400..499 then "invalid_request_error"
          when 500..599 then "server_error"
          else "api_error"
          end
        end

        def sleep_for(seconds)
          value = seconds.to_f
          @clock.sleep(value) if value.positive?
        end
    end
  end
end
