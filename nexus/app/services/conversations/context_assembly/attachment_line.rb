module Conversations
  class ContextAssembly
    # THE INDEX LINE: what a model reads about a picture it
    # cannot see — one text part, IN THE PICTURE'S POSITION, so a text-only
    # row still reads "here is the diagram" followed by what the diagram
    # was. ONE grammar for the two facts a model can read about an
    # attachment: on the wire when the row cannot take it (the two reasons
    # here), and in a summary when the cut removed it (`NOT_CARRIED`, the
    # summarizer's pointer). Image lines expose no upload id. Ordinary
    # files carry their upload reference for the executor attachment tools;
    # their bytes remain outside model-native media. Model-facing image bytes: measured
    # by the index-line bench, never tuned by hand: `NOT_SHOWN` is the
    # spelling the bench ruled — the cause clause
    # names the model's own limit, so a reply stops sending the person
    # to re-upload a picture this row could never read.
    #
    # The decision is taken WHERE SEGMENTS ARE BUILT (Inline, ChatHistory,
    # the loop lane over its composed messages) against ONE closed
    # predicate built from the turn's resolved selection — per PART, per
    # TURN, at ASSEMBLY, because the answerer is a per-turn fact and a
    # regenerate re-asks under the turn's engine.
    module AttachmentLine
      NOT_SHOWN = "image content omitted: this model does not support image input".freeze
      NOT_TAKEN = "this model does not take %s".freeze
      NOT_CARRIED = "not carried past the summary; ask for it again if needed".freeze
      FILE_AVAILABLE = "file content is available through attachment tools".freeze

      module_function

      def render(upload, reason)
        bytes = ActiveSupport::NumberHelper.number_to_delimited(upload.byte_size)
        image = ContentBodies::AttachedMessage.image?(upload)
        reference = image ? "" : " nexus://uploads/#{upload.public_id}"
        reason = FILE_AVAILABLE unless image
        "[Attachment: #{upload.filename} (#{upload.content_type}, #{bytes} bytes)#{reference} — #{reason}]"
      end

      # The predicate, once: a callable answering nil when the selection
      # CARRIES a content type natively — the workload's modality, the
      # catalog row's `input_modalities` and the wire's allowlist all say
      # yes (`Input.media_allowed?`) — else the reason the line states:
      # the row declares no image ingress, or it does and the wire refuses
      # this type (HEIC on an OpenAI row). nil keeps every part.
      def carries_for(selection)
        lambda do |content_type|
          next FILE_AVAILABLE unless content_type.to_s.start_with?("image/")
          next nil if ModelSelection::Workloads::Input.media_allowed?(selection, content_type)

          modality = content_type.to_s.split("/").first
          if selection.capabilities.input_modalities.include?(modality)
            format(NOT_TAKEN, content_type)
          else
            NOT_SHOWN
          end
        end
      end

      # The Segment parts for bound rows in occurrence order: a native
      # attachment, or the line as a text part.
      def parts(uploads, carries: nil)
        uploads.map do |upload|
          reason = carries&.call(upload.content_type)
          reason ? Segment.text_part(render(upload, reason)) : Segment::Attachment.new(upload: upload)
        end
      end

      # The loop lane's placement over its composed message list: every
      # `upload` part whose row the selection cannot carry becomes the line
      # in place; the rest stay. Answers the messages and the DISTINCT rows
      # still placed, first-occurrence order — what the seal binds. A
      # placed id with no row among `uploads` keeps its part: acceptance
      # refuses it typed (`unknown_input_upload`), never silently here.
      def place(messages, uploads, carries: nil)
        rows = uploads.index_by(&:public_id)
        placed = []
        # The composed list is the element union (a message, a call, a
        # result, a marker); only a message carries parts to place.
        rewritten = messages.map do |message|
          case message
          when Nexus::TextInputMessage
            message.with(parts: placed_parts(message.parts, rows, carries, placed))
          else message
          end
        end
        [rewritten, placed.uniq(&:public_id)]
      end

      # One message's parts with every uncarried picture rewritten in
      # place; `placed` collects the rows that stayed native.
      def placed_parts(parts, rows, carries, placed)
        parts.map do |part|
          next part unless part.type == Nexus::InputParts::UPLOAD

          upload = rows[part.upload_public_id]
          reason = upload && carries&.call(upload.content_type)
          if reason
            Nexus::TextInputPart.new(type: Nexus::InputParts::TEXT, text: render(upload, reason))
          else
            placed << upload if upload
            part
          end
        end
      end
    end
  end
end
