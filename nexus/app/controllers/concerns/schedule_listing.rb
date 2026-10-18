# The console and member lists use the same status selector before pagination.
module ScheduleListing
  private

    def filtered_schedules(scope)
      status = params.permit(:status)[:status].to_s
      if status.empty?
        scope
      else
        raise APIErrors::ParameterInvalid, :status unless Schedule::STATUSES.include?(status)

        scope.where(status: status)
      end
    end
end
