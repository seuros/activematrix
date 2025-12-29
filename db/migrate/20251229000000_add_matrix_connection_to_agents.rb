# frozen_string_literal: true

class AddMatrixConnectionToAgents < ActiveRecord::Migration[8.0]
  def change
    # Add matrix_connection to reference YAML-configured connections
    # When set, credentials come from config/active_matrix.yml
    # When nil, uses inline homeserver/access_token columns (for user-uploaded bots)
    add_column :active_matrix_agents, :matrix_connection, :string

    # Make credential columns nullable - they're optional when using matrix_connection
    change_column_null :active_matrix_agents, :homeserver, true
    change_column_null :active_matrix_agents, :username, true

    add_index :active_matrix_agents, :matrix_connection
  end
end
