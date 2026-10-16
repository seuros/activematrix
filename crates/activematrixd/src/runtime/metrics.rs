//! Process-wide counters for `/metrics`, in Prometheus text format.

use std::fmt::Write as _;
use std::sync::atomic::{AtomicU64, Ordering};

pub struct Counter {
    name: &'static str,
    help: &'static str,
    value: AtomicU64,
}

impl Counter {
    const fn new(name: &'static str, help: &'static str) -> Self {
        Self { name, help, value: AtomicU64::new(0) }
    }

    pub fn add(&self, n: u64) {
        self.value.fetch_add(n, Ordering::Relaxed);
    }

    pub fn get(&self) -> u64 {
        self.value.load(Ordering::Relaxed)
    }
}

pub static SYNC_BATCHES: Counter =
    Counter::new("activematrixd_sync_batches_total", "Sync batches ingested");
pub static INBOX_EVENTS: Counter =
    Counter::new("activematrixd_inbox_events_total", "Events queued for the bots");
pub static SYNC_ERRORS: Counter =
    Counter::new("activematrixd_sync_errors_total", "Sync loops that ended in an error");
pub static OUTBOX_SENT: Counter =
    Counter::new("activematrixd_outbox_sent_total", "Outbox commands sent");
pub static OUTBOX_RETRIED: Counter =
    Counter::new("activematrixd_outbox_retried_total", "Outbox commands put back to retry");
pub static OUTBOX_FAILED: Counter =
    Counter::new("activematrixd_outbox_failed_total", "Outbox commands given up on");
pub static DELIVERIES: Counter =
    Counter::new("activematrixd_deliveries_total", "Pushes accepted by Rails");
pub static DELIVERY_FAILURES: Counter =
    Counter::new("activematrixd_delivery_failures_total", "Pushes Rails did not accept");

const COUNTERS: &[&Counter] = &[
    &SYNC_BATCHES,
    &INBOX_EVENTS,
    &SYNC_ERRORS,
    &OUTBOX_SENT,
    &OUTBOX_RETRIED,
    &OUTBOX_FAILED,
    &DELIVERIES,
    &DELIVERY_FAILURES,
];

/// Renders every counter plus the `agents` gauge, one line per state.
pub fn render(agents_by_state: &[(&str, usize)]) -> String {
    let mut out = String::new();
    // Writing to a String cannot fail.
    for counter in COUNTERS {
        let _ = writeln!(
            out,
            "# HELP {} {}\n# TYPE {} counter\n{} {}",
            counter.name,
            counter.help,
            counter.name,
            counter.name,
            counter.get()
        );
    }
    let _ = writeln!(
        out,
        "# HELP activematrixd_agents Agents this daemon holds, by state\n\
         # TYPE activematrixd_agents gauge"
    );
    for (state, count) in agents_by_state {
        let _ = writeln!(out, "activematrixd_agents{{state=\"{state}\"}} {count}");
    }
    out
}
