require "test_helper"

# The reading exists because a runner writes files whose tool result is only
# a path — a screenshot, a spilled bash log, a check's output. What it must
# never do is describe the filesystem it failed to read.
class FilesTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("rho-runner-files")
    File.binwrite(File.join(@root, "shot.png"), "\x89PNG\r\n\x1a\n" + ("x" * 32))
    File.write(File.join(@root, "bash-abc.log"), "hello\n")
  end

  def teardown = FileUtils.remove_entry(@root) if @root && File.directory?(@root)

  def bytes(path, **options) = Rho::Runner::Files.bytes(root: @root, path: path, **options)

  def locate(path) = Rho::Runner::Files.locate(root: @root, path: path)

  # THE PERSON'S NAMING OF A FILE (`files_bytes`): the resolved path, the
  # size, and the type the inline table classifies it as.
  def test_locate_names_the_file_with_its_size_and_classified_type
    located = locate("shot.png")

    assert_kind_of Rho::Runner::Files::Located, located
    assert_equal File.join(@root, "shot.png"), located.path
    assert_equal 40, located.size
    assert_equal "image/png", located.type
    assert_equal "text/plain; charset=utf-8", locate("bash-abc.log").type
    File.write(File.join(@root, "thing.bin"), "\0\1\2")
    assert_equal "application/octet-stream", locate("thing.bin").type, "an unclassified type is an attachment's"
  end

  def test_locate_refuses_with_a_code_and_never_the_filesystem
    missing = locate("nope.png")

    assert_kind_of Rho::Runner::Files::Refusal, missing
    assert_equal [404, "not_found"], [missing.status, missing.code]
    refute_match(/#{Regexp.escape(@root)}|Errno|ENOENT/, missing.message)
    assert_equal "not_a_file", locate(".").code
    assert_equal "path_required", locate("").code
    assert_equal "path_required", locate(nil).code
  end

  def test_a_known_type_is_served_inline_with_its_own_type
    answer = bytes("shot.png")

    assert_predicate answer, :ok?
    assert_equal "image/png", answer.headers.fetch("content-type")
    assert_match(/\Ainline; filename="shot\.png"/, answer.headers.fetch("content-disposition"))
    assert_equal File.binread(File.join(@root, "shot.png")), answer.body
  end

  # The bytes are sniff-proof and never cached; the policy that keeps them
  # from becoming active content is the DAEMON's header, added where the
  # origin is known — this module has no origin to speak of.
  def test_every_served_byte_says_its_type_is_final_and_is_never_cached
    headers = bytes("shot.png").headers

    assert_equal "nosniff", headers.fetch("x-content-type-options")
    assert_equal "private, no-store", headers.fetch("cache-control")
    assert_equal File.size(File.join(@root, "shot.png")).to_s, headers.fetch("content-length")
    refute headers.key?("content-security-policy"), "the policy is the daemon's, not the runner gem's"
  end

  # An unclassified type is handed over rather than rendered.
  def test_an_unclassified_type_is_an_attachment
    File.write(File.join(@root, "thing.bin"), "\0\1\2")

    headers = bytes("thing.bin").headers
    assert_equal "application/octet-stream", headers.fetch("content-type")
    assert_match(/\Aattachment;/, headers.fetch("content-disposition"))
  end

  def test_download_refuses_to_render_even_a_known_type
    assert_match(/\Aattachment;/, bytes("shot.png", download: true)
      .headers.fetch("content-disposition"))
  end

  # Paths resolve the way the tools resolve them, so the panel and the model
  # name the same file.
  def test_a_relative_path_lands_on_the_environment_root_and_an_absolute_one_stands
    assert_predicate bytes("bash-abc.log"), :ok?
    assert_predicate bytes(File.join(@root, "bash-abc.log")), :ok?
  end

  # THE ERRNO NEVER CROSSES. This is the read most likely to touch a private
  # path, and `Errno::EACCES … @ /Users/somebody/vault` is a disclosure with a
  # status code on it.
  def test_a_refusal_names_a_code_and_never_the_filesystem
    missing = bytes("nope.png")

    assert_equal 404, missing.status
    assert_equal "not_found", missing.body.dig(:error, :code)
    refute_match(/#{Regexp.escape(@root)}/, missing.body.dig(:error, :message))
    refute_match(/Errno|ENOENT/, missing.body.dig(:error, :message))
  end

  def test_a_directory_is_not_a_file
    assert_equal 422, bytes(".").status
    assert_equal "not_a_file", bytes(".").body.dig(:error, :code)
  end

  def test_an_empty_path_is_refused_before_anything_is_touched
    assert_equal 400, bytes(nil).status
    assert_equal 400, bytes("").status
  end

  # Inline means the browser renders it, so the cap is a transfer budget —
  # a different question from what a tool result may cost a prompt.
  def test_an_oversized_inline_answer_offers_the_download_instead
    # Sparse, so the real size check runs against a real stat without
    # writing ten megabytes to prove one comparison.
    huge = File.join(@root, "huge.png")
    File.open(huge, "wb") { |file| file.truncate(Rho::Runner::Files::INLINE_MAX_BYTES + 1) }

    answer = bytes("huge.png")
    assert_equal 413, answer.status
    assert_equal "too_large", answer.body.dig(:error, :code)
    assert_match(/download/, answer.body.dig(:error, :message))
    # …and the same file is still yours if you ask for it as one.
    assert_predicate bytes("huge.png", download: true), :ok?
  end
end
