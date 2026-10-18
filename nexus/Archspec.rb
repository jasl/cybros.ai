# Nexus follows a layered core while keeping Rails delivery adapters explicit.
# Models and services may enqueue jobs; jobs are asynchronous delivery
# entrypoints, not synchronous application dependencies.
component :interface, in: %w[
  app/channels/**/*.rb
  app/controllers/**/*.rb
  app/helpers/**/*.rb
  app/presenters/**/*.rb
]
component :application, in: "app/services/**/*.rb"
component :jobs, in: "app/jobs/**/*.rb"
component :delivery, in: %w[app/mailers/**/*.rb app/broadcasts/**/*.rb]
component :domain, in: "app/models/**/*.rb"
component :support, in: "lib/nexus/**/*.rb"
component :runtime_boot, in: "lib/model_runner/**/*.rb"
component(:concerns, in: "app/**/concerns/**/*.rb").cannot_reference_includers

interface.can_only_use :application, :jobs, :delivery, :domain, :support, :concerns
application.can_only_use :jobs, :delivery, :domain, :support, :concerns
jobs.can_only_use :application, :delivery, :domain, :support, :concerns
delivery.can_only_use :domain, :support, :concerns
domain.can_only_use :jobs, :delivery, :support, :concerns
support.can_only_use
runtime_boot.can_only_use :support

# Enqueued jobs and Rails delivery callbacks return through separate execution
# boundaries. The synchronous core must remain acyclic; models cannot bypass
# the enqueue boundary by executing jobs inline.
no_cycles among: %i[interface application domain support]
domain.cannot_call :perform_now, receiver: "ActiveJob::Base"

controller_api = %i[render redirect_to params session cookies flash]
[application, jobs, domain, support].each do |layer|
  layer.cannot_call(*controller_api, receiver: :none)
end

application.cannot_reference_constants "ActionController", "ActionView"
jobs.cannot_reference_constants "ActionController", "ActionView"
domain.cannot_reference_constants "ActionController", "ActionView"
domain.cannot_reference_constants "ModelProviders", "ModelSelection"
support.cannot_reference_constants "ActiveRecord", "ActiveJob", "ActionController", "ActionMailer", "ActionView"
