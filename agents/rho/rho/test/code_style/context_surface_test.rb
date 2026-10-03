require "test_helper"

# THE FACADE IS THE WHOLE SURFACE. A handler's second argument is the only
# thing an extension holds per request, so what it answers is what an
# extension can reach: pinned here, and grown only with the collaborator
# that backs a verb. `backing_loop`
# backs the Ops reads that take a loop OR a conversation id off a query
# (`rho request`) — the resolution `loop_command` applies to a
# body, exposed once for a GET. `current_conversation_public_id` backs the
# skill verbs' workspace rung: the newest followed
# conversation, the same row `rho btw` asks beside. `conversation_model`
# backs `rho prompt preview`: the model `say` would send the next turn on.
class ContextSurfaceTest < Minitest::Test
  # `adaptations` and `lead_hints`: rho's policy over
  # the SDK pack, and the model row's hint lines the standalone author
  # appends to its lead as a conversation turn does.
  # `approval_rules`, `grant`, `grants`: the daemon's
  # ONE rule list as it stands now — the standalone shell reads it — and
  # the session grants the approve verb adds to it and `rho rules` lists.
  # `list_named_definitions`, `sync_named_definitions`,
  # `remove_named_definition` (named sub-agents): the
  # `rho agents` verbs over the daemon's declare edge and the kernel's door.
  # `environments`: the daemon's environment tables
  # — the conversation door and the handoff verb reach the record, the
  # relay and the placement through it.
  SURFACE = %i[
    adaptations adopt_run approval_rules backing_loop bearer clock compaction_policy config conversation_bindings conversation_model
    current_conversation_public_id declaration_conflicts declare_union endpoint environment environments
    executor_plane
    failures follow forget grant grants home host_binding host_bindings host_of inventory kernel_tool_definitions
    lead_hints learn_runner list_named_definitions live_process_in log
    loop_command loops_for member_plane notes own_runner? own_user_public_id page? registry remember
    remote_runner remove_named_definition
    repoint_tools run runner_selection runner_snapshot runs settings_runner spawn stopping? sync_named_definitions
    tool_env
  ].freeze

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
    %i[daemon host lineage loops loaded wire].each do |name|
      refute Rho::Daemon::Context.method_defined?(name), "#{name} must not be reachable"
    end
  end
end
