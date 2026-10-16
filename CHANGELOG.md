## 2.8.0 - 2022-08-19

- Drops support for EoL Ruby 2.6
- Adds helpers for accessing room state
- Fixes Client#sync_token usage
- Improves caching of state events in rooms

## [0.1.0](https://github.com/seuros/activematrix/compare/v0.0.15...v0.1.0) (2026-10-16)


### ⚠ BREAKING CHANGES

* the bot API is new; MultiInstanceBase and the old DSL are gone, and MXID no longer accepts group ids.
* agent_stores, knowledge_bases and the chat session context and history columns are gone; agents must run `activematrix login` after upgrading.
* the Ruby Matrix client, the in-process agent runtime and the activematrix Thor CLI are removed.

### Features

* **daemon:** configuration, sealed access tokens, keygen and check ([3aca69a](https://github.com/seuros/activematrix/commit/3aca69a48c5118c79358b05f49f35392859cd408))
* **daemon:** leases and exactly-once ingest ([d340441](https://github.com/seuros/activematrix/commit/d340441dd2e12b4fac86c5b10071cb498e3532e4))
* **daemon:** Matrix client and a fake homeserver to test it against ([4a2ef48](https://github.com/seuros/activematrix/commit/4a2ef4877943f5b027547079e07b3bc0ed96a10a))
* scaffold the activematrixd Rust workspace ([55438f1](https://github.com/seuros/activematrix/commit/55438f1320693602249d18d6500bc1ec6bf5b209))
* system tests, the Synapse contract tier, and the release pipeline ([eff57b1](https://github.com/seuros/activematrix/commit/eff57b126da99346867f0d07b615cfe6f152f08a))
* the database contract between the daemon and Rails ([66c3be7](https://github.com/seuros/activematrix/commit/66c3be760a30b307fb3ba272b5cf32916a586e62))
* the Rails side: delivery endpoint, ordered drain jobs and the bot DSL ([535db3d](https://github.com/seuros/activematrix/commit/535db3d3c5b7a8331b92177fe010839067d05d01))


### Bug Fixes

* **daemon:** ACTIVEMATRIX_MAX_AGENTS overrides max_agents ([448af39](https://github.com/seuros/activematrix/commit/448af395c86d9736d6bba7141eeaceccc4e60237))


### Code Refactoring

* replace the Ruby SDK and runtime with an engine skeleton and daemon launcher ([1aa9e70](https://github.com/seuros/activematrix/commit/1aa9e701719b6ea24a98183734e760f14bb64cab))

## 2.7.0 - 2022-08-12

- Adds a bot subsystem + DSL
  - [An example](examples/bot_api.rb) can be found in the examples folder
- Adds additional useful helpers for Room and User
- Fixes Client.new_for_domain
- Improves the handling of MXIDs as strings
- Improves handling of caches for rooms
- Improves Client shutdown when using Client#start_listener_thread
- Improves account data handling, with caches on both Client and Room level

## 2.6.0 - 2022-07-15

- Adds some multi-thread usage support to the API (create your API/client with `threadsafe: :multithread/true/false`)
    The API will currently default to running with multi-threaded requests. In case your application is single-threaded - or never performs requests from multiple threads - then you can set `threadsafe: true/false` to support connection reuse.
- Changes room finding to ignore non-canonical aliases by default
- Improves room alias handling
- Improves Ruby 3.0+ support
- Improves debug output by supporting PP (Ruby pretty print) on all MatrixSdk objects

## 2.5.0 - 2022-01-14

- Adds preliminary support for the Matrix v1.1 `client/v3` API
- Adds some support for knocking rooms
- Adds mutex synchronization on API requests to avoid some threading issues
- Fixes error on attempting to skip cache for certain requests (#19)
- Fixes inconsistency in MXID typing for the Client abstraction (#18 #20)
- Fixes missed autoloader entries for errors (#22)
- Fixes some potential issues arising from broken user-provided state data

## 2.4.0 - 2021-07-19

- Adds support for matrix: URI's according to MSC2312
- Adds some basic support for detecting Spaces (MSC1772)
- Fixes sync against Synapse 1.38.0 missing empty fields

## 2.3.0 - 2021-03-26

- Adds support for Ruby 3.0 (#15)
- Adds support for requests against the Synapse admin API
- Adds helper methods for checking and changing user power levels
- Adds a proper caching system for room data
- Fixes argument error in `#get_room_messages`
- Removes unfinished and broken AS abstraction

## 2.2.0 - 2020-11-20

- Adds direct message (1:1) room mapping to client abstraction
- Adds Api#get_room_event_context (#13)
- Improves support for JRuby

## 2.1.3 - 2020-09-18

- Adds separate state event handler as Client#on_state_event
- Changes Client sync interval to by-default run at full speed
- Fixes state events being sent twice if included in both timeline and state of a sync
- Improves error reporting of broken 200 responses
- Improves event handlers for rooms, to not depend on a specific room object instance anymore

## 2.1.2 - 2020-09-10

- Adds method for reading complete member lists for rooms, improves the CS spec adherence
- Adds test for state events
- Fixes state event handler for rooms not actually passing events
- Fixes Api#new_for_domain using a faulty URI in certain cases

## 2.1.1 - 2020-08-21

- Fixes crash if state event content is null (#11)
- Fixes an uninitialized URI constant exception when requiring only the main library file
- Fixes the Api#get_pushrules method missing an ending slash in the request URI
- Fixes discovery code for client/server connections based on domain

## 2.1.0 - 2020-05-22

- Adds unique query IDs as well as duration in API debug output, to make it easier to track long requests
- Finishes up MSC support, get sync over SSE working flawlessly
- Exposes the #listen_forever method in the client abstraction
- Fixes room access methods

## 2.0.1 - 2020-03-13

- Adds code for handling non-final MSC's in protocols
  - Currently implementing clients parts of MSC2018 for Sync over Server Sent Events

## 2.0.0 - 2020-02-14

**NB**, this release includes backwards-incompatible changes;
- Changes room state lookup to separate specific state lookups from full state retrieval.
  This will require changes in client code where `#get_room_state` is called to retrieve
  all state, as it now requires a state key. For retrieving full room state,
  `#get_room_state_all` is now the method to use.
- Changes some advanced parameters to named parameters, ensure your code is updated if it makes use of them
- Fixes SSL verification to actually verify certs (#9)

- Adds multiple CS API endpoints
- Adds `:room_id` key to all room events
- Adds `:self` as a valid option to the client abstraction's `#get_user` method
- Separates homeserver part stringification for MXIDs
- Exposes some previously private client abstraction methods (`#ensure_room`, `#next_batch`) for easier bot usage
- Changes room abstraction member lookups to use `#get_room_joined_members`, reducing transferred data amounts
- Fixes debug print of methods that return arrays (e.g. CS `/room/{id}/state`)

## 1.5.0 - 2019-10-25

- Adds error event to the client abstraction, for handling errors in the background listener
- Adds an `open_timeout` setter to the API
- Fixes an overly aggressive filter for event handlers

## 1.4.0 - 2019-09-30

- Adds the option to change the logger globally or per-object.

## 1.3.0 - 2019-07-16

- Improves response handling to add accessors recursively
- Removes MatrixSdk extensions from the global scope,
  if you've been using these in your own code you must now remember to
  `extend MatrixSdk::Extensions` in order for them to be available.

## 1.2.1 - 2019-07-02

- Fixes mxc download URL generation

## 1.2.0 - 2019-06-28

- Adds getters and setters for more specced room state
- Fixes handling of the timeout parameter for the sync endpoint (#7)
    - Additionally also now allows for running sync with a nil timeout
- Cleans up the CS protocol implementation slightly, removing a mutation that's not supposed to be there
- Cleans up the gemspec slightly, no longer uses `git ls-files`
- Add support for explicitly setting proxy config for API

## v1.1.1 - 2019-06-05

- Fixes a faulty include which broke the single implemented S2S endpoint
- Replaces the room name handling with a cached lazy loading system

## v1.1.0 - 2019-06-04

- The create_room method in the client abstraction now automatically stores the created room
- Adds more CS API endpoints, exposed as #get_joined_rooms, #get_public_rooms, and #username_available?
- Adds a method to the client abstraction to reload all joined rooms
- Adds a method to the client abstraction to get a list of all public rooms
- Adds avatar tracking to rooms in the client abstraction
- Adds lazy loading of join rules and guest access for rooms in the client abstraction
- Adds granular error classes like MatrixSdk::MatrixNotFoundError to make error handling easier
- Improves the CS API endpoint for room state retrieval
- Fixes an issue in the client abstraction where it would fail to load aliases if multiple HSes have applied aliases to a room

## v1.0.1 - 2019-05-24

- Fixes an error in the room creation code
- Fixes a divergence from spec in the room message request
- Fixes a slight divergence from spec in the kick method
- Fixes a divergence from spec in the tags handling methods

## v1.0.0 - 2019-05-17

- Improves testing and code coverage of existing code
- Fixes a series of minor bugs found during the writing of tests

## v0.1.0 - 2019-05-10

- Adds code for handling member lazy load in the client abstraction, and activates it by default
- Adds methods to read device keys from users
- Adds basic methods for device handling
- Restructures the API code to separate protocol implementations
- Improves the domain discovery code to support all currently specced methods
- Improves performance in sync calls
- Started work on an application service prototype, not ready for use yet
- Testing has been written for large parts of the code

## v0.0.4 - 2019-02-20

- Adds a parameter to the client abstraction to allow retrying syncs on timeouts
- Adds support for token-based login in the client abstraction
- Adds rudimentary username and password validation in the client abstraction
- Adds MXID validation in the client abstraction
- Adds a method to discover a homeserver address based on a domain.
    - Supporting both SRV and .well-known lookups
- Adds methods from the r0.4.0 spec
- Adds support for version 3 event IDs
- Extends the connection exceptions with a specific timeout error
- Sets a series of filters in the simple client example to skip unhandled event
- Fixes an exception when null values end up in the body cleaner during debugging
- Fixes an error with CGI not being required correctly

## v0.0.3 - 2018-08-14

- Adds missing accessors for HTTP timeout
- Adds methods for checking auth status to client API
- Adds a wrapper class for API responses to ease use
- Adds option (and defaults) to store login details on registration
- Allows creating a MatrixSdk::Client off of an existing MatrixSdk::Api
- Extends event handling

- Fixes batch handling in sync
- Fixes event handling in the sample
- Removes unimplemented API methods to avoid confusion

- Plenty of documentation work

## v0.0.2 - 2018-05-11

- Fixes for multiple issues discovered after initial release
- Adds additional API methods
- Higher-level client API gets room and user abstractions

## v0.0.1 - 2018-05-06

Initial release
