class Runners::CredentialsController < Runners::BaseController
  # "Stop this machine now": the lineages end, the machine survives, and the
  # same logical registration re-pairs on its next connection.
  def destroy
    runner.revoke_credentials
    redirect_to runners_path, notice: t(".revoked")
  end
end
