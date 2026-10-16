//! activematrixd owns every Matrix connection for an ActiveMatrix app: it
//! syncs agents, mirrors room state into Postgres, and sends what the Rails
//! side writes to the outbox.

pub mod cli;
