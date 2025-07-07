# frozen_string_literal: true

module ActiveMatrix::Rooms
  class Space < ActiveMatrix::Room
    TYPE = 'm.space'

    def tree(suggested_only: nil, max_rooms: nil)
      data = client.api.request :get, :client_v1, "/rooms/#{id}/hierarchy", query: {
        suggested_only: suggested_only,
        max_depth: max_rooms
      }.compact

      rooms = data.rooms.map do |r|
        next if r[:room_id] == id

        room = client.ensure_room(r[:room_id])
        room.instance_variable_set :@room_type, r[:room_type] if r.key? :room_type
        room = room.to_space if room.space?

        # Inject available room information
        r.each do |k, v|
          room.instance_variable_set("@#{k}", v) if room.instance_variable_defined? "@#{k}"
        end
        room
      end
      rooms.compact!

      grouping = {}
      data.events.each do |ev|
        next unless ev[:type] == 'm.space.child'
        next unless ev[:content].key? :via

        d = (grouping[ev[:room_id]] ||= [])
        d << ev[:state_key]
      end

      build_tree = proc do |entry|
        next if entry.nil?

        room = self if entry == id
        room ||= rooms.find { |r| r.id == entry }
        Rails.logger.debug { "Unable to find room for entry #{entry}" } unless room
        # next if room.nil?

        ret = {
          room => []
        }

        grouping[entry]&.each do |child|
          if grouping.key?(child)
            ret[room] << build_tree.call(child)
          else
            child_r = self if child == id
            child_r ||= rooms.find { |r| r.id == child }

            ret[room] << child_r
          end
        end

        ret[room].compact!

        ret
      end

      build_tree.call(id)
    end
  end
end
