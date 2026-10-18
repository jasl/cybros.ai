require "test_helper"

# Active Storage draws no routes here (`config.active_storage.draw_routes =
# false`). The framework's direct-upload endpoints accept anonymous blob
# writes and its read routes are public bearer URLs; nothing in the app
# mints a signed-id URL, and the only ingest is the member plane's multipart
# door. The refusal is the framework switch, not a controller answering 403.
class ActiveStorageRoutesTest < ActionDispatch::IntegrationTest
  test "the framework draws no routes" do
    assert_not ActiveStorage.draw_routes
    assert_not defined?(ActiveStorageUploadsController),
      "the refusal lives in configuration, not a controller"
  end

  test "direct and disk uploads do not resolve" do
    assert_no_difference "ActiveStorage::Blob.count" do
      post "#{ActiveStorage.routes_prefix}/direct_uploads",
        params: { blob: { filename: "x", byte_size: 1, checksum: "x", content_type: "text/plain" } }
      assert_response :not_found
    end

    put "#{ActiveStorage.routes_prefix}/disk/token"
    assert_response :not_found
  end

  test "the public read routes do not resolve" do
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("server-created content"),
      filename: "sample.txt",
      content_type: "text/plain"
    )

    assert_not_respond_to self, :rails_blob_path
    assert_not_respond_to self, :rails_storage_proxy_path

    get "#{ActiveStorage.routes_prefix}/blobs/redirect/#{blob.signed_id}/sample.txt"
    assert_response :not_found

    get "#{ActiveStorage.routes_prefix}/blobs/proxy/#{blob.signed_id}/sample.txt"
    assert_response :not_found
  ensure
    blob&.purge
  end
end
