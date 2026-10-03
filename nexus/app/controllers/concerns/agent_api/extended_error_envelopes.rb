module AgentAPI
  # THE ERROR ENVELOPE'S FOUR EXTENSIONS, in one place. Every refusal is
  # `{error: {code, message}}`; four doors carry one more fact beside the
  # code — where a refused edge word sat, what failed to compile, the
  # revision the loop is at, the conversation a hosted loop's door belongs
  # to — and a caller who branches on the code reads it by name. The table
  # is the contract pack's source (`errors.json#/extended_envelopes`) and
  # the renderer's fence: a door cannot add a member the pack does not
  # publish, nor drop one it does.
  module ExtendedErrorEnvelopes
    extend ActiveSupport::Concern

    MEMBERS = {
      "edge_authoring_refused" => %w[path],
      "invalid_steps" => %w[steps],
      "stale_revision" => %w[current_revision],
      "conversation_hosted" => %w[conversation_public_id turn_public_id],
    }.freeze

    private

      def render_extended_error(code, message, status:, **members)
        published = MEMBERS.fetch(code.to_s)
        unless members.keys.map(&:to_s).sort == published.sort
          raise ArgumentError, "#{code} carries #{published.join(", ")}, not #{members.keys.join(", ")}"
        end

        render json: { error: { code: code, message: message, **members } }, status: status
      end
  end
end
