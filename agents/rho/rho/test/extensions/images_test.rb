require "test_helper"

# THE IMAGE TOOL AS AN EXTENSION: one agent-address tool that asks the kernel for an image
# — a InferenceRequest on the `image_generation` workload, on the model the
# settings name (`image_model`, never a hardcoded id), keyed by the call,
# followed under the clamp, its bytes fetched through the SDK's download
# route and written under the environment root as a `files:` capture the
# run uploads, so the image re-enters the transcript. Loaded alone on a
# fresh handle, with a fake member plane that records what was placed.
class ImagesExtensionTest < Minitest::Test
  Images = Rho::Extensions::Images
  ImageGenerate = Images::ImageGenerate
  Imagegen = Images::Imagegen
  Result = Rho::Runner::Result

  PNG = "\x89PNG\r\n\x1a\nfake".b
  MODEL = "dev/mock-image".freeze

  # The member plane a tool reaches: one workspace, one `inference_requests` lane
  # that records the create, answers a scripted sequence of fetches and
  # serves the bytes of the file the result names.
  class Lane
    attr_reader :creates, :fetches, :downloads, :cancels

    def initialize(statuses:, files: [{ index: 0, filename: "os-1-image-output-1", content_type: "image/png" }],
                   create_error: nil, cancel_error: nil, bytes: PNG)
      @statuses = statuses
      @files = files
      @create_error = create_error
      @cancel_error = cancel_error
      @bytes = bytes
      @creates = []
      @fetches = 0
      @downloads = []
      @cancels = []
    end

    def create(**fields)
      raise @create_error if @create_error

      @creates << fields
      CybrosAgent::Api::InferenceRequestsContext::Accepted.new(inference_request: inference_request(@statuses.first), replayed: false)
    end

    def fetch(_public_id)
      @fetches += 1
      inference_request(@statuses[[@fetches, @statuses.length - 1].min])
    end

    def download(public_id, index)
      @downloads << [public_id, index]
      @bytes
    end

    def cancel(public_id)
      @cancels << public_id
      raise @cancel_error if @cancel_error

      inference_request(:canceled)
    end

    private

      def inference_request(status)
        result =
          case status
          when :running then nil
          when :completed then CybrosAgent::Api::InferenceRequestResult.new(
            status: "completed", finish_quality: nil, output_text: nil, usage: nil, timing: nil, error: nil,
            reasoning: nil, output_files: @files.map { |file| CybrosAgent::Api::InferenceRequestFile.new(byte_size: 12, **file) }
          )
          else CybrosAgent::Api::InferenceRequestResult.new(
            status: status.to_s, finish_quality: nil, output_text: nil, usage: nil, timing: nil,
            error: CybrosAgent::Api::InferenceRequestError.new(code: "provider_refused", attempt_budget_spent: true),
            reasoning: nil, output_files: nil
          )
          end
        CybrosAgent::Api::InferenceRequest.new(
          public_id: "os-1", workload: "image_generation", status: result ? result.status : "running",
          model: nil, billing_subject: nil, created_at: nil, updated_at: nil, usage_summary: nil, result: result
        )
      end
  end

  class Uploads
    attr_reader :paths

    def initialize
      @paths = []
    end

    def create(path)
      @paths << path
      CybrosAgent::Api::UploadRef.new(public_id: "up-#{@paths.length}", filename: File.basename(path),
        content_type: "image/png", byte_size: File.size(path))
    end
  end

  class Turns
    attr_reader :queries

    def initialize(items)
      @items = items
      @queries = []
    end

    def list(**query)
      @queries << query
      CybrosAgent::Api::ConversationTurnPage.new(items: @items, before_position: 0, after_position: @items.length - 1)
    end
  end

  Workspace = Data.define(:inference_requests, :turns) do
    def conversation(_public_id) = self
  end

  Client = Struct.new(:lane, :uploads, :turns) do
    def workspace(public_id)
      raise "wrong workspace #{public_id}" unless public_id == "ws-1"

      Workspace.new(inference_requests: lane, turns: turns)
    end
  end

  def setup
    super
    @root = File.realpath(Dir.mktmpdir("rho-images"))
    @sleeps = []
    @lane = nil
    @uploads = Uploads.new
    @turns = Turns.new([])
  end

  def teardown
    FileUtils.remove_entry(@root)
    super
  end

  def config(image_model: MODEL, default_model: nil, adaptations: "auto")
    Rho::Config.from_hash({ "plugins" => { "rho.images" => { "configuration_version" => 1, "configuration" => { "model" => image_model } } },
      "default_model" => default_model, "adaptations" => adaptations }.compact)
  end

  def host(config:, plane: :present, lane: nil, default_workspace: "ws-1")
    Rho::Extensions::Host.new(
      home: RhoTest.host.home, log: nil, clock: -> { Time.now }, config: config, processes: nil,
      member_plane: ->(host_public_id: nil, workspace_public_id: nil) do
        if plane == :present && lane
          Rho::Extensions::MemberPlane.new(client: Client.new(lane, @uploads, @turns),
            workspace_public_id: workspace_public_id || (%w[al-1 conv-1].include?(host_public_id) ? "ws-1" : default_workspace))
        end
      end
    )
  end

  def env = Rho::Runner::ToolEnv.new(root: @root, artifacts_dir: File.join(@root, "artifacts"))

  def bound(statuses: %i[running running completed], plane: :present, config: self.config,
            default_workspace: "ws-1", **lane_fields)
    @lane = Lane.new(statuses: statuses, **lane_fields)
    api = Rho::Extensions::Api.new(host: host(config: config, plane: plane, lane: @lane, default_workspace: default_workspace),
      extension_name: Images::NAME, source: "<test>")
    Images.register(api)
    api.tools.fetch(0).klass.sleeper = ->(seconds) { @sleeps << seconds }
    raise "expected one tool, got #{api.tools.length}" unless api.tools.length == 1

    api.tools.fetch(0).klass.new(env: env)
  end

  def context(run_public_id: "al-1", task: "call_7", conversation: nil, workspace: nil)
    Rho::Runner::ExecutionContext.new(run_public_id: run_public_id, task_key: task, conversation_public_id: conversation,
      workspace_public_id: workspace)
  end

  # No context means no `with`: the test thread carries none, and the
  # signature of `with` takes a context, never nil.
  def call(tool, args = { "prompt" => "a red circle" }, ctx: context)
    return tool.call(args) if ctx.nil?

    Rho::Runner::ExecutionContext.with(ctx) { tool.call(args) }
  end

  def test_images_stay_in_the_original_workspace_when_the_default_changes
    [context, context(run_public_id: "new-turn", conversation: "conv-1"), context(run_public_id: "child-turn", conversation: "unfollowed-child", workspace: "ws-1")].each do |owner|
      tool = bound(default_workspace: "ws-2")

      result = call(tool, ctx: owner)

      refute result.is_error
      assert_equal 1, @lane.creates.length
      assert_equal PNG, File.binread(result.files.fetch(0))
    end
  end

  # The extension ships in the default set, is excluded in runner mode
  # (a runner opens no member plane), and registers exactly one
  # agent-address tool — ONLY when the settings name an image model; the
  # profile it announces is the family's: a write on the open world
  # (one network call, one file), keyed by the call, reconciled by lookup
  # (a replayed key finds the standing InferenceRequest), a five-minute park.
  def test_the_extension_ships_one_agent_tool_gated_on_the_image_model_setting
    assert_includes Rho::Extensions::DEFAULT_EXTENSIONS, Images
    assert_includes Rho::Extensions::RUNNER_MODE_EXCLUDES, Images

    none = Rho::Extensions.load(host: host(config: config(image_model: nil)), extensions: [Images])
    assert_predicate none, :ok?, none.failures.inspect
    assert_empty none.registry.names, "no image_model: the extension registers nothing and announces nothing"
    assert_equal [Images::NAME], none.extensions.map(&:name), "the extension itself is committed"

    loaded = Rho::Extensions.load(host: host(config: config), extensions: [Images])
    assert_predicate loaded, :ok?, loaded.failures.inspect
    assert_equal ["image_generate"], loaded.registry.names
    assert_empty loaded.registry.serving(:runner).names, "the agent's tool, never the runner's"
    entry = loaded.registry.serving(:agent).entries.fetch(0)
    assert_equal ImageGenerate::NAME, entry.name
    assert_equal({ "kind" => "write", "destructive" => false, "effect_scope" => "open",
                   "idempotency" => "keyed", "reconciliation" => "lookup" }, entry.effect_profile)
    assert_equal 300_000, entry.timeout_ms
    assert_equal %w[prompt], entry.schema.fetch("required")
    assert_equal false, entry.schema.fetch("additionalProperties")
    assert_equal ImageGenerate::DESCRIPTION, entry.description
    assert_nil Rho::Runner::Extensions::Tool.prompt_snippet(ImageGenerate), "the description is the one model-facing home"
    refute_includes Rho::RunDeclaration.undeclared, "image_generate", "offered to the model"
  end

  # THE CODEX SPELLING: under a boot row whose tool_style
  # names `codex`, the same tool registers as `imagegen` — rho's own
  # switch on the pack's row, because the kernel's alias grammar takes a
  # KERNEL canonical only (`alias_canonical_unknown` for an executor's
  # tool), so `presets.yml` cannot spell it. Same profile, same schema,
  # the description naming the spelling the model calls.
  def test_the_codex_boot_row_spells_the_tool_imagegen
    loaded = Rho::Extensions.load(host: host(config: config(default_model: "dev/mock-text", adaptations: "codex")),
      extensions: [Images])
    assert_predicate loaded, :ok?, loaded.failures.inspect
    assert_equal ["imagegen"], loaded.registry.names
    entry = loaded.registry.serving(:agent).entries.fetch(0)
    assert_operator entry.klass, :<, Imagegen
    assert_operator Imagegen, :<, ImageGenerate
    assert_equal ImageGenerate::SCHEMA, Imagegen::SCHEMA
    assert_equal ImageGenerate::EFFECT_PROFILE, Imagegen::EFFECT_PROFILE
    assert_equal ImageGenerate::TIMEOUT_MS, Imagegen::TIMEOUT_MS
    assert_equal ImageGenerate::DESCRIPTION.gsub("image_generate", "imagegen"), Imagegen::DESCRIPTION
    assert_equal({ "codex" => "imagegen" }, ImageGenerate::SPELLINGS)

    plain = Rho::Extensions.load(host: host(config: config(default_model: "dev/mock-text", adaptations: "default")),
      extensions: [Images])
    assert_equal ["image_generate"], plain.registry.names, "every other row keeps the plain name"
  end

  def test_the_description_names_the_edit_sources_without_claiming_unavailable_provider_options
    assert_includes ImageGenerate::DESCRIPTION, "referenced_image_paths"
    assert_includes ImageGenerate::DESCRIPTION, "num_last_images_to_include"
    assert_includes ImageGenerate::DESCRIPTION, "not generated tool captures"
    assert_equal %w[prompt referenced_image_paths num_last_images_to_include], ImageGenerate::SCHEMA.fetch("properties").keys
    assert_equal ["prompt"], ImageGenerate::SCHEMA.fetch("required")
  end

  def test_preparing_a_replacement_keeps_the_existing_tools_model_and_member_plane
    original = bound(statuses: [:completed], config: config(image_model: "dev/first-image"))
    original_lane = @lane
    replacement = bound(statuses: [:completed], config: config(image_model: "dev/next-image"))
    replacement_lane = @lane

    call(original)
    assert_equal "dev/first-image", original_lane.creates.fetch(0).fetch(:model)
    assert_empty replacement_lane.creates
    call(replacement)
    assert_equal "dev/next-image", replacement_lane.creates.fetch(0).fetch(:model)
  end

  # One InferenceRequest on the member plane, on the settings' image model, the
  # prompt as the workload's string input, keyed by the call; followed
  # until the result envelope arrived; the one file fetched through the
  # download route and written under the environment root by content
  # type; the answer names the path and captures the file.
  def test_the_handler_places_one_inference_request_downloads_the_file_and_captures_it
    tool = bound
    result = call(tool)

    path = File.join(@root, "generated_images", "call_7.png")
    assert_equal Result.ok("call_7.png: image generated; saved at #{path}", title: "image generated", files: [path]), result
    assert_equal PNG, File.binread(path)
    assert_equal 1, @lane.creates.length
    create = @lane.creates.fetch(0)
    assert_equal "image_generation", create.fetch(:workload)
    assert_equal MODEL, create.fetch(:model)
    assert_equal "a red circle", create.fetch(:input), "the workload's input is the prompt string"
    assert_equal "image_generate:al-1:call_7", create.fetch(:idempotency_key)
    assert_equal 2, @lane.fetches, "followed until the result envelope arrived"
    assert_equal [Rho::InferenceRequestRun::POLL_SECONDS] * 2, @sleeps
    assert_equal [["os-1", 0]], @lane.downloads
    assert_empty @lane.cancels
  end

  def test_local_edit_sources_are_uploaded_in_the_submitted_order
    tool = bound
    paths = %w[first.png second.png].map { |name| File.join(@root, name).tap { |path| File.binwrite(path, PNG) } }
    result = call(tool, { "prompt" => "combine these", "referenced_image_paths" => paths.reverse })

    refute result.is_error
    assert_equal paths.reverse, @uploads.paths
    assert_equal %w[up-1 up-2], @lane.creates.fetch(0).fetch(:upload_public_ids)
    assert_equal "combine these", @lane.creates.fetch(0).fetch(:input)
  end

  def test_recent_images_are_anchored_to_this_execution_and_keep_original_order
    tool = bound(default_workspace: "ws-other")
    @turns = Turns.new([
      image_turn("earlier-run", %w[photo-1 photo-2]),
      image_turn("al-1", %w[photo-3]),
      image_turn("later-run", %w[not-in-this-prompt]),
    ])
    result = call(tool, { "prompt" => "edit the last two", "num_last_images_to_include" => 2 },
      ctx: context(conversation: "conv-1", workspace: "ws-1"))

    refute result.is_error
    assert_equal %w[photo-2 photo-3], @lane.creates.fetch(0).fetch(:upload_public_ids)
    assert_equal [{ before_position: 2_147_483_647, limit: 50 }], @turns.queries
    assert_empty @uploads.paths
  end

  def test_unavailable_or_ambiguous_references_do_not_start_a_generation
    cases = [
      [{ "referenced_image_paths" => ["missing.png"] }, context],
      [{ "referenced_image_paths" => ["missing.png"], "num_last_images_to_include" => 1 }, context],
      [{ "num_last_images_to_include" => 1 }, context],
      [{ "num_last_images_to_include" => 1 }, context(conversation: "conv-1")],
    ]
    cases.each do |arguments, owner|
      tool = bound
      result = call(tool, { "prompt" => "edit" }.merge(arguments), ctx: owner)
      assert result.is_error, arguments.inspect
      assert_empty @lane.creates
      assert_empty @uploads.paths
    end
  end

  def test_recent_images_refuse_a_shortage_instead_of_silently_editing_fewer_pictures
    tool = bound
    @turns = Turns.new([image_turn("al-1", ["photo-1"])])
    result = call(tool, { "prompt" => "combine both", "num_last_images_to_include" => 2 },
      ctx: context(conversation: "conv-1"))

    assert result.is_error
    assert_includes result.content, "not enough recent user image attachments"
    assert_empty @lane.creates
    assert_empty @uploads.paths
  end

  def image_turn(run_id, upload_ids)
    images = upload_ids.map do |id|
      CybrosAgent::Api::UploadRef.new(public_id: id, filename: "#{id}.png", content_type: "image/png", byte_size: PNG.bytesize)
    end
    variant = CybrosAgent::Api::ConversationVariant.new(public_id: "variant-#{run_id}", source: "run",
      status: "running", model: nil, content_preview: nil, content: nil, active: true,
      run_public_id: run_id, attachments: images)
    Data.define(:active_variant).new(active_variant: variant)
  end

  # The extension by content type: jpeg and webp by their types, an
  # unknown type by the filename's own extension, and the InferenceRequest's id
  # names the file when no task key is bound.
  def test_the_file_takes_its_extension_from_the_content_type_and_its_name_from_the_call
    tool = bound(files: [{ index: 2, filename: "os-1-image-output-3", content_type: "image/jpeg" }])
    result = call(tool, ctx: context(task: "k9"))
    assert_equal [File.join(@root, "generated_images", "k9.jpg")], result.files
    assert_equal [["os-1", 2]], @lane.downloads

    tool = bound(files: [{ index: 0, filename: "pic.webp", content_type: "image/webp" }])
    assert_equal [File.join(@root, "generated_images", "k9.webp")], call(tool, ctx: context(task: "k9")).files

    tool = bound(files: [{ index: 0, filename: "out.tiff", content_type: "image/tiff" }])
    assert_equal [File.join(@root, "generated_images", "k9.tiff")], call(tool, ctx: context(task: "k9")).files

    tool = bound
    assert_equal [File.join(@root, "generated_images", "os-1.png")], call(tool, ctx: nil).files,
      "no context: the InferenceRequest's own id"
  end

  # A failed InferenceRequest is DATA the model reads (unlike the summarizer, whose
  # row must fail): the status and the provider's code, no file written.
  def test_a_failed_inference_request_is_an_error_the_model_reads
    tool = bound(statuses: %i[running failed])
    result = call(tool)

    assert_predicate result, :is_error
    assert_equal "image generation failed: provider_refused", result.content
    assert_empty result.files
    refute File.exist?(File.join(@root, "generated_images"))
  end

  def test_a_completed_inference_request_with_no_file_is_an_error_the_model_reads
    tool = bound(files: [])
    result = call(tool)

    assert_predicate result, :is_error
    assert_equal "image generation completed but produced no image", result.content
    assert_empty @lane.downloads
  end

  # THE KERNEL'S REFUSAL, RELAYED: an image model the account's catalog
  # cannot run, or a row that is no image row, is refused at the create
  # under the kernel's own code — the loud refusal, as text the model
  # reads and the log shows.
  def test_a_kernel_refusal_at_the_create_relays_its_code
    tool = bound(create_error: CybrosAgent::Api::InvalidRequest.new("no such model", code: "model_unavailable"))
    result = call(tool)

    assert_predicate result, :is_error
    assert_equal "image generation refused: model_unavailable", result.content
    assert_empty @lane.downloads
  end

  def test_no_member_plane_and_no_model_are_errors_the_model_reads
    tool = bound(plane: :absent)
    result = call(tool)
    assert_predicate result, :is_error
    assert_match(/no member plane/, result.content)
    assert_empty @lane.creates

    empty = Class.new(ImageGenerate)
    empty.bind(member_plane: ->(**) { nil }, model: nil)
    tool = empty.new(env: env)
    empty.bind(member_plane: ->(**) { Rho::Extensions::MemberPlane.new(client: Client.new(Lane.new(statuses: [:completed])), workspace_public_id: "ws-1") },
      model: nil)
    result = call(tool)
    assert_predicate result, :is_error
    assert_equal "no image model: configure the rho.images model", result.content
  end

  # THE CLAMP'S CHECKPOINT: a follow that never finishes ends at the
  # context's cancellation, never at its own patience.
  def test_cancellation_mid_follow_raises_cancelled
    tool = bound(statuses: %i[running running running])
    ctx = context
    tool.class.sleeper = ->(_seconds) { ctx.cancel(:deadline) }

    assert_raises(Rho::Runner::ExecutionContext::Cancelled) { call(tool, ctx: ctx) }
    assert_equal 1, @lane.creates.length
    assert_empty @lane.downloads
    assert_equal ["os-1"], @lane.cancels
  end

  def test_cancel_transport_failure_keeps_the_original_cancellation_and_logs_the_known_locator
    tool = bound(statuses: [:running], cancel_error: CybrosAgent::TransportError.new("unavailable"))
    log = StringIO.new
    tool.class.bind(member_plane: tool.class.member_plane, model: MODEL, log: Rho::Log.new(io: log))
    ctx = context
    tool.class.sleeper = ->(_seconds) { ctx.cancel(:canceled) }

    error = assert_raises(Rho::Runner::ExecutionContext::Cancelled) { call(tool, ctx: ctx) }
    assert_equal :canceled, error.reason
    assert_equal ["os-1"], @lane.cancels
    assert_includes log.string, "event=image.cancel_failed"
    assert_includes log.string, "inference_request=os-1"
    assert_empty @lane.downloads
  end
end
