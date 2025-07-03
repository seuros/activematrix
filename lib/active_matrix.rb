# frozen_string_literal: true

require 'active_matrix/util/extensions'
require 'active_matrix/util/uri'
require 'active_matrix/version'

require 'json'

require_relative 'active_matrix/logging'

module ActiveMatrix
  autoload :Api, 'active_matrix/api'
  # autoload :ApplicationService, 'active_matrix/application_service'
  autoload :Client, 'active_matrix/client'
  autoload :MXID, 'active_matrix/mxid'
  autoload :Response, 'active_matrix/response'
  autoload :Room, 'active_matrix/room'
  autoload :User, 'active_matrix/user'

  autoload :MatrixError, 'active_matrix/errors'
  autoload :MatrixRequestError, 'active_matrix/errors'
  autoload :MatrixNotAuthorizedError, 'active_matrix/errors'
  autoload :MatrixForbiddenError, 'active_matrix/errors'
  autoload :MatrixNotFoundError, 'active_matrix/errors'
  autoload :MatrixConflictError, 'active_matrix/errors'
  autoload :MatrixTooManyRequestsError, 'active_matrix/errors'
  autoload :MatrixConnectionError, 'active_matrix/errors'
  autoload :MatrixTimeoutError, 'active_matrix/errors'
  autoload :MatrixUnexpectedResponseError, 'active_matrix/errors'

  module Bot
    autoload :Base, 'active_matrix/bot/base'
  end

  module Rooms
    autoload :Space, 'active_matrix/rooms/space'
  end

  module Util
    autoload :AccountDataCache, 'active_matrix/util/account_data_cache'
    autoload :StateEventCache, 'active_matrix/util/state_event_cache'
    autoload :Tinycache, 'active_matrix/util/tinycache'
    autoload :TinycacheAdapter, 'active_matrix/util/tinycache_adapter'
  end

  module Protocols
    autoload :AS, 'active_matrix/protocols/as'
    autoload :CS, 'active_matrix/protocols/cs'
    autoload :IS, 'active_matrix/protocols/is'
    autoload :SS, 'active_matrix/protocols/ss'

    # Non-final protocol extensions
    autoload :MSC, 'active_matrix/protocols/msc'
  end

  # Load Railtie for Rails integration
  require 'active_matrix/railtie' if defined?(Rails::Railtie)
end
