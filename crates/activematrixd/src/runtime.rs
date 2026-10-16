//! The supervisor: claims agents, keeps their leases, runs one task per
//! agent, wakes outbox workers, serves the probes, and drains on shutdown.

pub mod agent;
pub mod metrics;
mod probe;

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use chrono_machines::{BackoffStrategy, ExponentialBackoff};
use sqlx::PgPool;
use sqlx::postgres::PgListener;
use tokio::sync::{Notify, mpsc, watch};
use tokio::task::JoinHandle;
use tokio::time::Instant;
use uuid::Uuid;

use crate::config::Config;
use crate::db::agents::{self, Agent, State};
use crate::db::{Db, SchemaError};
use crate::delivery::{self, Pusher};
use agent::{Control, Ending, Env, Report, SharedReport};

/// How often unprocessed inbox rows are pushed again.
const DELIVERY_SWEEP: Duration = Duration::from_secs(15);

/// Exponential backoff with full jitter: about 1s, 2s, 4s ... up to a minute.
pub fn backoff(attempt: u8) -> Duration {
    let policy = ExponentialBackoff::new()
        .base_delay_ms(1_000)
        .multiplier(2.0)
        .max_delay_ms(60_000)
        .jitter_factor(1.0)
        .max_attempts(u8::MAX);
    policy
        .delay(attempt, &mut chrono_machines::rand::rng())
        .map_or(Duration::from_mins(1), Duration::from_millis)
}

#[derive(Debug, thiserror::Error)]
pub enum StartError {
    #[error(transparent)]
    Config(#[from] crate::config::ConfigError),
    #[error("database: {0}")]
    Database(#[from] sqlx::Error),
    #[error(transparent)]
    Schema(#[from] SchemaError),
    #[error("probe server: {0}")]
    Probe(String),
}

struct Handle {
    control: watch::Sender<Control>,
    outbox_wake: Arc<Notify>,
    report: SharedReport,
    task: JoinHandle<Ending>,
}

/// State the probes read.
pub struct Shared {
    node: String,
    heartbeat: Duration,
    started: Instant,
    agents: Mutex<HashMap<Uuid, Handle>>,
    last_heartbeat: Mutex<Option<Instant>>,
    draining: AtomicBool,
}

impl Shared {
    fn agents(&self) -> MutexGuard<'_, HashMap<Uuid, Handle>> {
        self.agents.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn reports(&self) -> Vec<(Uuid, Report)> {
        self.agents()
            .iter()
            .map(|(id, handle)| {
                (
                    *id,
                    handle
                        .report
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner)
                        .clone(),
                )
            })
            .collect()
    }

    fn healthy(&self) -> bool {
        let last = *self
            .last_heartbeat
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        last.is_some_and(|at| at.elapsed() < self.heartbeat * 3)
    }
}

/// A started daemon.
pub struct Running {
    pub probe: SocketAddr,
    pub task: JoinHandle<()>,
}

/// Connects, checks the schema, binds the probe, and starts supervising.
/// Runs until `shutdown` turns true, then drains.
pub async fn start(
    config: &Config,
    shutdown: watch::Receiver<bool>,
) -> Result<Running, StartError> {
    let db = Db::connect(config.database_url()?, 10).await?;
    db.verify_schema().await?;
    let pool = db.pool().clone();
    let key = Arc::new(config.master_key()?);
    let pusher = Pusher::new(config.delivery()?);

    let shared = Arc::new(Shared {
        node: config.node_id.clone(),
        heartbeat: config.heartbeat,
        started: Instant::now(),
        agents: Mutex::new(HashMap::new()),
        last_heartbeat: Mutex::new(None),
        draining: AtomicBool::new(false),
    });
    let probe = probe::serve(config.probe_bind, Arc::clone(&shared), shutdown.clone())
        .await
        .map_err(|error| StartError::Probe(error.to_string()))?;

    let (delivery_tx, delivery_rx) = mpsc::unbounded_channel();
    let env = Env {
        db: pool.clone(),
        node: config.node_id.clone(),
        key,
        delivery: delivery_tx,
    };
    let delivery = tokio::spawn(delivery::run(
        pusher,
        pool.clone(),
        env.node.clone(),
        delivery_rx,
        DELIVERY_SWEEP,
        shutdown.clone(),
    ));
    tokio::spawn(outbox_listener(pool, Arc::clone(&shared), shutdown.clone()));

    let settings = Settings {
        heartbeat: config.heartbeat,
        lease_ttl: config.lease_ttl,
        max_agents: config.max_agents,
        shutdown_timeout: config.shutdown_timeout,
    };
    let task = tokio::spawn(async move {
        supervise(&env, settings, &shared, shutdown).await;
        drop(env); // closes the delivery queue, so the delivery loop ends
        let _ = delivery.await;
    });
    tracing::info!(node = %config.node_id, probe = %probe, "activematrixd started");
    Ok(Running { probe, task })
}

#[derive(Clone, Copy)]
struct Settings {
    heartbeat: Duration,
    lease_ttl: Duration,
    max_agents: u32,
    shutdown_timeout: Duration,
}

async fn supervise(
    env: &Env,
    settings: Settings,
    shared: &Arc<Shared>,
    mut shutdown: watch::Receiver<bool>,
) {
    let mut ticks = tokio::time::interval(settings.heartbeat);
    ticks.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        tokio::select! {
            _ = ticks.tick() => heartbeat(env, settings, shared).await,
            _ = shutdown.changed() => break,
        }
    }
    drain(env, settings, shared).await;
}

/// Reaps finished agents, renews leases, claims new agents.
async fn heartbeat(env: &Env, settings: Settings, shared: &Arc<Shared>) {
    let finished: Vec<(Uuid, Handle)> = shared
        .agents()
        .extract_if(|_, handle| handle.task.is_finished())
        .collect();
    for (id, handle) in finished {
        match handle.task.await {
            Ok(ending) => tracing::info!(agent = %id, ?ending, "agent stopped"),
            Err(error) => tracing::error!(agent = %id, %error, "agent task crashed"),
        }
    }

    let held: Vec<Uuid> = shared.agents().keys().copied().collect();
    match agents::renew(&env.db, &env.node, settings.lease_ttl, &held).await {
        Ok(renewed) => {
            let renewed: HashMap<Uuid, bool> = renewed.into_iter().collect();
            for (id, handle) in shared.agents().iter() {
                let (lease_held, enabled) = renewed
                    .get(id)
                    .map_or((false, true), |enabled| (true, *enabled));
                handle.control.send_if_modified(|control| {
                    let changed = control.lease_held != lease_held || control.enabled != enabled;
                    control.lease_held = lease_held;
                    control.enabled = enabled;
                    changed
                });
            }
            *shared
                .last_heartbeat
                .lock()
                .unwrap_or_else(PoisonError::into_inner) = Some(Instant::now());
        }
        // Leases outlive a few missed heartbeats; if the database stays away,
        // another daemon takes the agents and fencing stops these ones.
        Err(error) => tracing::warn!(%error, "could not renew leases"),
    }

    let free = usize::try_from(settings.max_agents)
        .unwrap_or(usize::MAX)
        .saturating_sub(shared.agents().len());
    if free == 0 || shared.draining.load(Ordering::Relaxed) {
        return;
    }
    match agents::claim(
        &env.db,
        &env.node,
        settings.lease_ttl,
        i64::try_from(free).unwrap_or(i64::MAX),
    )
    .await
    {
        Ok(claimed) => {
            for agent in claimed {
                spawn_agent(env, shared, agent);
            }
        }
        Err(error) => tracing::warn!(%error, "could not claim agents"),
    }
}

fn spawn_agent(env: &Env, shared: &Shared, agent: Agent) {
    let id = agent.id;
    tracing::info!(agent = %agent.name, "claimed");
    let (control, receiver) = watch::channel(Control {
        lease_held: true,
        enabled: agent.enabled,
        stopping: false,
    });
    let outbox_wake = Arc::new(Notify::new());
    let report = Arc::new(Mutex::new(Report {
        name: agent.name.clone(),
        state: State::Starting,
        error: None,
    }));
    let task = tokio::spawn(agent::run(
        agent,
        env.clone(),
        receiver,
        Arc::clone(&outbox_wake),
        Arc::clone(&report),
    ));
    shared.agents().insert(
        id,
        Handle {
            control,
            outbox_wake,
            report,
            task,
        },
    );
}

/// Tells every agent to stop, waits for them up to the shutdown timeout,
/// and releases whatever is left.
async fn drain(env: &Env, settings: Settings, shared: &Arc<Shared>) {
    shared.draining.store(true, Ordering::Relaxed);
    let handles: Vec<(Uuid, Handle)> = shared.agents().drain().collect();
    tracing::info!(agents = handles.len(), "draining");
    for (_, handle) in &handles {
        handle
            .control
            .send_modify(|control| control.stopping = true);
    }
    let deadline = Instant::now() + settings.shutdown_timeout;
    let mut stragglers = Vec::new();
    for (id, handle) in handles {
        match tokio::time::timeout_at(deadline, handle.task).await {
            Ok(_) => {}
            Err(_) => stragglers.push(id),
        }
    }
    if !stragglers.is_empty() {
        tracing::warn!(
            count = stragglers.len(),
            "agents did not stop in time; releasing them"
        );
        if let Err(error) = agents::release(&env.db, &env.node, &stragglers, false).await {
            tracing::warn!(%error, "could not release leases");
        }
    }
    tracing::info!("drained");
}

/// Wakes the outbox worker of the agent a new command belongs to. Workers
/// also poll, so a missed notification only delays a send.
async fn outbox_listener(pool: PgPool, shared: Arc<Shared>, mut shutdown: watch::Receiver<bool>) {
    let mut listener = loop {
        match PgListener::connect_with(&pool).await {
            Ok(mut listener) => match listener.listen("active_matrix_outbox").await {
                Ok(()) => break listener,
                Err(error) => tracing::warn!(%error, "could not LISTEN for outbox commands"),
            },
            Err(error) => tracing::warn!(%error, "could not connect the outbox listener"),
        }
        tokio::select! {
            () = tokio::time::sleep(Duration::from_secs(5)) => {}
            _ = shutdown.changed() => return,
        }
    };
    loop {
        let notification = tokio::select! {
            notification = listener.recv() => notification,
            _ = shutdown.changed() => return,
        };
        let id = match notification {
            Ok(notification) => notification.payload().parse::<Uuid>().ok(),
            Err(error) => {
                // PgListener reconnects and listens again on its own.
                tracing::warn!(%error, "outbox listener interrupted");
                tokio::time::sleep(Duration::from_secs(1)).await;
                continue;
            }
        };
        let Some(id) = id else { continue };
        let agent: Option<Uuid> =
            sqlx::query_scalar("SELECT agent_id FROM active_matrix_outbox WHERE id = $1")
                .bind(id)
                .fetch_optional(&pool)
                .await
                .unwrap_or_default();
        if let Some(agent) = agent
            && let Some(handle) = shared.agents().get(&agent)
        {
            handle.outbox_wake.notify_one();
        }
    }
}
