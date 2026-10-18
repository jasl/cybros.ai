module ModelInvocations
  # Occupancy counted from the running set: the terminal transition is
  # the release, so nothing can drift or leak. Blast-radius brakes, not
  # fairness — that is the rotation's job.
  module RunningCapacity
    # Blast-radius brake per payer. Release policy, never an Account setting.
    USER_ACTIVE_LIMIT = 16

    class << self
      # Every layered cap, answered together, because the caller asks them
      # under one advisory lock and a partial answer would be a bypass lane.
      def available?(provider_id:, workload:, payer_id:, catalog: ModelCatalog.current)
        running_for(provider_id).count <
          ModelCatalog.provider_concurrency_limit(provider_id, snapshot: catalog) &&
          running_for(provider_id, workload: workload).count <
            ModelCatalog.provider_concurrency_limit(
              provider_id, workload: workload, snapshot: catalog
            ) &&
          running_for_payer(payer_id).count < USER_ACTIVE_LIMIT
      end

      private

        # An Agent's running work rides its steward's brake, resolved
        # through `users.steward_id`.
        def running_for_payer(payer_id)
          ModelInvocation.where(
            status: "running", creating_user_id: User.billed_to(payer_id).select(:id)
          )
        end

        def running_for(provider_id, workload: nil)
          scope = ModelInvocation.where(status: "running", provider_id: provider_id)
          workload ? scope.where(workload: workload) : scope
        end
    end
  end
end
