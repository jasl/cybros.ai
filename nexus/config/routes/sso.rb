post "sso/providers/:provider_id/start", to: "sso/attempts#create", as: :sso_start
get "sso/providers/:provider_id/callback", to: "sso/attempts#callback", as: :sso_callback
get "sso/attempts/:id/confirmation", to: "sso/attempts#show", as: :sso_confirmation
post "sso/attempts/:id/confirmation", to: "sso/attempts#confirm"
get "sso/recovery", to: "sso/recoveries#show", as: :sso_recovery
