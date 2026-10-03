require "fileutils"
require_relative "reference_images"

module Rho
  module Extensions
    module Images
      # THE ONE TOOL: a prompt in, one image out — a OneShot on the member
      # plane followed under the runner's clamp, the file fetched and
      # written under the environment root, captured for the client and
      # named for the model.
      class ImageGenerate
        PLAIN_NAME = "image_generate".freeze
        # The preset word → the spelling a model trained on that reference
        # calls (codex's `imagegen`); every other row keeps the
        # plain name.
        SPELLINGS = { Images::CODEX => "imagegen" }.freeze
        NAME = PLAIN_NAME
        # The familiar imagegen inputs, narrowed to the references rho can
        # resolve: local files or user image attachments on this conversation.
        # Provider options absent from the public workload are not advertised.
        DESCRIPTION_TEMPLATE = <<~TEXT.strip.freeze
          The `%<name>s` tool generates images from descriptions and edits existing images.

          Use it for diagrams, portraits, comics, memes, illustrations, or requested changes to an image.

          Guidelines:
          - %<name>s needs a few minutes to finish.
          - For an edit, use referenced_image_paths when the source images are local files. Inspect them with read first.
          - For recent user image attachments without a local path, use num_last_images_to_include, the smallest number that includes all source images (1 to 5).
          - Recent selection includes user attachments through this execution's turn, not generated tool captures. Use the saved local path for a generated image.
          - Never provide both reference mechanisms. For a new image, omit both.
          - If the required images are unavailable, ask the user to attach them again.
          - Directly generate or edit the image without reconfirmation unless source images are missing.
        TEXT
        DESCRIPTION = format(DESCRIPTION_TEMPLATE, name: NAME).freeze
        # The runner validates this shape before invoking the handler.
        SCHEMA = {
          "type" => "object",
          "properties" => {
            "prompt" => { "type" => "string", "minLength" => 1, "description" => "The image to generate, described as a scene." },
            "referenced_image_paths" => { "type" => "array", "items" => { "type" => "string", "minLength" => 1 },
                                          "minItems" => 1, "description" => "Local source images to edit, in their intended order." },
            "num_last_images_to_include" => { "type" => "integer", "minimum" => 1, "maximum" => 5,
                                              "description" => "How many recent user image attachments to edit, up to this execution's turn." },
          },
          "required" => ["prompt"],
          "additionalProperties" => false,
        }.freeze
        # THE FAMILY: a WRITE on the OPEN world — one network call through
        # the kernel, one file under the root — so no allow row names it
        # (`LoopRequest::APPROVAL_RULES`): it runs under `bypass`, parks
        # under `ask`, is refused under `rules` until a rule allows it.
        # KEYED: the call's key is the OneShot's idempotency key, and a
        # re-run with the same key finds the standing row (`lookup`).
        EFFECT_PROFILE = {
          "kind" => "write", "destructive" => false, "world" => "open",
          "idempotency" => "keyed", "reconciliation" => "lookup",
        }.freeze
        # Five minutes: a generation runs half a minute to a few; the park
        # bounds a dead rho's cost, and stays under the runner's own ceiling.
        TIMEOUT_MS = 300_000
        WORKLOAD = "image_generation".freeze
        # Under the environment root, codex's own directory name
        # (`tool.rs:184-205`), the call's key as the file's name.
        DIRECTORY = "generated_images".freeze
        # The extension the file takes from the download's content type;
        # a type outside the three keeps the kernel's filename extension.
        EXTENSIONS = { "image/png" => ".png", "image/jpeg" => ".jpg", "image/webp" => ".webp" }.freeze

        NO_PLANE = "no member plane: this rho holds no adopted workspace, so it cannot place the image OneShot".freeze
        NO_MODEL = "no image model: settings.json image_model must name one".freeze
        NO_IMAGE = "image generation completed but produced no image".freeze
        REFUSED = "image generation refused: %s".freeze
        FAILED = "image generation %s: %s".freeze

        class << self
          attr_reader :member_plane, :config, :sleeper, :log

          # Bound at registration (the Compaction pattern): the plane
          # callable and the settings; the sleeper is the follow's cadence,
          # injectable so a test does not wait.
          def bind(member_plane:, config:, sleeper: ->(seconds) { sleep(seconds) }, log: nil)
            @member_plane = member_plane
            @config = config
            @sleeper = sleeper
            @log = log
          end

          attr_writer :sleeper

          # The class registered for a boot row's styles: `Imagegen` when
          # one of them owns a spelling, else this one.
          def spelled(styles)
            Array(styles).any? { |word| SPELLINGS.key?(word) } ? Imagegen : self
          end
        end

        def initialize(env:)
          @env = env
        end

        def call(args)
          # The binding is the base class's: a subclass spelling reads it there.
          context = Rho::Runner::ExecutionContext.current
          context&.raise_if_cancelled!
          plane = ImageGenerate.member_plane&.call(host_public_id: context&.conversation_public_id || context&.agent_loop_public_id,
            workspace_public_id: context&.workspace_public_id)
          return Rho::Runner::Result.error(NO_PLANE) if plane.nil?

          model = ImageGenerate.config&.image_model
          return Rho::Runner::Result.error(NO_MODEL) if model.nil?

          lane = plane.client.workspace(plane.workspace_public_id).one_shots
          uploads = ReferenceImages.new(plane: plane, env: @env, context: context).resolve(args)
          context&.raise_if_cancelled!
          accepted = lane.create(workload: WORKLOAD, model: model, input: args.fetch("prompt"),
            idempotency_key: idempotency_key(context), **(uploads.empty? ? {} : { upload_public_ids: uploads }))
          one_shot = follow(lane, accepted.one_shot, context)
          deliver(lane, one_shot, context)
        rescue CybrosAgent::Error => error
          # THE KERNEL'S REFUSAL, RELAYED under its own code — a model the
          # account cannot run, a row that is no image row, a workload the
          # lane refuses — as text the model reads.
          Rho::Runner::Result.error(format(REFUSED, error.code || error.message))
        rescue ArgumentError, Errno::ENOENT, Errno::EACCES => error
          Rho::Runner::Result.error(error.message)
        end

        private

          # THE ROW'S KEY: a transport retry
          # replays the standing OneShot instead of billing twice.
          def idempotency_key(context)
            "#{PLAIN_NAME}:#{context&.agent_loop_public_id}:#{context&.task_key}"
          end

          # Under the clamp's checkpoint: the runner's deadline is the park's
          # minus headroom, and a cancel lands at the next poll.
          def follow(lane, one_shot, context)
            until one_shot.finished?
              context&.raise_if_cancelled!
              ImageGenerate.sleeper.call(Rho::OneShotRun::POLL_SECONDS)
              context&.raise_if_cancelled!
              one_shot = lane.fetch(one_shot.public_id)
            end
            one_shot
          rescue Rho::Runner::ExecutionContext::Cancelled
            cancel(lane, one_shot) unless one_shot.finished?
            raise
          end

          # Only a known accepted run belongs to this call. A failed create
          # has no locator; completed output is already a durable result.
          # Preserve the runner's cancellation even when this best-effort
          # kernel cancellation cannot be confirmed over the network.
          def cancel(lane, one_shot)
            lane.cancel(one_shot.public_id)
          rescue CybrosAgent::Error => error
            ImageGenerate.log&.warn("image.cancel_failed", one_shot: one_shot.public_id, code: error.code)
          end

          # A finished OneShot: failed is DATA the model reads (status and
          # the provider's code); completed with no file likewise; else the
          # first file, fetched and written, captured and named.
          def deliver(lane, one_shot, context)
            result = one_shot.result
            unless result.status == "completed"
              return Rho::Runner::Result.error(format(FAILED, result.status, result.error&.code || "no error code"))
            end

            file = result.files.first
            return Rho::Runner::Result.error(NO_IMAGE) if file.nil?

            path = write(lane.download(one_shot.public_id, file.index), file, context&.task_key || one_shot.public_id)
            Rho::Runner::Result.ok("#{File.basename(path)}: image generated; saved at #{path}",
              title: "image generated", files: [path])
          end

          # `<root>/generated_images/<name><ext>`: the bytes as the kernel
          # stored them (no decoding here), the extension by content type.
          def write(bytes, file, name)
            directory = @env.resolve(DIRECTORY)
            FileUtils.mkdir_p(directory)
            path = File.join(directory, "#{name}#{extension(file)}")
            File.binwrite(path, bytes)
            path
          end

          def extension(file)
            EXTENSIONS.fetch(file.content_type.to_s) { File.extname(file.filename.to_s) }
          end
      end

      # THE CODEX SPELLING of the same tool: the four constants the loader
      # validates on the class itself, the description naming the word the
      # model calls, everything else inherited.
      class Imagegen < ImageGenerate
        NAME = ImageGenerate::SPELLINGS.fetch(Images::CODEX)
        DESCRIPTION = format(ImageGenerate::DESCRIPTION_TEMPLATE, name: NAME).freeze
        SCHEMA = ImageGenerate::SCHEMA
        EFFECT_PROFILE = ImageGenerate::EFFECT_PROFILE
        TIMEOUT_MS = ImageGenerate::TIMEOUT_MS
      end
    end
  end
end
