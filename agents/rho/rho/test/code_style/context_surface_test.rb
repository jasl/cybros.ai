require "test_helper"

# THE FACADE IS THE WHOLE SURFACE. A handler's second argument is the only
# thing an extension holds per request, so what it answers is what an
# extension can reach: pinned here, and grown only with the collaborator
# that backs a verb. `backing_run`
# backs the Ops reads that take a run OR a conversation id off a query
# (`rho request`) — the resolution `run_command` applies to a
# body, exposed once for a GET. `current_conversation_public_id` backs the
# skill verbs' workspace rung: the newest followed
# conversation, the same row `rho side` asks beside. `conversation_model`
# backs `rho prompt preview`: the model `say` would send the next turn on.
class ContextSurfaceTest < Minitest::Test
  # `adaptations` and `lead_hints`: rho's policy over
  # the SDK pack, and the model row's hint lines the standalone author
  # appends to its lead as a conversation turn does.
  # `approval_rules`, `grant`, `grants`: the daemon's
  # ONE rule list as it stands now — the standalone shell reads it — and
  # the session grants the approve verb adds to it and `rho rules` lists.
  # `agent_roster` carries the current named addresses into standalone leads.
  # `list_named_definitions`, `sync_named_definitions`,
  # `remove_named_definition` (named sub-agents): the
  # `rho agents` verbs over the daemon's declare edge and the kernel's door.
  # `listed_followers`: the host owner's interactive listing, excluding
  # background review without exposing another extension's private notes.
  # `environments`: the daemon's environment tables
  # — the conversation door and the set_default_runner verb reach the record, the
  # call_tool and the placement through it.
  SURFACE = %i[
    adaptations adopt_follower agent_roster approval_rules backing_run bearer clock compaction_policy config conversation_bindings conversation_code_mode conversation_model conversation_tool_names
    current_conversation_public_id declare_profile endpoint environment environments
    executor_plane
    failures follow forget grant grants home host_binding host_bindings host_of inventory kernel_tool_configuration
    lead_hints learn_runner list_named_definitions listed_followers live_process_in log
    run_command runs_for member_plane notes own_runner? own_user_public_id page? registry remember
    remote_runner remove_named_definition
    repoint_tools follower runner_selection runner_snapshot followers settings_runner spawn stopping? sync_named_definitions
    tool_env clear_environment_override configure configure_plugin plugin_inventory update_settings refresh_extension manage_packages
  ].sort.freeze

  # `rake rbs` wraps every signed method in a named hook pair; those are the
  # checker's, not the surface.
  def surface
    Rho::Daemon::Context.public_instance_methods(false).grep_v(/__RBS_TEST_/).sort
  end

  def test_the_context_answers_exactly_the_listed_verbs
    assert_equal SURFACE, surface
  end

  # No reader onto anything behind it — not the daemon it delegates to, not
  # the collaborators later steps split out of the daemon.
  def test_nothing_behind_the_context_has_a_reader
    %i[daemon host lineage runs loaded wire].each do |name|
      refute Rho::Daemon::Context.method_defined?(name), "#{name} must not be reachable"
    end
  end
end
