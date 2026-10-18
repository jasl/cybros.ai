require_relative "base"
require_relative "codex_responses"
require_relative "../media_input"
require_relative "../media_type"

module SimpleInference
  module Protocols
    class OpenAIImages < Base
      # The locally frozen bounded requested count (C2-1 non-text matrix): the
      # normalized `images` quantity is final independently of provider
      # tokens, so a non-positive or absurd n is a pre-IO rejection. 1..10 is
      # the documented Images API enum for n.
      REQUESTED_COUNT_RANGE = (1..10)

      # The vendor's documented vocabularies (images/create reference + the
      # gpt-image-2.5 sunburst/flare pages, read 2026-09-16): quality is the
      # gpt-image family's auto/low/medium/high/xhigh/max plus the dall-e
      # family's standard/hd. A vendor-page widening, not a reference
      # agreement — codex's own enum stops at high and always sends auto
      # (codex-api/src/images.rs, ext/image-generation tool.rs). An unlisted
      # value is a loud pre-IO rejection.
      QUALITY_VOCABULARY = %w[auto low medium high xhigh max standard hd].freeze
      # Size is the documented enum across both families OR, for the 2.5
      # variants, an arbitrary WIDTHxHEIGHT under the page's rule below. No
      # per-row "declares an enum" switch: a provider answers a bad dall-e
      # size itself.
      SIZE_VOCABULARY = %w[
        auto 256x256 512x512 1024x1024 1536x1024 1024x1536 1792x1024 1024x1792
      ].freeze
      SIZE_PATTERN = /\A(\d+)x(\d+)\z/
      SIZE_MULTIPLE = 16
      SIZE_MAX_EDGE = 3840
      SIZE_ASPECT_RANGE = (Rational(1, 3)..Rational(3, 1))
      SIZE_PIXEL_RANGE = (655_360..8_294_400)

      # The vendor's `image[]` bound for the gpt-image family on
      # v1/images/edits (codex caps its own references at 5).
      MAX_EDIT_IMAGES = 16
      # How the edits body is spelled — a per-lane wire_options fact: the
      # public v1 route takes multipart/form-data (`image[]` + `mask`), the
      # codex backend the JSON shape codex-rs sends
      # (`{images: [{image_url: <data URL>}], prompt, ...}`,
      # codex-api/src/images.rs ImageEditRequest — which has no mask slot).
      EDITS_ENCODINGS = %w[multipart json].freeze

      # The standard OpenAI image-generation options this protocol forwards by
      # name — the dall-e family's n/quality/response_format/size/style/user
      # plus the gpt-image family's background/moderation/output_compression/
      # output_format (stream/partial_images are deliberately absent — this
      # protocol's contract is one buffered JSON response) — and the two
      # edit inputs, `images` (bytes-only MediaInputs) and `mask`, whose
      # presence retargets the compile to the edits path. Provider-specific
      # wire fields ride extra_body.
      def self.request_option_keys
        %i[
          background moderation n output_compression output_format
          quality response_format size style user
          images mask
        ].freeze
      end

      # `originator` is the codex image lane's marker (codex generates images
      # on the provider it chats on, ext/image-generation/src/backend.rs):
      # emitted only when a row declares it, so plain openai_api/xai rows
      # stay header-free.
      def initialize(images_path: nil, image_response_format: nil, images_edits_path: nil,
                     images_edits_encoding: nil, originator: nil, **connection)
        super(**connection)
        @images_path = normalize_images_path(images_path, "generations")
        @images_edits_path = normalize_images_path(images_edits_path, "edits")
        @images_edits_encoding = validated_edits_encoding(images_edits_encoding)
        @image_response_format = image_response_format
        validate_response_format(@image_response_format) unless @image_response_format.nil?
        @originator = originator.nil? ? nil : validated_marker(:originator, originator, nil)
      end

      def generate(model:, prompt: nil, input: nil, **options)
        compile_create(model: model, prompt: prompt, input: input, **options).execute(config)
      end

      def compile_create(model:, prompt: nil, input: nil, **options)
        raise SimpleInference::ValidationError, "model is required" if model.nil? || model.to_s.strip.empty?
        raise SimpleInference::ValidationError, "prompt or input is required" if prompt.to_s.strip.empty? && input.nil?

        declared, extra_body = split_request_options(options)
        # Compatible providers do not share one default delivery shape.
        # Catalog composition may pin the provider's current inline-byte
        # spelling; an explicit request value remains authoritative.
        if !declared.key?(:response_format) && @image_response_format
          declared[:response_format] = @image_response_format
        end
        validate_option_surface(declared)
        images = declared.delete(:images)
        mask = declared.delete(:mask)
        body = request_body(model: model, prompt: prompt, input: input, declared: declared)
        return compile_generation(body, extra_body) if images.nil?

        compile_edit(body, images: images, mask: mask, extra_body: extra_body)
      end

      private

      def compile_generation(body, extra_body)
        compile_json_request(path: @images_path, body: finalize_wire_body(body, extra_body), stream: false) do |connection_config, compiled|
          images_result_from_response(compiled_response(compiled, config: connection_config), "images.generate")
        end
      end

      # The edits compile, spelled by the lane's declared encoding.
      def compile_edit(body, images:, mask:, extra_body:)
        case @images_edits_encoding
        when "multipart" then compile_multipart_edit(body, images: images, mask: mask, extra_body: extra_body)
        when "json" then compile_json_edit(body, images: images, mask: mask, extra_body: extra_body)
        else raise ArgumentError, "unhandled images edits encoding #{@images_edits_encoding.inspect}"
        end
      end

      # The public v1 route: one `image[]` part per input, an optional `mask`
      # part, every scalar field beside them (the same multipart compile
      # the transcription route uses).
      def compile_multipart_edit(body, images:, mask:, extra_body:)
        parts = body.map { |key, value| { name: key, value: value } }
        images.each_with_index do |media, index|
          parts << { name: "image[]", value: multipart_file_part(media, filename: edit_filename("image-#{index + 1}", media)) }
        end
        parts << { name: "mask", value: multipart_file_part(mask, filename: edit_filename("mask", mask)) } unless mask.nil?

        compile_multipart_request(path: @images_edits_path, parts: finalize_multipart_parts(parts, extra_body)) do |connection_config, compiled|
          images_result_from_response(compiled_response(compiled, config: connection_config), "images.edit")
        end
      end

      # The codex backend's JSON shape: every input as a CONSTRUCTED data
      # URL (bytes-only, never a caller string), no mask slot.
      def compile_json_edit(body, images:, mask:, extra_body:)
        unless mask.nil?
          raise SimpleInference::ValidationError,
                "mask has no slot on the json images/edits shape (codex-rs ImageEditRequest carries images only)"
        end

        edit_body = body.merge("images" => images.map { |media| { "image_url" => data_url(media) } })
        compile_json_request(path: @images_edits_path, body: finalize_wire_body(edit_body, extra_body), stream: false) do |connection_config, compiled|
          images_result_from_response(compiled_response(compiled, config: connection_config), "images.edit")
        end
      end

      def data_url(media)
        "data:#{media.media_type};base64,#{[media.bytes].pack("m0")}"
      end

      def edit_filename(stem, media)
        "#{stem}.#{media.media_type.split("/").last.sub("jpeg", "jpg")}"
      end

      # The originator marker rides both the generations and the edits
      # request when the row declares it.
      def protocol_headers(_body)
        @originator.nil? ? {} : { CodexResponses::ORIGINATOR_HEADER => @originator }
      end

      def images_result_from_response(response, provider_format)
        body = response.body || {}

        SimpleInference::Images::Result.new(
          images: normalize_images(body["data"]),
          usage: normalize_usage(body["usage"]),
          provider_response: response,
          provider_format: provider_format,
          output_text: Array(body["data"]).filter_map { |item| item["revised_prompt"] }.first
        )
      end

      # The pinned option surface — every rejection here is pre-IO and loud.
      def validate_option_surface(declared)
        validate_requested_count(declared[:n]) if declared.key?(:n)
        validate_vocabulary(:quality, declared[:quality], QUALITY_VOCABULARY) if declared.key?(:quality)
        validate_size(declared[:size]) if declared.key?(:size)
        validate_response_format(declared[:response_format]) if declared.key?(:response_format)
        validate_edit_images(declared[:images]) if declared.key?(:images)
        validate_edit_mask(declared[:mask], declared.key?(:images)) if declared.key?(:mask)
      end

      def validate_requested_count(value)
        return if value.is_a?(Integer) && REQUESTED_COUNT_RANGE.cover?(value)

        raise SimpleInference::ValidationError,
              "n is the locally frozen bounded requested images count and must be an Integer in " \
              "#{REQUESTED_COUNT_RANGE.min}..#{REQUESTED_COUNT_RANGE.max} (got #{value.inspect})"
      end

      def validate_vocabulary(name, value, vocabulary)
        return if vocabulary.include?(value.to_s)

        raise SimpleInference::ValidationError,
              "#{name} #{value.inspect} is outside the frozen candidate vocabulary #{vocabulary.join(", ")}"
      end

      # The enum, or the gpt-image-2.5 pages' arbitrary-size rule: both
      # edges multiples of 16 and at most 3840, aspect within 1:3..3:1,
      # 655,360..8,294,400 pixels in total. One rejection, naming the
      # clause it breaks.
      def validate_size(value)
        return if SIZE_VOCABULARY.include?(value.to_s)

        match = SIZE_PATTERN.match(value.to_s)
        clause =
          if match.nil?
            "is neither a documented size (#{SIZE_VOCABULARY.join(", ")}) nor WIDTHxHEIGHT"
          else
            size_rule_violation(Integer(match[1], 10), Integer(match[2], 10))
          end
        return if clause.nil?

        raise SimpleInference::ValidationError, "size #{value.inspect} #{clause}"
      end

      def size_rule_violation(width, height)
        if width % SIZE_MULTIPLE != 0 || height % SIZE_MULTIPLE != 0
          "must have both edges a multiple of #{SIZE_MULTIPLE}"
        elsif width > SIZE_MAX_EDGE || height > SIZE_MAX_EDGE
          "must keep both edges at most #{SIZE_MAX_EDGE}"
        elsif !SIZE_ASPECT_RANGE.cover?(Rational(width, height))
          "must keep the aspect ratio within 1:3..3:1"
        elsif !SIZE_PIXEL_RANGE.cover?(width * height)
          "must total #{SIZE_PIXEL_RANGE.min}..#{SIZE_PIXEL_RANGE.max} pixels"
        end
      end

      # Byte-inline transport policy: only b64_json delivery is accepted. A
      # url response is a remote-fetch delivery mechanism and is LOCALLY
      # rejected regardless of provider support.
      def validate_response_format(value)
        return if value.to_s == "b64_json"

        raise SimpleInference::ValidationError,
              "response_format #{value.inspect} is locally rejected: image bytes travel inline as " \
              "b64_json only (byte-inline transport policy)"
      end

      # Bytes-only ingress: a non-empty list of image MediaInputs within the
      # vendor's `image[]` cap. Caller data URIs, URLs, paths and raw
      # strings are loud rejections here.
      def validate_edit_images(images)
        unless images.is_a?(Array) && !images.empty? && images.length <= MAX_EDIT_IMAGES
          raise SimpleInference::ValidationError,
                "images must be a non-empty Array of at most #{MAX_EDIT_IMAGES} SimpleInference::MediaInput " \
                "image inputs (got #{images.is_a?(Array) ? "#{images.length} entries" : images.class})"
        end

        images.each { |media| validate_image_media(:images, media) }
      end

      def validate_edit_mask(mask, images_present)
        unless images_present
          raise SimpleInference::ValidationError, "mask needs images: a mask edits the images it rides with"
        end

        validate_image_media(:mask, mask)
      end

      def validate_image_media(name, media)
        unless media.is_a?(SimpleInference::MediaInput) && MediaType::IMAGE_TYPES.include?(media.media_type)
          raise SimpleInference::ValidationError,
                "#{name} carries raw image bytes via SimpleInference::MediaInput — caller data URIs, URLs, " \
                "paths and non-image bytes are rejected at this lane's lowering " \
                "(got #{media.is_a?(SimpleInference::MediaInput) ? media.media_type : media.class})"
        end
      end

      def validated_edits_encoding(value)
        return EDITS_ENCODINGS.first if value.nil?
        return value.to_s if EDITS_ENCODINGS.include?(value.to_s)

        raise SimpleInference::ConfigurationError,
              "images_edits_encoding must be one of #{EDITS_ENCODINGS.join(", ")} (got #{value.inspect})"
      end

      # The wire body, STRING-keyed throughout — each wire field written in
      # exactly one place; declared options map 1:1 onto same-named fields.
      # Prompt/input quirk preserved: a String input doubles as the prompt when
      # no prompt was given (prompt-only providers read it either way).
      def request_body(model:, prompt:, input:, declared:)
        body = { "model" => model }
        declared.each { |key, value| body[key.to_s] = value }
        body["prompt"] = prompt unless prompt.to_s.strip.empty?
        body["input"] = input unless input.nil?
        body["prompt"] = input if body["prompt"].nil? && input.is_a?(String)
        body
      end

      def normalize_images(data)
        Array(data).map do |item|
          b64_json = item["b64_json"]
          mime_type = item["mime_type"] || "image/png"

          {
            "url" => item["url"],
            "b64_json" => b64_json,
            "mime_type" => mime_type,
            "revised_prompt" => item["revised_prompt"],
          }.compact
        end
      end

      # Truthful usage per the non-text matrix: the raw provider-shaped hash
      # survives untouched and the evidenced subcounts are flattened alongside
      # it (input_tokens_details.{image,text}_tokens -> {image,text}_input_tokens,
      # output_tokens_details likewise). A field absent on the wire stays
      # absent — never fabricated as 0 — and an omitted usage object stays nil
      # (gpt-image-2's declared-omission review branch).
      def normalize_usage(value)
        return nil if value.nil?

        value.merge(
          flattened_subcounts(value["input_tokens_details"], "input"),
          flattened_subcounts(value["output_tokens_details"], "output"),
        )
      end

      def flattened_subcounts(details, direction)
        return {} if details.nil?

        subcounts = {}
        subcounts["image_#{direction}_tokens"] = details["image_tokens"] if details.key?("image_tokens")
        subcounts["text_#{direction}_tokens"] = details["text_tokens"] if details.key?("text_tokens")
        subcounts
      end

      # Both image routes default under the api prefix (`/v1/images/<route>`);
      # a lane whose base has no prefix (the codex backend) declares the
      # bare path, as codex_responses does for /responses.
      def normalize_images_path(value, route)
        path = value.to_s.strip
        path = "#{config.api_prefix}/images/#{route}" if path.empty?
        path = "/#{path}" unless path.start_with?("/")

        prefix = config.api_prefix.to_s
        return path if prefix.empty? || path.start_with?("#{prefix}/") || path == prefix
        return path unless config.base_url_included_api_prefix?

        "#{prefix}#{path}"
      end
    end
  end
end
