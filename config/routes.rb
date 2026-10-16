# frozen_string_literal: true

ActiveMatrix::Engine.routes.draw do
  post 'deliveries', to: 'deliveries#create', as: :deliveries
end
