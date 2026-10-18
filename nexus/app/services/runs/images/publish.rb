module Runs
  module Images
    # Provider bytes were validated and stored before invocation completion.
    # Bind those same blobs to UUID-addressed uploads under the result body;
    # pruning invocation detail cannot delete a retained task's output file.
    # ApplyStepResult's status, invocation and generation fences precede this
    # write, and the whole result commits in its existing transaction.
    module Publish
      module_function

      def call(node, invocation)
        uploads = invocation.output_files_attachments.order(:id).includes(:blob).map do |file|
          upload = ContentUpload.new(account: node.account, creating_user: invocation.creating_user)
          upload.file.attach(file.blob)
          upload.save!
          upload
        end
        entries = invocation.content_bodies.find_by(role: "response")&.entry_payloads || []
        entries += uploads.map do |upload|
          { "resource_link" => { "uri" => "nexus://uploads/#{upload.public_id}",
            "name" => upload.filename.to_s, "mimeType" => upload.content_type, "size" => upload.byte_size } }
        end
        result = ContentBodies::Replace.call(owner: node, role: "output", entries: entries, uploads: uploads, seal: true)
        raise "image output was not storable: #{result.refusal}" unless result.accepted?

        StampOutputPreview.call(node)
      end
    end
  end
end
