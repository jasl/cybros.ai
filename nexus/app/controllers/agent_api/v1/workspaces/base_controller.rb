# The Workspace family's plumbing: the member plane, the effective-access
# scoped finder whose miss conceals like absence, the bounded lock_version
# caster and the one outcome-to-HTTP mapping.
class AgentAPI::V1::Workspaces::BaseController < AgentAPI::V1::BaseController
  include AgentAPI::KeysetPagination
  include AgentAPI::ExtendedErrorEnvelopes
  include BooleanParameter

  serves_plane :member

  LOCK_VERSION_RANGE = (0..2_147_483_647)

  # Digesting an accepted envelope canonicalizes it before any domain
  # service runs, so the shared numeric limitation surfaces here as the
  # frozen 422, never a 500.
  rescue_from Nexus::CanonicalJson::UnsupportedValue, with: :render_uncarryable_value

  private

    # One frozen 422 for "canonical JSON cannot carry this", with the message
    # naming the limitation actually hit — reporting a NUL byte as an
    # exponent-form number would send the caller to fix the wrong thing.
    def render_uncarryable_value(exception = nil)
      message = case exception
      when Nexus::CanonicalJson::UnsupportedText
        "Text carrying U+0000 or invalid UTF-8 is unsupported"
      else
        "Exponent-form numbers are unsupported; encode the value as a string"
      end

      render_error(:validation_failed, message, status: :unprocessable_entity)
    end

    def acting_user
      current_credential.user
    end

    def current_account
      acting_user.account
    end

    # Show and every command reach browsable rows only: no effective access
    # and tombstones both read as absence before any policy answer.
    def find_browsable_workspace(param = :public_id)
      Workspace.data_accessible_to(acting_user).browsable
        .find_by!(public_id: params.fetch(param))
    end

    # The conversation funnel under a browsable workspace: the ONE funnel
    # — tombstones and a level of `none` both read as absence, the
    # archived bin stays browsable. `param:` names the id's place for the
    # resource's own routes, so there is one funnel, not two.
    def find_listable_conversation(workspace, param: :conversation_public_id)
      Conversation.visible_to(acting_user, workspace: workspace)
        .find_by!(public_id: params.fetch(param))
    end

    # The loop funnel, the LOOP row itself: a loop-backed loop follows its
    # conversation's level (a `none` conversation must not leak through its
    # loop id); a standalone loop keeps the workspace rule. Each reader
    # decides what a loop-backed loop means for it.
    def find_listable_loop(workspace, param: :run_public_id)
      AgentRun.where(workspace_id: workspace.id).listable.readable_by(acting_user)
        .find_by!(public_id: params.fetch(param))
    end

    # WRITES need write standing ON THE HOST: a browsable-but-not-writable
    # caller (an archived-workspace reader, a dedication-fenced agent, a
    # principal a conversation lists at `read`) reads, never writes. One
    # name on every host (Workspace, Conversation, AgentRun), so no door
    # branches on a type; called AFTER the finder, so a concealed row is
    # 404 and never a 403 that admits it exists. The plane's 403, and
    # false so the action returns.
    def authorize_writable(host)
      return true if host.writable_by?(acting_user)

      render_error(:not_authorized,
        "This workspace is not writable by the caller", status: :forbidden)
      false
    end

    # THE ONE IDEMPOTENT RENDERER of the member plane: an executed command
    # answers its response, a replay its receipt — through the caller's
    # current scope where the door names one (`resolve_replay_target`), so
    # a row concealed since is 404 — a mismatch the family's conflict, and
    # a refusal the one map (`render_refused`).
    def render_idempotent_outcome(outcome, &resolve_replay_target)
      case outcome.outcome
      when :executed
        response.set_header("Idempotency-Replayed", "false")
        render json: outcome.response.body, status: outcome.response.status
      when :replayed
        if resolve_replay_target.nil? || resolve_replay_target.call(outcome.receipt)
          response.set_header("Idempotency-Replayed", "true")
          render json: outcome.receipt.response_body, status: outcome.receipt.response_status
        else
          render_not_found
        end
      when :mismatched
        render_refusal(:idempotency_envelope_mismatch)
      when :refused
        render_refused(outcome.refusal)
      else
        raise "unmapped idempotent outcome: #{outcome.outcome}"
      end
    end

    # A service's refusal result: `invalid` carries the record's errors,
    # every other outcome is a code the map renders.
    def render_refused(refusal)
      if refusal.outcome == :invalid
        render_domain_invalid(refusal.errors)
      else
        render_refusal(refusal.outcome)
      end
    end

    def lock_version_from(container)
      bounded_integer(container[:lock_version], :lock_version, range: LOCK_VERSION_RANGE)
    end

    # Explicit JSON null is not omission: non-null fields reject it before any
    # digest or domain call, from the parsed body because Strong Parameters
    # drops a null for hash-shaped fields.
    def reject_explicit_nulls(root, fields)
      # The parsed body, whatever its content type — the same body Strong
      # Parameters read, so the two halves of the boundary cannot disagree.
      container = request.request_parameters[root.to_s]
      case container
      when Hash
        fields.each do |field|
          if container.key?(field.to_s) && container[field.to_s].nil?
            render_error(
              :validation_failed, "#{field} cannot be null", status: :unprocessable_entity
            )
            return false
          end
        end
        true
      else
        true
      end
    end

    # Absence is a real answer (no receipt written), but a key the caller did
    # send must fit the receipt column: 400 at the boundary, never a 500 later.
    def optional_idempotency_key(max_bytes: WorkspaceCommandReceipt::IDEMPOTENCY_KEY_MAX_BYTES)
      key = request.headers["Idempotency-Key"]
      return nil if key.blank?
      raise APIErrors::ParameterInvalid, :idempotency_key if key.bytesize > max_bytes

      key
    end

    def required_idempotency_key
      key = request.headers["Idempotency-Key"]
      if key.blank?
        render_error(:idempotency_key_required, "Idempotency-Key header is required", status: :bad_request)
        nil
      elsif key.bytesize > WorkspaceCommandReceipt::IDEMPOTENCY_KEY_MAX_BYTES
        raise APIErrors::ParameterInvalid, :idempotency_key
      else
        key
      end
    end

    # Post-commit, best-effort: completion usually lands before the next read
    # while the recurring sweep owns correctness. After the render, so the
    # response reports the acceptance state.
    def complete_transition_after(result)
      if result.outcome == :accepted
        ::Workspaces::CompleteTransition.call(workspace: result.workspace)
      end
    end

    def render_workspace_result(result)
      case result.outcome
      when :created
        render json: { workspace: AgentAPI::WorkspacePresenter.full(result.workspace) }, status: :created
      when :updated, :transferred, :accepted, :state_already_current
        render json: { workspace: AgentAPI::WorkspacePresenter.full(result.workspace) }
      else
        render_refused(result)
      end
    end

    def render_domain_invalid(errors)
      if errors.any? { |error| error.type == Nexus::SizeBounds::REJECTION }
        render_error(:content_too_large, "Content exceeds its size bound", status: :content_too_large)
      elsif (macro = errors.find { |error| error.type == :macro_unknown })
        # An inline slot override refuses a macro the way the slot door
        # does: the same code, the word in the message.
        render_refusal(:prompt_document_macro_unknown, detail: macro.options[:name])
      else
        render_error(:validation_failed, errors.full_messages.to_sentence, status: :unprocessable_entity)
      end
    end
end
