# frozen_string_literal: true

Rails.application.routes.draw do
  mount ActiveMatrix::Engine, at: '/active_matrix'
end
