class Runs::TranscriptController < Runs::BaseController
  def show
    before = params[:before].present? ? Task::TranscriptCursor.decode(params[:before]) : 0
    @transcript = Runs::Transcript.call(run: @run, before: before,
      limit: limit_param(default: Runs::Transcript::DEFAULT_LIMIT, max: Runs::Transcript::MAX_LIMIT),
      prefix: params[:prefix].presence)
    render_not_found if @transcript.refused?
  rescue Task::TranscriptCursor::MalformedCursor
    raise APIErrors::ParameterInvalid, :before
  end
end
