//! Shared by the integration tests. (`mod.rs`, not `common.rs`: as a file
//! of its own under tests/ it would build as a test binary.)

// Each test binary uses a different part.
#![allow(dead_code)]
// Test support: a panic here is a failed test, which is what unwrap is for.
#![allow(clippy::unwrap_used, clippy::expect_used)]

pub mod sink;

use sqlx::PgPool;
use sqlx::postgres::PgPoolOptions;
use uuid::Uuid;

const SCHEMA_SQL: &str = include_str!("../schema.sql");

/// A database schema of its own, loaded from the Rails engine's snapshot.
pub struct TestDb {
    pub pool: PgPool,
    schema: String,
    url: String,
}

impl TestDb {
    /// `None` when Postgres is unreachable outside CI; in CI that panics.
    pub async fn new() -> Option<Self> {
        let url =
            std::env::var("ACTIVEMATRIX_TEST_DATABASE_URL").expect("set in .cargo/config.toml");
        let admin = match connect_creating(&url).await {
            Ok(admin) => admin,
            Err(error) if std::env::var_os("CI").is_none() => {
                eprintln!(
                    "skipping: test database unreachable ({error}); run `docker compose up -d`"
                );
                return None;
            }
            Err(error) => panic!("test database unreachable in CI: {error}"),
        };
        let schema = format!("t_{}", Uuid::now_v7().simple());
        sqlx::query(sqlx::AssertSqlSafe(format!("CREATE SCHEMA {schema}")))
            .execute(&admin)
            .await
            .unwrap();
        admin.close().await;

        let search_path = schema.clone();
        let pool = PgPoolOptions::new()
            .max_connections(8)
            .after_connect(move |conn, _| {
                let search_path = search_path.clone();
                Box::pin(async move {
                    sqlx::query(sqlx::AssertSqlSafe(format!("SET search_path TO {search_path}")))
                        .execute(conn)
                        .await?;
                    Ok(())
                })
            })
            .connect(&url)
            .await
            .unwrap();
        // The snapshot qualifies every name with `public.` and clears the
        // search path; point both at this test's schema instead.
        let sql = SCHEMA_SQL
            .replace("SELECT pg_catalog.set_config('search_path', '', false);", "")
            .replace("public.", &format!("{schema}."));
        sqlx::raw_sql(sqlx::AssertSqlSafe(sql)).execute(&pool).await.unwrap();
        Some(Self { pool, schema, url })
    }

    pub fn url(&self) -> &str {
        &self.url
    }

    pub fn schema(&self) -> &str {
        &self.schema
    }

    /// An agent row as Rails creates it, plus a sealed token so it is
    /// claimable. Returns its id.
    pub async fn agent(&self, name: &str, homeserver_url: &str, ciphertext: Option<&[u8]>) -> Uuid {
        sqlx::query_scalar(
            "INSERT INTO active_matrix_agents (name, bot_class, homeserver_url,
             access_token_ciphertext, created_at, updated_at)
             VALUES ($1, 'EchoBot', $2, $3, now(), now()) RETURNING id",
        )
        .bind(name)
        .bind(homeserver_url)
        .bind(ciphertext)
        .fetch_one(&self.pool)
        .await
        .unwrap()
    }

    pub async fn drop_schema(self) {
        let schema = self.schema.clone();
        self.pool.close().await;
        let admin = PgPool::connect(&self.url).await.unwrap();
        sqlx::query(sqlx::AssertSqlSafe(format!("DROP SCHEMA {schema} CASCADE")))
            .execute(&admin)
            .await
            .unwrap();
        admin.close().await;
    }
}

/// Connects, creating the database first if it does not exist yet. Gives up
/// after a few seconds rather than the pool's 30.
async fn connect_creating(url: &str) -> Result<PgPool, sqlx::Error> {
    let connect = |url: String| async move {
        PgPoolOptions::new().acquire_timeout(std::time::Duration::from_secs(5)).connect(&url).await
    };
    match connect(url.to_owned()).await {
        Err(sqlx::Error::Database(error)) if error.code().as_deref() == Some("3D000") => {
            let (server, database) = url.rsplit_once('/').expect("URL has a database");
            let postgres = connect(format!("{server}/postgres")).await?;
            let created = sqlx::query(sqlx::AssertSqlSafe(format!("CREATE DATABASE {database}")))
                .execute(&postgres)
                .await;
            postgres.close().await;
            // Another test binary may have created it in the meantime.
            if let Err(error) = created
                && !error.to_string().contains("already exists")
            {
                return Err(error);
            }
            connect(url.to_owned()).await
        }
        other => other,
    }
}

impl TestDb {
    /// A URL whose connections land in this test's schema, for the daemon.
    pub fn scoped_url(&self) -> String {
        let separator = if self.url.contains('?') { '&' } else { '?' };
        format!("{}{separator}options=-c%20search_path%3D{}", self.url, self.schema)
    }
}

/// Waits until `check` returns true, polling every 50ms, or panics.
pub async fn eventually<F, Fut>(what: &str, timeout: std::time::Duration, mut check: F)
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = bool>,
{
    let deadline = tokio::time::Instant::now() + timeout;
    while !check().await {
        assert!(tokio::time::Instant::now() < deadline, "timed out waiting for {what}");
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
}
