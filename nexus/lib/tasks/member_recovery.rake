# Deployment-local human-member recovery. These tasks run only on the
# installation host; no remote surface can mint or clear recovery.
namespace :member_recovery do
  desc "Mint a one-time recovery secret for an active human member: member_recovery:mint[email]"
  task :mint, [:email] => :environment do |_, args|
    identity = Identity.find_by(email: Identity.normalize_value_for(:email, args[:email].to_s))
    result = MemberRecoveryAuthorizations::Issue.call(user: identity&.user)

    if result.outcome == :issued
      puts "One-time consume path (shown once): /passwords/edit?token=#{result.secret}"
      puts "Expires at: #{result.authorization.expires_at.utc.iso8601}"
      puts "Every existing session and credential for this member is now fenced."
      puts "Open that path on this installation and set the new password there."
    else
      abort "Not recoverable: the target must be an active human member of this installation."
    end
  end

  desc "Show recovery state for a member without revealing any secret: member_recovery:status[email]"
  task :status, [:email] => :environment do |_, args|
    identity = Identity.find_by(email: Identity.normalize_value_for(:email, args[:email].to_s))
    abort "No identity found for that email." if identity.nil?

    current = MemberRecoveryAuthorization.current.find_by(identity: identity)
    puts "Recovery generation: #{identity.credential_recovery_generation}"
    puts "Fence pending: #{identity.local_recovery_pending?}"
    if current
      puts "Current authorization: generation #{current.generation}, expires #{current.expires_at.utc.iso8601}"
    else
      puts "Current authorization: none"
    end
  end
end
