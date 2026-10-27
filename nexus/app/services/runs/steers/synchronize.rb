module Runs
  module Steers
    # Consumption pins link authority before execution owners. A source Stop and
    # recipient scheduling then serialize in Run id order, including bidirectional
    # messages. Discovery is lock-free; a newly accepted row asks the existing
    # scheduler to retry rather than acquiring its owners below a held Run.
    module Synchronize
      module_function

      def call(run_id:)
        preview = Run.find_by(id: run_id)
        return unless preview

        rows = preview.steering_inputs.pluck(:id, :conversation_link_id, :sender_run_public_id)
        links = rows.filter_map { |row| row[1] }.uniq
        owners = rows.filter_map { |row| row[2] }.uniq
        Run.transaction do
          if links.any?
            preview.workspace.lock!("FOR KEY SHARE")
            User.where(id: [preview.creating_user_id, preview.answering_user.id]).order(:id).lock("FOR KEY SHARE").load
          end
          grants = ConversationLink.where(id: links).order(:id).lock("FOR SHARE").index_by(&:id)
          SourceWork.with_sources(owners + [preview.public_id]) do |runs|
            run = runs[preview.public_id]
            next unless run

            current = run.steering_inputs.to_a
            if (current.map(&:id) - rows.map(&:first)).any?
              ScheduleJob.perform_later(run.id)
              next
            end

            current.each do |input|
              if (input.conversation_link_id && grants.fetch(input.conversation_link_id).closed?) ||
                  SourceWork.stopped?(input.cancellation_source_public_id, runs[input.sender_run_public_id])
                # The execution owner excludes every other consumer; the public
                # edit/delete doors serialize on the row before it is destroyed.
                input = Input.lock.find_by(id: input.id)
                Conversations::Inputs::Destroy.remove(input) if input
              end
            end
            yield run
          end
        end
      end
    end
  end
end
