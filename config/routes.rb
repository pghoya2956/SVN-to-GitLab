Rails.application.routes.draw do
  mount ActionCable.server => '/cable'
  
  # API routes
  namespace :api do
    namespace :v1 do
      resources :migrations, only: [:index, :show, :create] do
        member do
          post :cancel
          get :logs
        end
      end
    end
  end
  
  resources :repositories do
    member do
      post :validate
      get :edit_strategy
      patch :update_strategy
      post :sync
      post :detect_structure
      get :edit_authors
      patch :update_authors
    end
    resources :jobs, only: [:new, :create]
  end
  
  resources :jobs, only: [:index, :show] do
    member do
      post :cancel
      post :resume
      get :logs
    end
  end
  
  resources :gitlab_projects, only: [:index] do
    collection do
      get :search
      post :select
    end
  end
  
  resource :gitlab_token, only: [:new, :create, :edit, :update, :destroy]
  
  # devise_for :users (로그인 기능 비활성화)
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Defines the root path route ("/")
  root "repositories#index"
end