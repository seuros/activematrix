//! Stands in for the Rails delivery endpoint: records every push.

use std::convert::Infallible;
use std::sync::{Arc, Mutex};

use rama::graceful::Shutdown;
use rama::http::body::util::BodyExt;
use rama::http::server::HttpServer;
use rama::http::{Body, Request, Response, StatusCode};
use rama::rt::Executor;
use rama::service::service_fn;
use rama::tcp::server::TcpListener;

#[derive(Debug, Clone)]
pub struct Push {
    pub timestamp: String,
    pub signature: String,
    pub body: String,
}

pub struct Sink {
    pub url: String,
    pushes: Arc<Mutex<Vec<Push>>>,
    _stop: tokio::sync::oneshot::Sender<()>,
}

impl Sink {
    pub async fn start() -> Self {
        let pushes = Arc::new(Mutex::new(Vec::new()));
        let (stop, stopped) = tokio::sync::oneshot::channel::<()>();
        let graceful = Shutdown::new(async move {
            let _ = stopped.await;
        });
        let executor = Executor::graceful(graceful.guard());
        let listener = TcpListener::bind_address("127.0.0.1:0", executor.clone()).await.unwrap();
        let url = format!("http://{}/active_matrix/deliveries", listener.local_addr().unwrap());
        let recorded = Arc::clone(&pushes);
        let app = service_fn(move |request: Request| {
            let recorded = Arc::clone(&recorded);
            async move {
                let header = |name: &str| {
                    request
                        .headers()
                        .get(name)
                        .and_then(|v| v.to_str().ok())
                        .unwrap_or_default()
                        .to_owned()
                };
                let (timestamp, signature) =
                    (header("x-activematrix-timestamp"), header("x-activematrix-signature"));
                let body = request
                    .into_body()
                    .collect()
                    .await
                    .map(rama::http::body::util::Collected::to_bytes)
                    .unwrap_or_default();
                recorded.lock().unwrap().push(Push {
                    timestamp,
                    signature,
                    body: String::from_utf8_lossy(&body).into_owned(),
                });
                Ok::<_, Infallible>(
                    Response::builder().status(StatusCode::ACCEPTED).body(Body::empty()).unwrap(),
                )
            }
        });
        tokio::spawn(async move {
            listener.serve(HttpServer::auto(executor).service(app)).await;
        });
        Self { url, pushes, _stop: stop }
    }

    pub fn pushes(&self) -> Vec<Push> {
        self.pushes.lock().unwrap().clone()
    }
}
