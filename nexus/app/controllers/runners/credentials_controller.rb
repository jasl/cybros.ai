class Runners::CredentialsController < Runners::BaseController
  # The lineages end, the address survives, and the
  # same logical registration re-pairs on its next connection.
  def destroy
    runner.revoke_credentials
    redirect_to runner_path(runner), notice: t(".revoked")
  end
end
