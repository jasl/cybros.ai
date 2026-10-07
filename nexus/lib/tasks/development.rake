namespace :development do
  desc "Create an explicit local-only demonstration owner in an empty development installation"
  task seed: :environment do
    abort "development:seed is only available in development." unless Rails.env.development?
    abort "The installation already has an account. No settings were changed." if Account.exists?

    Account.create_with_owner(
      account: { name: Setup::DEFAULT_ACCOUNT_NAME },
      owner: {
        email: "admin@example.com", display_name: "Admin",
        password: "Passw0rd!", password_confirmation: "Passw0rd!",
      }
    )
    puts "Created local development owner: admin@example.com / Passw0rd!"
    puts "Sign in to the Dashboard, then open /admin/model_providers to configure a provider."
  end
end
