module Rho
  class Core
    # THE CONVERSATION PRIMITIVES: a conversation opened,
    # spoken to, stopped, compacted, and a side opened beside it — each
    # one route, each answering the daemon's document. The wire shapers
    # (`Core.schedule_fields`, `Core.deliver_at_wire`) are the class's own:
    # Ops' `inputs edit` spells the same two fields.
    module Conversations
      # `rho do`/`rho run`: a conversation, and its first
      # turn — `POST /conversations`, the 201 document answered whole (the
      # ids, the model adaptation row, the access, the answerer, the staged attachments, the
      # runner slot, an extension's `until`; or `pending` when the kernel
      # has not materialized the turn within the daemon's bound). The block
      # is where an extension's flags fold into the request
      # (`Extensions::Api#register_flags`): the body goes in, the body comes
      # back. `model` may be nil — the daemon holds the default, and refuses
      # when neither names one.
      # `runner` names the runner-kind executor the turn's tools run on.
      # `restricted` opens with the access default `none`.
      # `agent` names WHO ANSWERS as `@handle` or a public id.
      # `attachments` are PATHS the person typed: checked here
      # before any call — a missing file is refused in one sentence — and
      # posted as they stand on this shell (absolute): the daemon holds the
      # member plane, reads the bytes and stages each as an upload.
      # `upload_public_ids` names uploads already staged by this member;
      # replaying an input keeps those same IDs rather than uploading again.
      # It cannot be combined with local `attachments` paths.
      # `prompt` may be nil: without attachments the PROMPTLESS open sends
      # no `prompt` key at all, and the daemon creates the conversation,
      # follows it and posts no turn — a session is a conversation opened
      # with no turn; the 201 then carries the conversation
      # and the runner slot alone, no turn and no run.
      # `directory` BINDS: it rides as
      # the descriptive `working_directory` AND as the `environment` the
      # daemon validates before the create and records after it — the
      # root, with `directories` as the rest of the root set; with none
      # named, `Dir.pwd` stays descriptive and nothing is bound.
      def open_conversation(prompt: nil, model: nil, instructions: nil, directory: nil, directories: [],
                            runner: nil, restricted: false, agent: nil, attachments: [], upload_public_ids: [], title: nil,
                            idempotency_key: nil, workspace_public_id: nil, memory_context: nil, code_mode: KEEP)
        paths = attachment_paths(attachments)
        uploads = prepared_attachments(upload_public_ids, paths)
        daemon = require_daemon
        # The directory the human was standing in is the one fact this
        # surface has that nothing else does; optional like every
        # environment field.
        body = { "working_directory" => directory || Dir.pwd }
        body["environment"] = { "root" => directory, "directories" => Array(directories) } unless directory.nil?
        body["code_mode"] = code_mode unless KEEP.equal?(code_mode)
        body["prompt"] = prompt unless prompt.nil?
        body["workspace_public_id"] = workspace_public_id unless workspace_public_id.nil?
        body["memory_context"] = memory_context unless memory_context.nil?
        body["title"] = title unless title.nil?
        body["idempotency_key"] = idempotency_key unless idempotency_key.nil?
        body["attachments"] = paths unless paths.empty?
        body["upload_public_ids"] = uploads unless uploads.empty?
        body["model"] = model unless model.nil?
        body["instructions"] = instructions unless instructions.nil?
        body["default_runner_executor_public_id"] = runner unless runner.nil?
        body["access_default"] = "none" if restricted
        body["agent"] = agent unless agent.nil?
        body = yield(body) if block_given?
        response = post(daemon, "/conversations", body, budget: Budget::KERNEL_ROUND_TRIP)
        answer = parse(response)
        return answer if response.code == "201"

        refuse(response, answer, "the daemon refused to open the conversation")
      end

      # The durable listing, including its cursor; followed hosts are a
      # separate, local view. The archived listing is the recycle bin.
      def conversations(after: nil, limit: nil, archived: false)
        query = { "after" => after, "limit" => limit, "archived" => ("1" if archived) }.compact
        path = "/conversations"
        path += "?#{URI.encode_www_form(query)}" unless query.empty?
        response = get(require_daemon, path, budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to list the conversations") unless response.code.to_i == 200

        document
      end

      def conversation(public_id, workspace_public_id: nil)
        query = URI.encode_www_form({ "public_id" => public_id, "workspace_public_id" => workspace_public_id }.compact)
        response = get(require_daemon, "/conversations/detail?#{query}", budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to read the conversation") unless response.code.to_i == 200

        document.fetch("conversation")
      end

      def conversation_code_mode(public_id, workspace_public_id: nil)
        query = URI.encode_www_form({ "public_id" => public_id, "workspace_public_id" => workspace_public_id }.compact)
        response = get(require_daemon, "/conversations/code_mode?#{query}", budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to read code mode") unless response.code.to_i == 200

        document.fetch("code_mode")
      end

      def update_conversation_code_mode(public_id, code_mode:, workspace_public_id: nil)
        body = { "public_id" => public_id, "code_mode" => code_mode }
        body["workspace_public_id"] = workspace_public_id unless workspace_public_id.nil?
        response = patch(require_daemon, "/conversations/code_mode", body, budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to change code mode") unless response.code.to_i == 200

        document.fetch("code_mode")
      end

      def update_conversation(public_id, title:, workspace_public_id: nil)
        response = patch(require_daemon, "/conversations", { "public_id" => public_id, "title" => title, "workspace_public_id" => workspace_public_id }.compact,
          budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to update the conversation") unless response.code.to_i == 200

        document.fetch("conversation")
      end

      def archive_conversation(public_id, workspace_public_id: nil)
        response = post(require_daemon, "/conversations/archive", { "public_id" => public_id, "workspace_public_id" => workspace_public_id }.compact, budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to archive the conversation") unless response.code.to_i == 200

        document.fetch("conversation")
      end

      def unarchive_conversation(public_id, workspace_public_id: nil)
        response = post(require_daemon, "/conversations/unarchive", { "public_id" => public_id, "workspace_public_id" => workspace_public_id }.compact, budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to restore the conversation") unless response.code.to_i == 200

        document.fetch("conversation")
      end

      # ONE verb for every host the daemon follows: `steer`
      # lands at the running turn's next model boundary, `queue` waits for
      # the turn boundary. `to` is WHO ANSWERS the turn, as
      # typed, resolved by the daemon and answered back as `addressed_to`.
      # `attachments` ride a QUEUED turn only — a steer with one is refused
      # here with the kernel's own word before any call.
      # `deliver_at`/`deliver_in` are the
      # kernel's two wire fields through `schedule_fields` — a steer with a
      # time is refused the same way. Explicit `tool_names` preserves the
      # caller's subset, including an empty list, for the target profile's
      # kernel validation. A side permits only further tool narrowing and
      # retains its posture's approval mode. `model` and `approval_mode` are sent
      # as themselves when named: the daemon reads the model ahead of its
      # own resolution and the mode in the kernel's vocabulary (`bypass`,
      # `ask`, `rules`; nil is the profile's word). Answers the 200
      # document: the `input`, the addressee, the staged attachments, the
      # runner slot — and on a conversation the `turn` and `run` the
      # daemon's await answered (or `pending` past its bound).
      def say(public_id, text, mode: "steer", to: nil, attachments: [], upload_public_ids: [], deliver_at: nil, deliver_in: nil,
              model: nil, approval_mode: nil, tool_names: nil, idempotency_key: nil, speaker_public_id: nil, kind: nil, wait: true, workspace_public_id: nil, expected_steering_run_public_id: nil, inline: nil, code_mode: KEEP)
        paths = attachment_paths(attachments)
        uploads = prepared_attachments(upload_public_ids, paths)
        if mode == "steer" && (paths.any? || uploads.any?)
          raise Rho::Error, "attachments_not_steerable: an attachment rides a queued turn, never a steer " \
            "(`--attach` implies `--mode queue`; drop `--mode steer`)"
        end
        schedule = Core.schedule_fields(deliver_at: deliver_at, deliver_in: deliver_in)
        if mode == "steer" && schedule.any?
          raise Rho::Error, "deliver_at_not_steerable: a timed word rides a queued turn, never a steer " \
            "(`--at`/`--in` imply `--mode queue`; drop `--mode steer`)"
        end

        body = { "public_id" => public_id, "text" => text, "delivery_mode" => mode }.merge(schedule)
        body["workspace_public_id"] = workspace_public_id unless workspace_public_id.nil?
        body["to"] = to unless to.nil?
        body["attachments"] = paths unless paths.empty?
        body["upload_public_ids"] = uploads unless uploads.empty?
        body["model"] = model unless model.nil?
        body["approval_mode"] = approval_mode unless approval_mode.nil?
        body["tool_names"] = tool_names unless tool_names.nil?
        body["code_mode"] = code_mode unless KEEP.equal?(code_mode)
        body["idempotency_key"] = idempotency_key unless idempotency_key.nil?
        body["speaker_public_id"] = speaker_public_id unless speaker_public_id.nil?
        body["kind"] = kind unless kind.nil?
        body["expected_steering_run_public_id"] = expected_steering_run_public_id unless expected_steering_run_public_id.nil?
        body["inline"] = inline unless inline.nil?
        body["wait"] = false unless wait
        # The same budget `do` holds: the daemon's materialization wait (30 s)
        # sits inside the two kernel round-trips and the slack.
        response = post(require_daemon, "/say", body, budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        return document if response.code.to_i == 200

        refuse(response, document, "the daemon refused to say it")
      end

      # Forceful by default — stop means stop; `force: false` lets in-flight
      # work finish on a run. A conversation cancels through the kernel;
      # host_type: "run" names an exact run, including an old candidate's.
      # With a task key, ONE branch the model
      # started is canceled and the turn runs on. Answers the `stopped` row
      # (`followed: false` for a child nobody here followed).
      def stop(public_id, task_key = nil, force: true, host_type: "conversation", workspace_public_id: nil)
        body = { "public_id" => public_id, "force" => force, "host_type" => host_type }
        body["workspace_public_id"] = workspace_public_id unless workspace_public_id.nil?
        body["task_key"] = task_key unless task_key.nil?
        response = post(require_daemon, "/stop", body, budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        return document.fetch("stopped") if response.code.to_i == 200

        refuse(response, document, "the daemon refused to stop it")
      end

      # Compact now: the host picks the door — a
      # conversation compacts its running reply's next round, or its
      # history when idle; a standalone run compacts ONE named round.
      # Answers the `compacted` row.
      def compact(public_id, task_key = nil, workspace_public_id: nil)
        body = { "public_id" => public_id, "workspace_public_id" => workspace_public_id }.compact
        body["task_key"] = task_key unless task_key.nil?
        response = post(require_daemon, "/compact", body, budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        return document.fetch("compacted") if response.code.to_i == 200

        refuse(response, document, "the daemon refused to compact it")
      end

      # A SIDE beside the work: the parent's one open side — the
      # newest live conversation, or `parent:` — under the posture `tools`
      # names (`write`: ordinary tools; `read`: rho's read-only set), with
      # `text` as its first word when given. Answers the 200/201 document:
      # `side`, `parent`, `reused`, `lead`.
      def open_side(parent: nil, tools: "write", text: nil, code_mode: KEEP, approval_mode: nil)
        body = { "tools" => tools }
        body["approval_mode"] = approval_mode unless approval_mode.nil?
        body["code_mode"] = code_mode unless KEEP.equal?(code_mode)
        body["parent_public_id"] = parent unless parent.nil?
        body["text"] = text unless text.nil?
        response = post(require_daemon, "/side", body, budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        return document if [200, 201].include?(response.code.to_i)

        refuse(response, document, "the daemon refused to open the side conversation")
      end

      # ---- the conversation's environment ----

      # A field a caller did not name: not sent, so the daemon KEEPS what
      # the record holds (ABSENT = keep; nil and `[]` are the typed clears).
      KEEP = Object.new.freeze

      # THE RECORD READ: `GET /conversations/environment?public_id=` — the
      # id on the query, as rho's GET doors carry ids — answering the
      # `environment` document: the root set, its anchor and source, the
      # row's version and stamp, whether this host can place it, what the
      # row's runner elsewhere was told.
      def conversation_environment(public_id)
        response = get(require_daemon, "/conversations/environment?public_id=#{URI.encode_www_form_component(public_id)}",
          budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to read the conversation's environment") unless response.code.to_i == 200

        document.fetch("environment")
      end

      # THE BIND: `POST /conversations/environment {public_id, root?,
      # directories?, fs?, mcp?}` — a field not named is kept, `root: nil`
      # clears the record, `directories: []` clears the rest of the set,
      # `fs: {url, token, read, write, client}` registers the editor's
      # file-system port under the record's anchor and `fs: nil` drops it,
      # `mcp: [...]` binds the editor's MCP servers (the
      # ACP `mcpServers` list) under the anchor on the agent slot and
      # `mcp: []` closes them; the daemon validates, writes under
      # the store's discipline and relays to a runner elsewhere. Answers
      # the `environment` document after the write.
      def bind_environment(public_id, root: KEEP, directories: KEEP, fs: KEEP, mcp: KEEP)
        body = { "public_id" => public_id }
        body["root"] = root unless KEEP.equal?(root)
        body["directories"] = directories unless KEEP.equal?(directories)
        body["fs"] = fs unless KEEP.equal?(fs)
        body["mcp"] = mcp unless KEEP.equal?(mcp)
        response = post(require_daemon, "/conversations/environment", body, budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to bind the conversation's environment") unless response.code.to_i == 200

        document.fetch("environment")
      end

      # THE LIVE TABLE: `GET /environments`, every followed conversation's
      # record as the daemon holds it now.
      def environments
        response = get(require_daemon, "/environments")
        document = parse(response)
        refuse(response, document, "the daemon refused to list the environments") unless response.code.to_i == 200

        Array(document["environments"])
      end

      private

        def prepared_attachments(upload_public_ids, paths)
          ids = Array(upload_public_ids).map(&:to_s)
          if paths.any? && ids.any?
            raise Rho::Error, "cannot combine attachments paths with upload_public_ids"
          end
          ids
        end

        # Each path as this shell resolves it, refused before any call when
        # it is not a file: the daemon reads the bytes, and its root may
        # not be the directory the person typed in.
        def attachment_paths(attachments)
          Array(attachments).map do |path|
            file = File.expand_path(path.to_s)
            raise Rho::Error, "no such file to attach: #{path}" unless File.file?(file)

            file
          end
        end
    end
  end
end
