Rails.application.routes.draw do
  resource :setup, only: [:show, :create]
  resource :session, only: [:new, :create, :destroy]
  # The emailed reset capability travels only in the filtered token
  # query/form parameter, never a route path segment.
  resources :passwords, only: [:new, :create]
  get "passwords/edit" => "passwords#edit", as: :edit_password
  put "passwords" => "passwords#update"

  get "settings" => "settings/profiles#show", as: :settings
  namespace :settings do
    resource :profile, only: [:show, :update]
    resource :email, only: [:show, :update]
    resource :password, only: [:show, :update]
    resources :sessions, only: [:index, :destroy]
    resources :tokens, only: [:index, :create] do
      resource :revocation, only: :create, module: :tokens
    end
  end

  # The member-facing Workspace surface: reads resolve inside effective
  # access, Humans create their own rows and manage them through named resources,
  # and there is no administrator counterpart.
  resources :workspaces, only: [:index, :show, :new, :create, :edit, :update], param: :public_id do
    scope module: :workspaces do
      resource :access_mode, only: :update
      resource :ownership_transfer, only: [:show, :create]
      resource :archival, only: :create
      resource :restoration, only: :create
      resource :deletion, only: :destroy
    end
  end

  # Member-managed connection management (Round D slice 5): a steward governs
  # the agent programs they connected and the runners they manage. There is no
  # administrator counterpart for either.
  resources :agents, only: [:index, :show], param: :public_id do
    scope module: :agents do
      resource :credentials, only: :destroy
      resource :removal, only: :create
      resource :restoration, only: :create
      # THE AGENT'S HANDLE: the kernel assigned it; the steward renames
      # it here, one field, the smallest door.
      resource :handle, only: :update
    end
  end
  resources :runners, only: [:index, :destroy], param: :public_id do
    resource :credentials, only: :destroy, module: :runners
  end

  get "join" => "invitation_acceptances#new", as: :join
  post "join" => "invitation_acceptances#create"

  # THE SESSION DOOR FOR BYTES: the browser's multipart post into the one
  # ingest, beside the member plane's `/agent_api/v1/uploads`.
  resources :uploads, only: :create

  namespace :api do
    namespace :v1 do
      resource :session, only: [:show, :create, :destroy]
      resource :profile, only: :show
      resource :persona, only: [:show, :destroy]
      put "persona", to: "personas#update"
      namespace :admin do
        resources :models, only: :index
        resources :model_providers, only: [:index, :show], format: false, constraints: { id: /[^\/]+/ } do
          scope module: :model_providers do
            resource :authorization, only: [:show, :create, :destroy] do
              resources :sessions, only: :show, controller: "authorization_sessions"
            end
            put "definition", to: "definitions#update", as: :definition
            delete "definition", to: "definitions#destroy"
            put "model_definition", to: "model_definitions#update", as: :model_definition
            delete "model_definition", to: "model_definitions#destroy"
            post "model_definition/reset", to: "model_definitions#reset"
            post "model_discovery", to: "model_discoveries#create"
            post "model_test", to: "model_tests#create"
            put "model_availability", to: "model_availabilities#update"
            put "lane", to: "lanes#update", as: :lane
            put "model_visibility", to: "model_visibilities#update", as: :model_visibility
            put "api_key", to: "api_keys#update", as: :api_key
            delete "api_key", to: "api_keys#destroy"
          end
        end
        resources :users, only: [], param: :public_id do
          scope module: :users do
            resource :removal, only: :create
            # The budget ledger's three doors: open, ADJUST (PATCH, the
            # attributed credit or debit) and the named REVOKE command — every
            # write under an Idempotency-Key.
            resources :budgets, only: :create, param: :public_id do
              patch "", action: :update, on: :member
              scope module: :budgets do
                resource :revocation, only: :create
              end
            end
          end
        end
        # The budget-open path's precondition: the configure-once account
        # cost unit.
        scope module: :accounts do
          resource :account, only: [] do
            get "cost_unit", to: "cost_units#show"
            put "cost_unit", to: "cost_units#update"
            get "retention", to: "retentions#show"
            patch "retention", to: "retentions#update"
          end
        end
        # The statistics consumer over the usage rollups.
        get "model_usage/report", to: "model_usage_reports#show"
      end
    end
  end

  # The agent-facing family: bearer-only, one plane per resource.
  namespace :agent_api do
    namespace :v1 do
      resource :profile, only: :show do
        resources :ingress_speakers, only: :create, controller: "profiles/ingress_speakers"
        # THE PERSON'S OWN DOOR to memory's `user/` scope: the scope
        # follows the acting user's controlling Human, so an agent writes
        # its steward's notes here and reads them from any workspace;
        # `workspace/` and `conversation/` have their own doors. `path`
        # carries a slash (`user/notes.md`), so it rides the body rather
        # than the URL on every verb that names one.
        resources :memory, only: [:index, :create], controller: "profiles/memory" do
          collection do
            post :show, path: "show"
            post :delete, path: "delete"
            resource :grep, only: :create, controller: "profiles/memory/greps"
            resource :edit, only: :create, controller: "profiles/memory/edits"
          end
        end
        # THE PRINCIPAL'S OWN STORE: the ACTING user's row — an agent's is
        # the agent's, not its steward's; no receipt table — a repeat of one
        # (namespace, key) is `key_taken`.
        resources :store_entries, only: [:index, :show, :create, :destroy],
          param: :public_id, controller: "profiles/store_entries" do
          patch "", action: :update, on: :member
        end
        # THE ACTING USER'S OWN SLOTS: an agent profile's `system_prompt`, a
        # Human's `persona`; the workspace's `character` has its own door;
        # PUT is a whole replacement.
        resources :prompt_documents, only: [:index, :show, :destroy],
          param: :slot, controller: "profiles/prompt_documents" do
          put "", action: :update, on: :member
        end
        # THE CALLER'S NAMED DEFINITIONS: the profiles this agent minted
        # under `<its identifier>/<name>`; PUT is a whole replacement by
        # name. The segment is the handle grammar, no format: a dotted
        # or capitalized name is a route miss, never a `format`
        # surprise.
        resources :agents, only: [:index, :destroy], param: :name, format: false,
          constraints: { name: User::Handle::SEGMENT }, controller: "profiles/agents" do
          put "", action: :update, on: :member
        end
      end
      # THE ONE WRITER of the Agent's standing declaration: PUT and
      # never the PATCH twin `resource` would mint, because it is a whole
      # replacement of the block.
      put "profile/configuration", to: "profiles/configurations#update", as: :profile_configuration
      resource :executor, only: :show, controller: "executors/descriptions"
      # THE ONE WRITER of what an executor serves: a whole replacement,
      # PUT and never the PATCH twin, on the executor plane.
      put "executor/announcement", to: "executors/announcements#update", as: :executor_announcement
      # THE INBOX TRANSPORT, the executor plane's alone: the rows addressed
      # to this credential's executor across every live loop — the truth the
      # cable nudge points at — and the claim and commit on one of them. The
      # address is the scope; a workspace never is.
      scope "executor", module: "executors", as: :executor do
        resource :inbox, only: :show, controller: "inbox"
        scope "inbox/:run_public_id/:task_key", as: :inbox, constraints: { task_key: /[^\/]+/ } do
          resource :claim, only: %i[show create]
          resource :commit, only: :create
          resources :operations, only: %i[index create]
          resource :observation, only: :create
          resources :attachments, only: :show, param: :upload_public_id do
            resource :bytes, only: :show, controller: "attachments/bytes"
          end
          # THE CLAIMANT'S EXTENSION: the current claimant moves the one
          # clock, bounded and narrated.
          resource :extend, only: :create
        end
        # THE EPHEMERAL FRAMES an executor posts: one door, the frame's key
        # choosing the fence — a claim's, or the host's binding — broadcast
        # on the host's `progress` feed, stored nowhere.
        resource :progress, only: :create, controller: "progress"
        # THE EXECUTOR PLANE'S CAPTURES: the third door into the one
        # ingest — a capture this executor publishes, staged as its own
        # and named by a `resource_link` in a commit. No `show`.
        resource :uploads, only: :create
      end
      # THE ONE DOOR BYTES COME IN THROUGH, and a sibling of profile rather
      # than a child of a Workspace on purpose: an upload is staged against
      # the (Account, creator) pair — which is exactly the scope
      # `ContentUploads::ResolveReferences` binds from — and only becomes a
      # Workspace's business when a InferenceRequest in that Workspace names it.
      # THE KERNEL'S OWN TOOLS, PUBLISHED. A task declaring one must send
      # BYTE-IDENTICAL bytes — the registry stores wire names and the
      # compile door refuses `kernel_tool_redefined` for a paraphrase,
      # because a second prefix describing a tool that behaves
      # differently is worse than no tool at all. Until this route
      # existed there was no way to obtain those bytes: a client had to
      # transcribe them from the source, and any drift turned into a
      # refusal at authoring time with no way to fix it.
      #
      # Account-level, beside `profile`: which kernel tools exist is not
      # a workspace's fact.
      resources :tools, only: :index do
        collection do
          resource :assembly, only: :create, module: :tools
        end
      end
      # THE MODELS THIS ACCOUNT CAN RUN. Account-level beside `tools` for
      # the same reason: which models exist is not a workspace's fact.
      resources :models, only: :index
      # AUTHORIZED DISCOVERY: the executors the acting principal may
      # address — a runner to bind, a provider whose pool serves it — with
      # what each announced. Account-level, beside `tools` and `models`:
      # which executors exist is not a workspace's fact. Filtered by
      # ELIGIBILITY, never by presence (`last_seen_at`/`presence` are
      # shown, never used to choose). The singular `executor` above is the
      # executor plane's self-read; this plural is the member plane's.
      resources :executors, only: [:index, :show], param: :public_id
      # Read-only account lane discovery; Human administrators manage
      # provider credentials and enablement on the platform API.
      resources :model_providers, only: :index
      resources :uploads, only: [:create, :show], param: :public_id do
        scope module: :uploads do
          # THE ONE BYTES READ: an upload's bytes back out — streamed,
          # `Range`-able — by the upload's own rule: its creator, or a
          # reader of a row that names it (an attachment, a capture, a
          # placed picture, a InferenceRequest's input). A nested singular resource,
          # the InferenceRequest `files` door's shape.
          resource :bytes, only: :show
          # THE TWO NAMED REPRESENTATION READS: the thumbnail and the
          # preview of one upload, presets named in code (never a
          # client-supplied transformation, no `?preset=`), under the
          # same rule as `bytes`; every attachment read carries a strong
          # ETag and honours `If-None-Match`.
          resource :thumbnail, only: :show
          resource :preview, only: :show
        end
      end
      resources :workspaces, only: [:index, :show, :create, :destroy], param: :public_id do
        patch "", action: :update, on: :member
        scope module: :workspaces do
          put "access_mode", to: "access_modes#update", as: :access_mode
          # THE PROVIDER OVERRIDE OPT-IN: a whole replacement of one column, PUT
          # and never a PATCH twin; a workspace
          # administration act with no rho verb — the SDK is its client.
          put "tool_provider_overrides", to: "tool_provider_overrides#update", as: :tool_provider_overrides
          resource :ownership_transfer, only: :create
          resource :archival, only: :create
          resource :restoration, only: :create
          # THE PRINCIPALS LISTING: who may be named on a conversation's
          # access carrier — the members with access here, of either kind
          # — the one user listing the member plane has.
          resources :principals, only: :index
          resources :store_entries, only: [:index, :show, :create, :destroy], param: :public_id do
            patch "", action: :update, on: :member
          end
          # THE ROOM'S CHARACTER: write standing under the dedication
          # fence; a fenced agent reads it and never writes it.
          resources :prompt_documents, only: [:index, :show, :destroy], param: :slot do
            put "", action: :update, on: :member
          end
          # THE ROOM'S OWN MEMORY DOOR: the `workspace/` scope without a
          # conversation — the profile door's shape; write standing on the
          # workspace; the override guard the conversation door shares.
          # `path` rides the body (a slash).
          resources :memory, only: [:index, :create] do
            collection do
              post :show, path: "show"
              post :delete, path: "delete"
              resource :grep, only: :create, controller: "memory/greps"
              resource :edit, only: :create, controller: "memory/edits"
            end
          end
          # One resource carries the workload in the payload. Cancel is a
          # named POST command; DELETE tombstones terminal work.
          resources :inference_requests, only: [:index, :show, :create, :destroy],
            param: :public_id do
            collection do
              resource :input_estimate, only: :create, module: :inference_requests
            end
            scope module: :inference_requests do
              resource :cancellation, only: :create, param: :inference_request_public_id
              resources :events, only: :index
              # A generated image or synthesized audio file, addressed by its
              # ordinal in the result. Outputs remain Active Storage blobs;
              # they have no separate ContentUpload public identifier.
              resources :files, only: :show, param: :index
            end
          end
          resource :conversation_search, only: :show
          # The conversation plane: DELETE is delete intent — the tombstone
          # command — and archive/unarchive are the recycle bin's named POST
          # verbs, never overloads. The default list is the working surface
          # (unarchived, top-level: subagents and the bin each have their
          # own view); `archived` is the bin.
          resources :conversations, only: [:index, :show, :create, :destroy],
            param: :public_id do
            # PATCH alone (the member-patch idiom): `only: :update` would
            # mint a PUT twin the docs never describe, against the family's
            # one-spelling rule (`model_providers` above).
            patch "", action: :update, on: :member
            collection do
              resources :archived, only: :index, module: :conversations, controller: "archived"
            end
            scope module: :conversations do
              resource :history, only: :show
              resource :archive, only: :create
              resource :unarchive, only: :create
              # The subagent followers, reachable only through their parent.
              resources :children, only: :index
              resources :schedules, only: [:index, :show, :create], param: :public_id do
                patch "", action: :update, on: :member
                scope module: :schedules do
                  resource :pause, only: :create
                  resource :resume, only: :create
                  resource :cancel, only: :create
                  resources :executions, only: :index
                end
              end
              # The waiting room's full surface: read the queue, edit while
              # queued (the blocked head's unblock path), give up a row
              # (destroying a steering row IS steer-cancel), exact-set
              # reorder.
              resources :inputs, only: [:index, :create, :destroy],
                param: :public_id do
                patch "", action: :update, on: :member
                collection do
                  resource :reorder, only: :create, module: :inputs
                end
                resource :materialization, only: :show, module: :inputs
              end
              resources :forks, only: :create
              resource :regeneration_receipt, only: :show
              # THE CONVERSATION'S OWN STORE: the client state that forks
              # with it; never read into a prompt.
              resources :store_entries, only: [:index, :show, :create, :destroy],
                param: :public_id do
                patch "", action: :update, on: :member
              end
              # THE HANDOFF: a nested singular resource, PUT and never
              # the PATCH twin `resource` would mint — a whole
              # replacement of one column, the sanctioned rebinding of
              # `runner_executor_id`.
              put "default_runner", to: "default_runners#update", as: :default_runner
              # THE ACCESS CARRIER'S LATER CHANGE: the same shape — PUT, a
              # whole replacement of the default and the named entries, no
              # receipt; the standing is full on the row.
              put "access", to: "accesses#update", as: :access
              # PATCH is the view-state writer (visibility + conceal/
              # restore — the override facade for inherited rows); the
              # variant deck reads and mutates under its turn.
              # Stop the running reply; the invocation terminalizes as
              # canceled and the converger settles the timeline.
              resource :cancellation, only: :create
              # DELETE is the tail's undo verb: the apex — and only the apex
              # — physically removes.
              resources :turns, only: [:index, :show, :destroy], param: :public_id do
                patch "", action: :update, on: :member
                scope module: :turns do
                  # The tail content verbs as named POST commands: edit
                  # replaces content with a new activated candidate;
                  # regenerate asks the same request for a new sample.
                  resource :edit, only: :create, param: :turn_public_id
                  resource :regeneration, only: :create, param: :turn_public_id
                  resources :variants, only: :index, param: :public_id do
                    patch "", action: :update, on: :member
                    scope module: :variants do
                      # THE DEBUG DOOR: the sealed request as sent — the
                      # entries and the request_options — derived from the
                      # sealed body, never re-assembled; a loop-backed variant
                      # answers its first round's.
                      resource :request, only: :show, controller: "sealed_requests"
                      resource :reasoning, only: :show
                      resource :activation, only: :create, param: :variant_public_id
                    end
                  end
                end
              end
              resources :events, only: :index
              resource :context_estimate, only: :create
              resource :memory_context, only: :create
              # COMPACT NOW. The kernel still picks no threshold; this is
              # a caller asking, which the wall-only trigger never left
              # room for.
              resource :compaction, only: :create
              # DURABLE MEMORY, and on this plane it is the ONLY writer:
              # a direct_reply has no tools, so nothing here can call
              # `memory_write`. The assembly block is the reader.
              # `path` carries a slash (`workspace/notes.md`), so it
              # rides the body rather than the URL on every verb that
              # names one.
              resources :memory, only: [:index, :create], controller: "memory" do
                collection do
                  post :show, path: "show"
                  post :delete, path: "delete"
                  resource :grep, only: :create, controller: "memory/greps"
                  resource :edit, only: :create, controller: "memory/edits"
                end
              end
            end
          end
          # The Dynamic-DAG loop's task-grained surface: a loop is created
          # with its seed batch and grows through the one append door —
          # tasks in, never nodes or edges; the graph is read whole on its
          # own route.
          resources :runs, controller: "agent_runs", only: [:index, :show, :create, :destroy],
            param: :public_id do
            scope module: :agent_runs do
              resource :start, only: :create
              resource :pause, only: :create
              resource :resume, only: :create
              resource :stop, only: :create
              # The loop door: the conversation's waiting-room surface,
              # hosted by a standalone loop — the same verbs at the
              # loop's address.
              resources :inputs, only: [:index, :create, :destroy],
                param: :public_id do
                patch "", action: :update, on: :member
                collection do
                  resource :reorder, only: :create, module: :inputs
                end
              end
              resources :events, only: :index
              # THE HANDOFF: a nested singular resource, PUT and never the
              # PATCH twin `resource` would mint — a whole replacement of
              # one column, the sanctioned rebinding of
              # `runner_executor_id`; a loop-backed loop's address answers
              # `conversation_hosted`.
              put "default_runner", to: "default_runners#update", as: :default_runner
              # THE TRANSCRIPT: what a person sees, beside the trace's
              # orchestration view. A window, never a document.
              resource :transcript, only: :show, controller: "transcript"
              # THE PICTURE: nodes, edges and a Mermaid flowchart of the
              # whole run, for debugging, e2e evidence and a UI's drawing.
              resource :graph, only: :show, controller: "graph"
              # HOW FAR ALONG: the authored phases in write order, derived
              # from the receipts and the rows — nothing is stored for it.
              # `phases`, never `progress`: that word is the executor
              # plane's ephemeral feed, and one word has one meaning on
              # the wire.
              resource :phases, only: :show, controller: "phases"
              # `param: :key` so the verbs nested under a task read
              # `:task_key`, the key the model saw.
              resources :tasks, only: [:create, :show], param: :key do
                scope module: :tasks do
                  # THE DEBUG DOOR: the round's sealed request; a task with
                  # none is `request_not_sealed`.
                  resource :request, only: :show, controller: "sealed_requests"
                  resource :resolution, only: :create
                  resource :retry, only: :create
                  resource :abandon, only: :create
                  # THE APPROVER'S VERBS: a row resting at
                  # `needs_approval` is released past the stage or failed
                  # `approval_denied` with the person's reason.
                  resource :approve, only: :create
                  resource :deny, only: :create
                  # CANCEL A BRANCH: work a model started, by the key the
                  # model saw; the mainline's verb stays `stop`.
                  resource :cancel, only: :create
                  # COMPACT NOW, task-grained: the caller names the round
                  # to repair. The kernel still picks no threshold.
                  resource :compact, only: :create
                end
              end
            end
          end
        end
      end
    end
  end

  # OAuth authorization server. /oauth/device is the only wire-stable
  # browser URL; grant/connection routes are private decomposition.
  namespace :oauth do
    get :authorize, to: "authorizations#show"
    post :authorize, to: "authorizations#create"
    post :device_authorization, to: "device_authorizations#create"
    post "device_authorization/cancellation",
      to: "device_authorization_cancellations#create",
      as: :device_authorization_cancellation
    post :token, to: "tokens#create"
    post :revoke, to: "revocations#create"
    resource :device, only: :show, controller: "devices"
    scope :device do
      resource :verification, only: :create, as: :device_verification, controller: "device_verifications"
      resources :grants, only: :show, as: :device_grants, controller: "device_grants" do
        resource :connection, only: :create, controller: "device_connections"
        resource :cancellation, only: :create, controller: "device_cancellations"
      end
    end
  end

  namespace :admin do
    resource :cost_unit, only: [:show, :update]
    resources :model_providers, only: [:index, :show, :new, :create], format: false, constraints: { id: /[^\/]+/ } do
      scope module: :model_providers do
        resource :definition, only: [:show, :update, :destroy]
        resource :model_definition, only: [:new, :show, :create, :update, :destroy]
        resource :model_reset, only: :create
        resource :model_discovery, only: [:show, :create]
        resource :model_test, only: [:show, :create]
        resource :model_availability, only: :update
        resource :lane, only: [:show, :update]
        resource :api_key, only: [:show, :update, :destroy]
        resource :model_visibility, only: [:show, :update]
        resource :authorization, only: [:show, :create, :destroy] do
          resources :sessions, only: :show, controller: "authorization_sessions"
        end
      end
    end
    resource :retention, only: [:show, :update]
    resources :users, only: [:index, :show, :new, :create] do
      scope module: :users do
        resource :role, only: :update
        resource :suspension, only: :create
        resource :activation, only: :create
        resource :removal, only: :create
        resource :restoration, only: :create
        resource :ownership_transfer, only: :create
        resource :steward, only: [:show, :update]
      end
    end
    resources :invitations, only: [:index, :create, :destroy] do
      resource :resend, only: :create, module: :invitations
    end
  end

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "health#show", as: :rails_health_check

  root "dashboard#show"
end
