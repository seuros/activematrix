# frozen_string_literal: true

require 'matrix_sdk/util/extensions'
require 'matrix_sdk/util/uri'
require 'matrix_sdk/version'

require 'json'

require_relative 'matrix_sdk/logging'

module MatrixSdk
  autoload :Api, 'matrix_sdk/api'
  # autoload :ApplicationService, 'matrix_sdk/application_service'
  autoload :Client, 'matrix_sdk/client'
  autoload :MXID, 'matrix_sdk/mxid'
  autoload :Response, 'matrix_sdk/response'
  autoload :Room, 'matrix_sdk/room'
  autoload :User, 'matrix_sdk/user'

  autoload :MatrixError, 'matrix_sdk/errors'
  autoload :MatrixRequestError, 'matrix_sdk/errors'
  autoload :MatrixNotAuthorizedError, 'matrix_sdk/errors'
  autoload :MatrixForbiddenError, 'matrix_sdk/errors'
  autoload :MatrixNotFoundError, 'matrix_sdk/errors'
  autoload :MatrixConflictError, 'matrix_sdk/errors'
  autoload :MatrixTooManyRequestsError, 'matrix_sdk/errors'
  autoload :MatrixConnectionError, 'matrix_sdk/errors'
  autoload :MatrixTimeoutError, 'matrix_sdk/errors'
  autoload :MatrixUnexpectedResponseError, 'matrix_sdk/errors'

  module Bot
    autoload :Base, 'matrix_sdk/bot/base'
  end

  module Rooms
    autoload :Space, 'matrix_sdk/rooms/space'
  end

  module Util
    autoload :AccountDataCache, 'matrix_sdk/util/account_data_cache'
    autoload :StateEventCache, 'matrix_sdk/util/state_event_cache'
    autoload :Tinycache, 'matrix_sdk/util/tinycache'
    autoload :TinycacheAdapter, 'matrix_sdk/util/tinycache_adapter'
  end

  module Protocols
    autoload :AS, 'matrix_sdk/protocols/as'
    autoload :CS, 'matrix_sdk/protocols/cs'
    autoload :IS, 'matrix_sdk/protocols/is'
    autoload :SS, 'matrix_sdk/protocols/ss'

    # Non-final protocol extensions
    autoload :MSC, 'matrix_sdk/protocols/msc'
  end

  # Load Railtie for Rails integration
  require 'matrix_sdk/railtie' if defined?(Rails::Railtie)
end
