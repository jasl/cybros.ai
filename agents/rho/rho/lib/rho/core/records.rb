module Rho
  class Core
    # THE RECORD PRIMITIVES: a host's input queue, a conversation's access
    # carrier, the prompt family, the rewind/regenerate/variant doors,
    # the skills on their two rungs, and an upload's bytes — the Ops
    # extension's record routes, each one capability over one route.
    module Records
      def search_conversations(query:, after: nil, limit: nil, archived: nil, workspace_public_id: nil)
        params = { "query" => query, "after" => after, "limit" => limit,
          "archived" => archived, "workspace_public_id" => workspace_public_id }.compact
        response = get(require_daemon, "/conversations/search?#{URI.encode_www_form(params)}", budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to search conversations") unless response.code.to_i == 200

        document
      end

      def history(public_id, before_position: nil, after_position: nil, limit: nil, workspace_public_id: nil)
        params = { "public_id" => public_id, "before_position" => before_position, "after_position" => after_position,
          "limit" => limit, "workspace_public_id" => workspace_public_id }.compact
        response = get(require_daemon, "/conversations/history?#{URI.encode_www_form(params)}", budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to read history") unless response.code.to_i == 200

        document
      end

      def edit_turn(public_id, turn, text:, workspace_public_id: nil)
        history_verb("edit", public_id, turn, { "text" => text, "workspace_public_id" => workspace_public_id }.compact).fetch("variant")
      end

      def delete_turn(public_id, turn, workspace_public_id: nil)
        history_verb("delete", public_id, turn, { "workspace_public_id" => workspace_public_id }.compact).fetch("deleted")
      end

      def turn_view_state(public_id, turn, visibility: nil, concealed: nil, workspace_public_id: nil)
        history_verb("view", public_id, turn,
          { "visibility" => visibility, "concealed" => concealed, "workspace_public_id" => workspace_public_id }.compact).fetch("turn")
      end

      # THE QUEUE: a followed host's rows, so a person can find the
      # one the kernel parked.
      def inputs(public_id, host_type: nil, workspace_public_id: nil)
        query = URI.encode_www_form({ "public_id" => public_id, "host_type" => host_type,
          "workspace_public_id" => workspace_public_id }.compact)
        response = get(require_daemon, "/inputs?#{query}", budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to read the inputs") if document.key?("error")

        Array(document["inputs"])
      end

      def delete_input(public_id, input_public_id, host_type: nil, workspace_public_id: nil)
        input_verb("delete", { "public_id" => public_id, "input_public_id" => input_public_id,
          "host_type" => host_type, "workspace_public_id" => workspace_public_id }.compact,
          "the daemon refused to remove the input")
      end

      # The unblock path: the row rewritten — its `text`, and the kernel's
      # schedule fields (`schedule_fields`'s answer, or `deliver_in: "0s"`
      # for `--now`). Answers the `input` row.
      def update_input(public_id, input_public_id, text: nil, schedule: {}, delivery_mode: nil, host_type: nil, workspace_public_id: nil)
        body = { "public_id" => public_id, "input_public_id" => input_public_id,
          "host_type" => host_type, "workspace_public_id" => workspace_public_id }.compact
        body["text"] = text unless text.to_s.strip.empty?
        body["delivery_mode"] = delivery_mode if delivery_mode
        input_verb("update", body.merge(schedule), "the daemon refused to edit the input").fetch("input")
      end

      # WHO MAY SEE A CONVERSATION: the carrier as it stands.
      def access(public_id) = replace_access(public_id, nil)

      # One re-cut of the carrier — `{ "op" => add|rm|default, "principal",
      # "level" }` — over ONE route, a whole replacement of the kernel's
      # carrier with the read-modify-write done by the daemon; two racing
      # adds keep one. Answers the `access` document.
      def replace_access(public_id, change)
        body = { "public_id" => public_id }
        body["change"] = change unless change.nil?
        response = put(require_daemon, "/conversations/access", body, budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        return document.fetch("access") if response.code.to_i == 200

        refuse(response, document, "the daemon refused to change who may see the conversation")
      end

      # THE PROMPT ESTIMATE: what a send of these words would
      # seal, under the addressee named; the `preview` document.
      def prompt_preview(public_id, model: nil, prompt: nil, to: nil, variables: {}, template: nil, workspace_public_id: nil)
        body = { "public_id" => public_id, "workspace_public_id" => workspace_public_id }.compact
        body["model"] = model unless model.to_s.empty?
        body["prompt"] = prompt unless prompt.nil?
        body["to"] = to unless to.to_s.empty?
        body["variables"] = variables unless variables.empty?
        body["template"] = template unless template.nil?
        response = post(require_daemon, "/conversations/prompt_preview", body, budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to preview the prompt") if document.key?("error")

        document.fetch("preview")
      end

      # Rho's own prompt slots: every slot (`prompt_documents`), or one
      # (`prompt_document`) when named.
      def prompt_documents(slot: nil)
        path = "/prompt/documents"
        path += "?#{URI.encode_www_form("slot" => slot)}" unless slot.to_s.empty?
        response = get(require_daemon, path, budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to read the prompt documents") if document.key?("error")

        document
      end

      # A rewind or a regenerate may run two request runs back to back (a
      # checkpoints consult, then the restore); each is bound by the
      # runner's `checkpoint_restore` park (120 s), the sweep and the kernel
      # round-trips behind it.
      REWIND_CEILING_MS = 130_000

      # REWIND: branch a conversation at a turn and put the files
      # back to that point; the `rewind` document (the child, `forked_from`,
      # `position`, the `restoration` outcome).
      def rewind(public_id, turn, keep_checkpoints: false, title: nil, idempotency_key: nil, workspace_public_id: nil)
        body = { "public_id" => public_id, "turn" => turn, "keep_checkpoints" => keep_checkpoints,
          "idempotency_key" => idempotency_key, "workspace_public_id" => workspace_public_id }.compact
        body["title"] = title unless title.nil?
        response = post(require_daemon, "/conversations/rewind", body, budget: Budget.for_tool_call(REWIND_CEILING_MS))
        document = parse(response)
        refuse(response, document, "the daemon refused to rewind") unless response.code.to_i == 200

        document.fetch("rewind")
      end

      # REGENERATE: re-do a run-backed tail turn's reply,
      # restoring Runner checkpoints it changed first; the `regenerate` document
      # (`turn`, `variant`, the `restoration` outcome with `door_refused`).
      def regenerate(public_id, turn, idempotency_key:, keep_checkpoints: false, model: nil, workspace_public_id: nil)
        body = { "public_id" => public_id, "turn" => turn, "idempotency_key" => idempotency_key,
          "keep_checkpoints" => keep_checkpoints, "workspace_public_id" => workspace_public_id }.compact
        body["model"] = model unless model.nil?
        response = post(require_daemon, "/conversations/regenerate", body, budget: Budget.for_tool_call(REWIND_CEILING_MS))
        document = parse(response)
        refuse(response, document, "the daemon refused to regenerate") unless response.code.to_i == 200

        document.fetch("regenerate")
      end

      # THE REPLAY'S MAINLINE: a conversation's
      # turns in position order, off ONE `GET /conversations/turns` — the
      # daemon pages the kernel's window to the end under its cap. The
      # document: `turns` (per turn the id, position, kind, role, status, origin,
      # `inherited` history marker, and the active variant's content, run and source — and on a reply turn `prompt_text`, the words that opened it) and
      # `pagination` (`after_position`, the last position read — the next
      # call's window — and `has_more`). `after_position`/`limit` ride the
      # query as typed. `latest` or `before_position` selects one reverse
      # window instead; its pagination names `before_position` and
      # `has_older`, and the returned turns remain in position order.
      def turns(public_id, after_position: nil, before_position: nil, latest: false, limit: nil, workspace_public_id: nil)
        query = { "public_id" => public_id }
        query["workspace_public_id"] = workspace_public_id unless workspace_public_id.nil?
        query["after_position"] = after_position.to_s unless after_position.nil?
        query["before_position"] = before_position.to_s unless before_position.nil?
        query["latest"] = "1" if latest
        query["limit"] = limit.to_s unless limit.nil?
        response = get(require_daemon, "/conversations/turns?#{URI.encode_www_form(query)}", budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to read the turns") if document.key?("error")

        document
      end

      # The turn's deck: each live candidate's row.
      def variants(public_id, turn, workspace_public_id: nil)
        query = URI.encode_www_form({ "public_id" => public_id, "turn" => turn, "workspace_public_id" => workspace_public_id }.compact)
        response = get(require_daemon, "/conversations/variants?#{query}", budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to read the variants") if document.key?("error")

        Array(document["variants"])
      end

      # Choose the turn's rendered candidate through the kernel's activation door.
      def activate_variant(public_id, turn, variant_id, workspace_public_id: nil)
        body = { "public_id" => public_id, "turn" => turn, "variant" => variant_id, "workspace_public_id" => workspace_public_id }.compact
        response = post(require_daemon, "/conversations/activate", body, budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to activate the variant") unless response.code.to_i == 200

        document.fetch("variant")
      end

      # The kernel's view-state door on one candidate: concealed, or
      # restored; the `variant` row written.
      def variant(public_id, turn, variant_id, concealed:, workspace_public_id: nil)
        body = { "public_id" => public_id, "turn" => turn, "variant" => variant_id, "concealed" => concealed, "workspace_public_id" => workspace_public_id }.compact
        response = post(require_daemon, "/conversations/variant", body, budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to write the variant") unless response.code.to_i == 200

        document.fetch("variant")
      end

      # SKILLS: the rows on the two rungs (`user`,
      # `workspace`) and what this daemon's runner announces (`project`).
      def skills
        response = get(require_daemon, "/skills", budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to read the skills") if document.key?("error")

        document.fetch("skills")
      end

      # One skill onto a rung, as the runner's own parser split it; the
      # `memory` row written (201).
      def push_skill(name:, description:, content:, scope:, expected_public_id:, expected_lock_version:)
        body = { "scope" => scope, "name" => name, "description" => description, "content" => content,
                 "expected_public_id" => expected_public_id, "expected_lock_version" => expected_lock_version }
        response = post(require_daemon, "/skills/push", body, budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to push the skill") unless response.code.to_i == 201

        document.fetch("memory")
      end

      def show_skill(name, scope:)
        query = URI.encode_www_form("scope" => scope, "name" => name)
        response = get(require_daemon, "/skills/show?#{query}", budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to show the skill") if document.key?("error")

        document.fetch("memory")
      end

      # Delete only the observed document; a changed or recreated row
      # returns the kernel's stale_object conflict. No read or retry here.
      def remove_skill(name, scope:, expected_public_id:, expected_lock_version:)
        body = { "scope" => scope, "name" => name,
                 "expected_public_id" => expected_public_id, "expected_lock_version" => expected_lock_version }
        response = post(require_daemon, "/skills/rm", body,
          budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to remove the skill") unless response.code.to_i == 200

        document.fetch("deleted")
      end

      # The bytes a `resource_link` named, whole: the daemon
      # fetches them on the member plane. `kind` is `bytes`, `thumbnail`
      # or `preview`. Answers a binary string.
      def upload_bytes(public_id, kind: "bytes")
        query = URI.encode_www_form("public_id" => public_id, "kind" => kind)
        response = get(require_daemon, "/uploads/bytes?#{query}", budget: Budget::KERNEL_ROUND_TRIP)
        refuse(response, parse(response), "the daemon refused to read the upload") unless response.code.to_i == 200

        response.body.to_s.b
      end

      private

        def history_verb(verb, public_id, turn, fields)
          response = post(require_daemon, "/conversations/turns/#{verb}",
            { "public_id" => public_id, "turn" => turn }.merge(fields), budget: Budget::KERNEL_ROUND_TRIP)
          document = parse(response)
          refuse(response, document, "the daemon refused to change history") unless response.code.to_i == 200

          document
        end

        def input_verb(verb, body, refusal)
          response = post(require_daemon, "/inputs/#{verb}", body, budget: Budget::KERNEL_ROUND_TRIP)
          document = parse(response)
          return document if response.code.to_i == 200

          refuse(response, document, refusal)
        end
    end
  end
end
