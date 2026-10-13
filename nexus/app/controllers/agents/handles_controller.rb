# THE STEWARD RENAMES THEIR AGENT: the handle the kernel assigned at
# creation is the steward's to change — an ordinary update under the
# model's one rule set (format, normalization, unique in the account);
# the show page re-renders over its own facts with the field's error.
class Agents::HandlesController < Agents::BaseController
  def update
    handle = params.expect(handle: [:handle])[:handle].to_s
    # Serialize renames so the cooldown and event name the handle actually
    # released, even when another request loaded this profile earlier.
    updated = agent.with_lock { agent.update(handle: handle) }

    if updated
      redirect_to agent_path(agent), notice: t(".updated")
    else
      prepare_show
      render "agents/show", status: :unprocessable_entity
    end
  end
end
