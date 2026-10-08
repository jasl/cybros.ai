require "minitest/autorun"
require "minitest/mock"
require "stringio"
require "tmpdir"

load File.expand_path("../../bin/download-tokenizers", __dir__)

class DownloadTokenizersTest < Minitest::Test
  Response = Data.define(:body) do
    def raise_for_status = self
  end

  def setup
    @root = Dir.mktmpdir("tokenizer-download")
    @directory = File.join(@root, "assets")
    @manifest = File.join(@root, "tokenizers.json")
    @tokenizer = Tokenizers::Tokenizer.new(Tokenizers::Models::WordLevel.new(
      vocab: { "[UNK]" => 0, "hello" => 1 }, unk_token: "[UNK]"
    )).to_s
    @license = "Synthetic test license\n"
    write_manifest(@tokenizer)
    @client = Minitest::Mock.new
    @output = StringIO.new
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_installs_loadable_tokenizer_and_license_then_reuses_them_without_network
    expect_downloads
    downloader.call
    @client.verify

    assert_equal [1], Tokenizers.from_file(tokenizer_path).encode("hello").ids
    assert_equal @license, File.read(license_path)
    assert_includes @output.string, "Verified example/tiny"

    # The strict mock has no more calls: both ordinary preparation and the
    # offline check must succeed from the verified local files alone.
    downloader.call
    downloader.call(check: true)
    @client.verify
  end

  def test_checksum_failure_preserves_the_existing_file
    FileUtils.mkdir_p(@directory)
    File.write(tokenizer_path, @tokenizer)
    replacement = @tokenizer.sub("hello", "updated")
    write_manifest(replacement)
    @client.expect(:get, Response.new(body: "incomplete download"), [url("tokenizer.json")])

    error = assert_raises(TokenizerDownloader::Error) { downloader.call }

    assert_includes error.message, "Checksum mismatch"
    assert_equal @tokenizer, File.read(tokenizer_path)
    assert_equal [File.basename(tokenizer_path)], Dir.children(@directory)
    @client.verify
  end

  def test_invalid_tokenizer_is_not_published_even_when_its_checksum_matches
    write_manifest("not a tokenizer")
    @client.expect(:get, Response.new(body: "not a tokenizer"), [url("tokenizer.json")])

    error = assert_raises(TokenizerDownloader::Error) { downloader.call }

    assert_includes error.message, "Cannot load tokenizer"
    assert_empty Dir.children(@directory)
    @client.verify
  end

  def test_offline_check_reports_missing_files_without_creating_or_downloading
    error = assert_raises(TokenizerDownloader::Error) { downloader.call(check: true) }

    assert_includes error.message, "run bin/download-tokenizers"
    refute_path_exists @directory
    @client.verify
  end

  def test_http_failure_preserves_the_existing_file
    FileUtils.mkdir_p(@directory)
    File.write(tokenizer_path, "previous file")
    @client = Object.new
    def @client.get(_url) = raise(HTTPX::TimeoutError.new(60, "download timed out"))

    error = assert_raises(TokenizerDownloader::Error) { downloader.call }

    assert_includes error.message, "example/tiny/tokenizer.json: download timed out"
    assert_equal "previous file", File.read(tokenizer_path)
  end

  private

    def write_manifest(tokenizer)
      File.write(@manifest, JSON.generate([{
        repository: "example/tiny", revision: "a" * 40,
        tokenizer_sha256: Digest::SHA256.hexdigest(tokenizer),
        license: "Test license", license_sha256: Digest::SHA256.hexdigest(@license),
      }]))
    end

    def downloader
      TokenizerDownloader.new(manifest_path: @manifest, directory: @directory, client: @client, output: @output)
    end

    def expect_downloads
      @client.expect(:get, Response.new(body: @tokenizer), [url("tokenizer.json")])
      @client.expect(:get, Response.new(body: @license), [url("LICENSE")])
    end

    def url(filename) = "https://huggingface.co/example/tiny/resolve/#{"a" * 40}/#{filename}"
    def tokenizer_path = File.join(@directory, "example_tiny.json")
    def license_path = File.join(@directory, "example_tiny.LICENSE")
end
