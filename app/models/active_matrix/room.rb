# frozen_string_literal: true

module ActiveMatrix
  # A room as one agent sees it. Mirrored from /sync by the daemon; read-only
  # from Rails, whose writes go through the outbox.
  class Room < ApplicationRecord
    self.table_name = 'active_matrix_rooms'

    belongs_to :agent, class_name: 'ActiveMatrix::Agent', inverse_of: :rooms
    has_many :members, class_name: 'ActiveMatrix::RoomMember', foreign_key: %i[agent_id room_id],
                       primary_key: %i[agent_id room_id], inverse_of: :room, dependent: nil
    has_many :state_events, class_name: 'ActiveMatrix::RoomState', foreign_key: %i[agent_id room_id],
                            primary_key: %i[agent_id room_id], inverse_of: :room, dependent: nil

    scope :joined, -> { where(membership: 'join') }
    scope :invited, -> { where(membership: 'invite') }

    def readonly? = true

    # Content of the state event (type, state_key), or nil.
    def state(event_type, state_key = '')
      state_events.find_by(event_type:, state_key:)&.content
    end

    def power_levels = state('m.room.power_levels') || {}

    # user_id's power level, by the m.room.power_levels rules: an explicit
    # entry, else users_default (0 when unset). Without a power levels event
    # the creator has 100. From room version 12 (MSC4289) creators outrank
    # every level and appear as Float::INFINITY.
    def power_level(user_id)
      return Float::INFINITY if privileged_creators.include?(user_id)

      levels = state('m.room.power_levels')
      return levels.dig('users', user_id) || levels.fetch('users_default', 0) if levels

      creators.include?(user_id) ? 100 : 0
    end

    def joined_members = members.where(membership: 'join')

    private

    def create_event = state_events.find_by(event_type: 'm.room.create', state_key: '')

    def creators
      event = create_event
      return [] unless event

      [event.sender, event.content['creator'], *event.content['additional_creators']].compact.uniq
    end

    def privileged_creators
      version = create_event&.content&.fetch('room_version', '1').to_s
      version.match?(/\A\d+\z/) && version.to_i >= 12 ? creators : []
    end
  end
end
