# frozen_string_literal: true

module ActiveMatrix
  # A room membership as one agent sees it. Mirrored by the daemon.
  class RoomMember < ApplicationRecord
    self.table_name = 'active_matrix_room_members'

    belongs_to :agent, class_name: 'ActiveMatrix::Agent'
    belongs_to :room, class_name: 'ActiveMatrix::Room', foreign_key: %i[agent_id room_id],
                      primary_key: %i[agent_id room_id], inverse_of: :members

    def readonly? = true
  end
end
