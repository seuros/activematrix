# frozen_string_literal: true

# <rails-lens:schema:begin>
# connection = "primary"
# database_dialect = "SQLite"
# database_version = "3.50.4"
#
# # This is an abstract class that establishes a database connection
# # but does not have an associated table.
# <rails-lens:schema:end>
module ActiveMatrix
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true
  end
end
