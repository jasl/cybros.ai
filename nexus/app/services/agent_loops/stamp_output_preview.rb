module AgentLoops
  # The preview and true size are stamped the moment the body lands, so
  # every transcript read is a pure row query — loading a thousand bodies
  # to slice previews costs the same as sending them. `task_detail` is the full door.
  module StampOutputPreview
    LIMIT = 280

    module_function

    def call(node)
      text = node.content_bodies.find_by(role: "output")&.effective_text
      return if text.nil?

      node.update_columns(
        output_preview: text.first(LIMIT),
        output_size_bytes: text.bytesize
      )
    end
  end
end
