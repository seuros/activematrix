# frozen_string_literal: true

module ActiveMatrix
  # Helper methods for async ActiveRecord queries (Rails 8.0+)
  module AsyncQuery
    module_function

    # Load records asynchronously
    # @param relation [ActiveRecord::Relation] The relation to load
    # @return [Array] The loaded records
    def load_async(relation)
      relation.load_async.to_a
    end

    # Count records asynchronously
    # @param relation [ActiveRecord::Relation] The relation to count
    # @return [Integer] The count
    def async_count(relation)
      relation.async_count.value
    end

    # Sum column asynchronously
    # @param relation [ActiveRecord::Relation] The relation
    # @param column [Symbol] The column to sum
    # @return [Numeric] The sum
    def async_sum(relation, column)
      relation.async_sum(column).value
    end

    # Pluck columns asynchronously
    # @param relation [ActiveRecord::Relation] The relation
    # @param columns [Array<Symbol>] The columns to pluck
    # @return [Array] The plucked values
    def async_pluck(relation, *columns)
      relation.async_pluck(*columns).value
    end

    # Check existence asynchronously
    # @param relation [ActiveRecord::Relation] The relation
    # @return [Boolean] Whether records exist
    def async_exists?(relation)
      relation.async_count.value.positive?
    end

    # Execute multiple async queries in parallel and wait for all results
    # @param queries [Hash<Symbol, Proc>] Named queries to execute
    # @return [Hash<Symbol, Object>] Results keyed by query name
    # @example
    #   results = AsyncQuery.parallel(
    #     agents: -> { MatrixAgent.where(state: :online).load_async },
    #     count: -> { MatrixAgent.async_count }
    #   )
    def parallel(**queries)
      promises = queries.transform_values(&:call)
      promises.transform_values { |result| result.respond_to?(:value) ? result.value : result }
    end
  end
end
