# frozen_string_literal: true

Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Defines the root path route ("/")
  # root "articles#index"
  scope :api, defaults: { format: :json }, format: false do
    mount App::Core => '/'

    resources :launch_subscribers

    namespace :admin do
      resources :system_audits
      resources :search_bot_visits
    end
  end
end
