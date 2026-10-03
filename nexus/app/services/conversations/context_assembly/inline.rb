module Conversations
  class ContextAssembly
    # Fixed text at a position, as a role. The current input is one of
    # these, placed by the kernel; a template's inline blocks are the same primitive.
    class Inline
      class << self
        # `attachments` are the input body's bound rows in part order
        # (`ContentBody#upload_parts`); each rides native or as the index
        # line by `carries` (AttachmentLine). A picture with no words is
        # still a message.
        def call(role:, text:, attachments: [], carries: nil)
          return [] if text.blank? && attachments.empty?

          parts = Segment.text_parts(text.presence) + AttachmentLine.parts(attachments, carries: carries)
          [Segment.plain(role, nil, parts: parts)]
        end
      end
    end
  end
end
