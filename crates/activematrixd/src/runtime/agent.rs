//! One agent: a behavior tree ticked by its own task.
//!
//! ```text
//! reactive_sequence
//! ├── LeaseHeld        re-checked every tick: losing it halts everything below
//! ├── Enabled          Rails' switch, the daemon's shutdown, or a fatal error
//! └── retry_until_successful(unlimited)
//!     └── sequence
//!         ├── Backoff              waits out the delay after a failure
//!         ├── Connect.timeout(30s) opens the token, checks it with whoami
//!         └── Sync                 the sync loop and the outbox worker
//! ```
//!
//! Leaves own their tasks; the tree halts a running leaf exactly once when
//! it abandons it, and halting aborts the task. Nothing is lost by that:
//! the sync token is committed with every batch, and an interrupted send
//! resumes with the same transaction id.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use behavior_machines::{Leaf, Limit, Node, Status, Time, Tree};
use sqlx::PgPool;
use tokio::sync::{Notify, mpsc, oneshot, watch};
use tokio::task::JoinHandle;
use tokio::time::Instant;

use self::tasks::{connect, outbox_worker, sync_loop};
use super::{backoff, metrics};
use crate::crypto::MasterKey;
use crate::db::agents::{self, Agent, State};
use crate::delivery::Pair;
use crate::matrix::Client;

mod tasks;

const CONNECT_TIMEOUT: Duration = Duration::from_secs(30);

/// What the supervisor tells an agent.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Control {
    pub lease_held: bool,
    pub enabled: bool,
    pub stopping: bool,
}

/// What an agent reports, for `/status` and `/metrics`.
#[derive(Debug, Clone)]
pub struct Report {
    pub name: String,
    pub state: State,
    pub error: Option<String>,
}

pub type SharedReport = Arc<Mutex<Report>>;

/// Everything an agent task needs from the process.
#[derive(Clone)]
pub struct Env {
    pub db: PgPool,
    pub node: String,
    pub key: Arc<MasterKey>,
    pub delivery: mpsc::UnboundedSender<Pair>,
}

/// How an agent task ended, for the supervisor.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Ending {
    /// Released: disabled, stopping, or the tree gave up.
    Released,
    /// Another daemon has it now; nothing was written.
    LeaseLost,
    /// Released as failed; it is not claimed again until it logs in again.
    Failed,
}

#[derive(Debug, Clone, Copy)]
enum Step {
    LeaseHeld,
    Enabled,
    Backoff,
    Connect,
    Sync,
}

/// The tree's blackboard.
struct Context {
    agent: Agent,
    env: Env,
    control: watch::Receiver<Control>,
    wake: Arc<Notify>,
    outbox_wake: Arc<Notify>,
    report: SharedReport,
    client: Option<Client>,
    connecting: Option<oneshot::Receiver<Result<Client, Failure>>>,
    syncing: Option<Syncing>,
    attempts: u8,
    backoff_until: Option<Instant>,
    /// Set by the sync loop after a batch commits: the next failure starts
    /// the backoff over.
    healthy: Arc<AtomicBool>,
    lease_lost: bool,
    fatal: Option<String>,
    /// A state change the ticker writes after the tick.
    pending_state: Option<(State, Option<String>)>,
}

struct Syncing {
    sync: JoinHandle<()>,
    outbox: JoinHandle<()>,
    exit: oneshot::Receiver<Failure>,
}

impl Drop for Syncing {
    fn drop(&mut self) {
        self.sync.abort();
        self.outbox.abort();
    }
}

#[derive(Debug)]
enum Failure {
    Transient(String),
    Fatal(String),
    LeaseLost,
}

impl Leaf<Context> for Step {
    fn tick(&self, ctx: &mut Context, _now: Time) -> Status {
        match self {
            Self::LeaseHeld => pass(ctx.control.borrow().lease_held && !ctx.lease_lost),
            Self::Enabled => {
                let control = *ctx.control.borrow();
                pass(control.enabled && !control.stopping && ctx.fatal.is_none())
            }
            Self::Backoff => match ctx.backoff_until {
                Some(until) if Instant::now() < until => Status::Running,
                _ => {
                    ctx.backoff_until = None;
                    Status::Success
                }
            },
            Self::Connect => ctx.tick_connect(),
            Self::Sync => ctx.tick_sync(),
        }
    }

    fn halt(&self, ctx: &mut Context) {
        match self {
            // A connect cut short by its timeout counts as a failure.
            Self::Connect => {
                if ctx.connecting.take().is_some() {
                    ctx.fail("connecting timed out".into());
                }
            }
            Self::Sync => ctx.syncing = None,
            Self::LeaseHeld | Self::Enabled | Self::Backoff => {}
        }
    }
}

const fn pass(ok: bool) -> Status {
    if ok { Status::Success } else { Status::Failure }
}

impl Context {
    fn tick_connect(&mut self) -> Status {
        if self.client.is_some() {
            return Status::Success;
        }
        let Some(receiver) = &mut self.connecting else {
            let (done, receiver) = oneshot::channel();
            let (agent, env, wake) = (self.agent.clone(), self.env.clone(), Arc::clone(&self.wake));
            tokio::spawn(async move {
                // The agent may have been halted meanwhile; then nobody listens.
                let _ = done.send(connect(&agent, &env).await);
                wake.notify_one();
            });
            self.connecting = Some(receiver);
            return Status::Running;
        };
        match receiver.try_recv() {
            Err(oneshot::error::TryRecvError::Empty) => Status::Running,
            Ok(Ok(client)) => {
                self.connecting = None;
                self.client = Some(client);
                Status::Success
            }
            Ok(Err(failure)) => {
                self.connecting = None;
                self.absorb(failure)
            }
            Err(oneshot::error::TryRecvError::Closed) => {
                self.connecting = None;
                self.absorb(Failure::Transient("connect task ended".into()))
            }
        }
    }

    fn tick_sync(&mut self) -> Status {
        let Some(syncing) = &mut self.syncing else {
            let Some(client) = self.client.clone() else {
                return self.absorb(Failure::Transient("not connected".into()));
            };
            self.syncing = Some(self.spawn_sync(client));
            return Status::Running;
        };
        let failure = match syncing.exit.try_recv() {
            Err(oneshot::error::TryRecvError::Empty) => return Status::Running,
            Ok(failure) => failure,
            Err(oneshot::error::TryRecvError::Closed) => {
                Failure::Transient("sync task ended".into())
            }
        };
        self.syncing = None;
        self.absorb(failure)
    }

    fn spawn_sync(&self, client: Client) -> Syncing {
        let (exit, receiver) = oneshot::channel();
        let sync = {
            let (env, agent, wake, healthy) = (
                self.env.clone(),
                self.agent.clone(),
                Arc::clone(&self.wake),
                Arc::clone(&self.healthy),
            );
            let client = client.clone();
            let report = Arc::clone(&self.report);
            tokio::spawn(async move {
                let failure = sync_loop(client, &env, &agent, &healthy, &report).await;
                metrics::SYNC_ERRORS.add(1);
                let _ = exit.send(failure); // a halted agent no longer listens
                wake.notify_one();
            })
        };
        let outbox = {
            let (env, agent_id, wake) =
                (self.env.clone(), self.agent.id, Arc::clone(&self.outbox_wake));
            tokio::spawn(async move { outbox_worker(client, &env, agent_id, &wake).await })
        };
        Syncing { sync, outbox, exit: receiver }
    }

    fn absorb(&mut self, failure: Failure) -> Status {
        match failure {
            Failure::Transient(error) => self.fail(error),
            Failure::Fatal(error) => {
                tracing::error!(agent = %self.agent.name, %error, "giving up on agent");
                self.fatal = Some(error);
            }
            Failure::LeaseLost => self.lease_lost = true,
        }
        Status::Failure
    }

    /// A transient failure: back off, then reconnect.
    fn fail(&mut self, error: String) {
        if self.healthy.swap(false, Ordering::Relaxed) {
            self.attempts = 0;
        }
        self.attempts = self.attempts.saturating_add(1);
        let delay = backoff(self.attempts);
        tracing::warn!(agent = %self.agent.name, %error, ?delay, "agent failed; retrying");
        self.backoff_until = Some(Instant::now() + delay);
        self.pending_state = Some((State::Reconnecting, Some(error)));
    }

    async fn flush(&mut self) {
        let Some((state, error)) = self.pending_state.take() else {
            return;
        };
        report(&self.report, state, error.clone());
        if let Err(db_error) =
            agents::set_state(&self.env.db, &self.env.node, self.agent.id, state, error.as_deref())
                .await
        {
            tracing::warn!(agent = %self.agent.name, %db_error, "could not record state");
        }
    }
}

/// Runs an agent until it is disabled, stopped, loses its lease or fails
/// for good, then releases it accordingly.
pub async fn run(
    agent: Agent,
    env: Env,
    mut control: watch::Receiver<Control>,
    outbox_wake: Arc<Notify>,
    report: SharedReport,
) -> Ending {
    let wake = Arc::new(Notify::new());
    let mut tree = match Tree::new(tree()) {
        Ok(tree) => tree,
        Err(error) => {
            tracing::error!(%error, "invalid agent tree");
            return Ending::Released;
        }
    };
    control.mark_changed();
    let mut ctx = Context {
        agent,
        env,
        control,
        wake: Arc::clone(&wake),
        outbox_wake,
        report,
        client: None,
        connecting: None,
        syncing: None,
        attempts: 0,
        backoff_until: None,
        healthy: Arc::new(AtomicBool::new(false)),
        lease_lost: false,
        fatal: None,
        pending_state: None,
    };
    let origin = Instant::now();
    loop {
        let status = tree.tick(&mut ctx, Time::from_duration(origin.elapsed()));
        ctx.flush().await;
        if status != Status::Running {
            break;
        }
        let deadline = tree.next_deadline().map(|at| origin + Duration::from_nanos(at.as_nanos()));
        let wake_at = [deadline, ctx.backoff_until].into_iter().flatten().min();
        tokio::select! {
            () = wake.notified() => {}
            () = sleep_until(wake_at) => {}
            changed = ctx.control.changed() => if changed.is_err() {
                // The supervisor is gone: stop as if told to.
                break;
            },
        }
    }
    if tree.is_running() {
        tree.halt(&mut ctx);
    }
    finish(&ctx).await
}

fn tree() -> Node<Step> {
    Node::reactive_sequence([
        Node::leaf(Step::LeaseHeld),
        Node::leaf(Step::Enabled),
        Node::sequence([
            Node::leaf(Step::Backoff),
            Node::leaf(Step::Connect).timeout(CONNECT_TIMEOUT),
            Node::leaf(Step::Sync),
        ])
        .retry_until_successful(Limit::Unlimited),
    ])
}

async fn finish(ctx: &Context) -> Ending {
    let (db, node, id) = (&ctx.env.db, ctx.env.node.as_str(), ctx.agent.id);
    let ending = if ctx.lease_lost || !ctx.control.borrow().lease_held {
        Ending::LeaseLost
    } else if let Some(error) = &ctx.fatal {
        if let Err(db_error) = agents::set_state(db, node, id, State::Failed, Some(error)).await {
            tracing::warn!(agent = %ctx.agent.name, %db_error, "could not record failure");
        }
        report(&ctx.report, State::Failed, Some(error.clone()));
        Ending::Failed
    } else {
        report(&ctx.report, State::Offline, None);
        Ending::Released
    };
    if ending != Ending::LeaseLost
        && let Err(db_error) = agents::release(db, node, &[id], ending == Ending::Failed).await
    {
        tracing::warn!(agent = %ctx.agent.name, %db_error, "could not release lease");
    }
    ending
}

fn report(report: &SharedReport, state: State, error: Option<String>) {
    let mut report = report.lock().unwrap_or_else(PoisonError::into_inner);
    report.state = state;
    report.error = error;
}

async fn sleep_until(at: Option<Instant>) {
    match at {
        Some(at) => tokio::time::sleep_until(at).await,
        None => std::future::pending().await,
    }
}
