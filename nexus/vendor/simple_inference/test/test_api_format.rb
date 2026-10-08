require "test_helper"

# The format defaults are DATA this gem ships, so they are checked the way
# checked-in data is: every table must be complete enough to build a real
# profile from, and every format must name a protocol this gem adapted.
class TestApiFormat < Minitest::Test
  AF = SimpleInference::ApiFormat

  def test_every_format_names_an_adapted_protocol
    AF::FORMATS.each do |format|
      assert_includes SimpleInference::ApiFormat::PROTOCOL_CLASSES.keys, format,
        "#{format} has defaults but no protocol class"
    end
  end

  def test_every_format_builds_a_profile_from_its_defaults_alone
    AF::FORMATS.each do |format|
      profile = profile_for(format)
      assert_equal format, profile.adapter_profile
      assert_equal AF.workload(format), profile.workload
    end
  end

  # Naming the format names the workload — every shipped wire serves exactly
  # one kind of work, so a catalog entry says neither.
  def test_every_format_declares_the_one_workload_it_serves
    assert_equal AF::FORMATS.sort, AF::WORKLOADS.keys.sort
    AF::WORKLOADS.each_value do |workload|
      assert_includes AF::WORKLOAD_DEADLINE_SECONDS.keys, workload
      assert_includes SimpleInference::ExecutionProfile::WORKLOADS, workload
    end
  end

  def test_a_workload_with_no_deadline_and_a_format_with_no_table_refuse_loudly
    assert_raises(SimpleInference::ConfigurationError) { AF.defaults("no_such_format") }
    assert_raises(SimpleInference::ConfigurationError) { AF.deadline_seconds("no_such_workload") }
    assert_raises(SimpleInference::ConfigurationError) { AF.workload("no_such_format") }
  end

  # The images wire's edit route and the image it takes in are the FORMAT's
  # facts; the codex backend's spelling (json + originator) is a row's.
  def test_the_images_format_states_its_edit_route_and_the_image_it_takes_in
    defaults = AF.defaults("openai_images")

    assert_equal "/v1/images/edits", defaults[:wire_options][:images_edits_path]
    assert_equal "multipart", defaults[:wire_options][:images_edits_encoding]
    refute defaults[:wire_options].key?(:originator), "plain image rows carry no originator"
    assert_equal %w[image/png image/jpeg image/webp], defaults[:input_media].fetch("image").fetch("mime_allowlist")
    refute defaults[:input_media].fetch("image").key?("max_dimension"), "an edit's source is never re-encoded"

    profile = profile_for("openai_images")
    assert_equal %w[image/png image/jpeg image/webp], profile.mime_allowlist("image")
    protocol = AF.protocol_for(profile: profile, config: SimpleInference::Config.new(base_url: "http://example.com"))
    assert_equal %i[images_edits_path images_edits_encoding],
                 SimpleInference::Protocols::OpenAIImages.protocol_option_keys & %i[images_edits_path images_edits_encoding]
    assert_instance_of SimpleInference::Protocols::OpenAIImages, protocol
  end

  # The conservative window a model gets when it declares none — a model
  # nobody measured is never assumed bigger than it is.
  def test_the_default_window_is_conservative
    assert_equal 128_000, AF::DEFAULT_INPUT_TOKENS
    assert AF::WORKLOAD_DEADLINE_SECONDS.values.all? { |s| s.positive? }
  end

  def test_codex_accepts_prompt_images_with_a_local_resize_bound
    profile = profile_for("codex_responses")

    assert_equal %w[image/png image/jpeg image/webp], profile.mime_allowlist("image")
    facts = profile.input_media.fetch("image")
    assert_equal 2048, facts.max_dimension
    assert_nil facts.token_cost, "the resize bound does not declare provider token accounting"
  end

  def test_pdf_is_inline_file_input_only_on_the_adapted_formats
    formats = %w[openai_responses openai_compatible_chat anthropic_messages gemini_generate_content bedrock_converse]
    formats.each do |format|
      profile = profile_for(format)
      facts = profile.input_media.fetch("file")

      assert_equal ["application/pdf"], facts.mime_allowlist, format
      assert_nil facts.max_dimension, "#{format}: PDF bytes are not a raster preview"
      assert_nil facts.token_cost, "#{format}: a file is not a fixed-cost page"
    end
    (AF::FORMATS - formats).each do |format|
      assert_nil profile_for(format).mime_allowlist("file"), format
    end
  end
end
