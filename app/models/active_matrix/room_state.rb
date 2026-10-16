# frozen_string_literal: true

module ActiveMatrix
  # The current state event for one (type, state_key) in a room. Mirrored by
  # the daemon.
  class RoomState < ApplicationRecord
    self.table_name = 'active_matrix_room_state'

    belongs_to :agent, class_name: 'ActiveMatrix::Agent'
    belongs_to :room, class_name: 'ActiveMatrix::Room', foreign_key: %i[agent_id room_id],
                      primary_key: %i[agent_id room_id], inverse_of: :state_events

    def readonly? = true
  end
end
