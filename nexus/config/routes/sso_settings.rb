namespace :admin do
  resources :sso_providers, only: [:index, :new, :create, :show, :edit, :update, :destroy] do
    resource :deletion, only: :show, module: :sso_providers
    resource :activation, only: [:create, :destroy], module: :sso_providers
  end
  resource :sso_policy, only: :update
end

namespace :settings do
  resources :sso_connections, only: [:index, :destroy]
end
