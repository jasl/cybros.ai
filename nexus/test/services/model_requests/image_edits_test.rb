require "test_helper"
require "zlib"

class ModelRequests::ImageEditsTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @creator = users(:member)
    DevModelLane.ensure_enabled!(@account)
    snapshot = ModelCatalog.current
    model = snapshot.models.fetch("dev/mock-image")
    image_model = model.merge("capabilities" => model.fetch("capabilities").merge("input_modalities" => ["image"]))
    @catalog = snapshot.with(models: snapshot.models.merge("dev/mock-image" => image_model))
    @profile = ModelCatalog::ProfileBuilder.call(
      model_ref: "dev/mock-image", provider: @catalog.providers.fetch("dev"), model: image_model
    )
    @first_bytes = png_bytes(255, 0, 0)
    @second_bytes = png_bytes(0, 0, 255)
    @first = upload(@first_bytes)
    @second = upload(@second_bytes)
  end

  test "image edits preserve submitted reference order after cold loading and rebuilding" do
    invocation_id = create_edit([@second.public_id, @first.public_id])

    2.times do
      assert_equal [@second_bytes, @first_bytes], compiled_images(invocation_id),
        "the first and second source images are part of the accepted request"
    end
  end

  test "image edits preserve each submitted occurrence while sharing upload liveness" do
    invocation_id = create_edit([@second.public_id, @first.public_id, @second.public_id])
    invocation = ModelInvocation.find(invocation_id)
    assert_equal 2, invocation.content_bodies.find_by!(role: "request").content_body_uploads.count

    2.times do
      assert_equal [@second_bytes, @first_bytes, @second_bytes], compiled_images(invocation_id),
        "deduplicated storage references must not deduplicate the provider input"
    end
  end

  private

    def create_edit(upload_public_ids)
      command = OneShots::Create::Command.new(
        workspace: workspaces(:shared), creating_user: @creator, workload: "image_generation",
        submitted: DevModelLane.submission_for("image_generation"), configuration: {},
        input: "Use the first image as the subject and the second image as the background.",
        upload_public_ids: upload_public_ids, billing_subject: nil, idempotency_key: SecureRandom.uuid_v7
      )
      result = ModelCatalog.stub(:current, @catalog) do
        OneShots::Create.call(command: command, port: DevModelLane.port)
      end
      assert_predicate result, :created?, result.refusal.inspect
      one_shot = OneShot.find_by!(public_id: result.accepted.fetch("one_shot_public_id"))
      invocation = one_shot.model_invocation
      [one_shot.content_bodies.find_by!(role: "input"), invocation.content_bodies.find_by!(role: "request")].each do |body|
        assert_predicate body, :sealed?
        assert_equal command.input, body.readable_text
        assert_equal upload_public_ids, body.upload_parts.map(&:public_id)
      end
      invocation.id
    end

    def compiled_images(invocation_id)
      built = ModelRequests::Build.call(
        invocation: ModelInvocation.find(invocation_id), profile: @profile,
        base_url: "http://example.test", host: "solid_queue"
      )
      assert_predicate built, :built?, built.refusal.inspect
      assert_equal "/v1/images/edits", built.request.path
      boundary = built.request.headers.fetch("Content-Type").split("boundary=").last
      built.request.payload.to_s.split("--#{boundary}".b).drop(1).filter_map do |part|
        headers, bytes = part.split("\r\n\r\n".b, 2)
        bytes.delete_suffix("\r\n".b) if headers.include?(%(name="image[]"))
      end
    end

    def upload(bytes)
      @account.content_uploads.create!(
        creating_user: @creator,
        file: ActiveStorage::Blob.create_and_upload!(
          io: StringIO.new(bytes), filename: "pixel.png", content_type: "image/png"
        )
      )
    end

    def png_bytes(red, green, blue)
      "\x89PNG\r\n\x1a\n".b +
        png_chunk("IHDR", [1, 1, 8, 2, 0, 0, 0].pack("NNC5")) +
        png_chunk("IDAT", Zlib::Deflate.deflate([0, red, green, blue].pack("C4"))) +
        png_chunk("IEND", "".b)
    end

    def png_chunk(type, bytes)
      [bytes.bytesize].pack("N") + type + bytes + [Zlib.crc32(type + bytes)].pack("N")
    end
end
