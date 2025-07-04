# frozen_string_literal: true

module ActiveMatrix
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true
  end
end
