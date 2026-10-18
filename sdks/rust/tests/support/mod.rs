#![allow(dead_code)]
use std::{
    collections::{BTreeMap, VecDeque},
    sync::Arc,
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
    sync::{Mutex, mpsc},
};
#[derive(Clone, Debug)]
pub struct Request {
    pub method: String,
    pub path: String,
    pub headers: BTreeMap<String, String>,
    pub body: Vec<u8>,
}
#[derive(Clone)]
pub struct Reply {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
    pub body_delay: Duration,
}
impl Reply {
    pub fn json(status: u16, body: impl Into<Vec<u8>>) -> Self {
        Self {
            status,
            headers: vec![("Content-Type".into(), "application/json".into())],
            body: body.into(),
            body_delay: Duration::ZERO,
        }
    }
}
pub struct Server {
    pub url: String,
    requests: mpsc::UnboundedReceiver<Request>,
    task: tokio::task::JoinHandle<()>,
}
impl Server {
    pub async fn repeating(status: u16, body: &str) -> Self {
        Self::start(vec![], Some(Reply::json(status, body))).await
    }
    pub async fn script(replies: Vec<Reply>) -> Self {
        Self::start(replies, None).await
    }
    async fn start(replies: Vec<Reply>, repeat: Option<Reply>) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let (sender, requests) = mpsc::unbounded_channel();
        let replies = Arc::new(Mutex::new(VecDeque::from(replies)));
        let task = tokio::spawn(async move {
            loop {
                let (mut stream, _) = listener.accept().await.unwrap();
                let sender = sender.clone();
                let replies = replies.clone();
                let repeat = repeat.clone();
                tokio::spawn(async move {
                    let mut raw = vec![];
                    let end = loop {
                        let mut bytes = [0; 4096];
                        let n = stream.read(&mut bytes).await.unwrap();
                        if n == 0 {
                            return;
                        }
                        raw.extend_from_slice(&bytes[..n]);
                        if let Some(i) = raw.windows(4).position(|w| w == b"\r\n\r\n") {
                            break i + 4;
                        }
                    };
                    let head = String::from_utf8_lossy(&raw[..end]);
                    let mut lines = head.split("\r\n");
                    let mut line = lines.next().unwrap().split(' ');
                    let method = line.next().unwrap().to_owned();
                    let path = line.next().unwrap().to_owned();
                    let headers: BTreeMap<String, String> = lines
                        .filter_map(|line| {
                            line.split_once(':')
                                .map(|(k, v)| (k.to_ascii_lowercase(), v.trim().into()))
                        })
                        .collect();
                    let length = headers
                        .get("content-length")
                        .and_then(|n| n.parse::<usize>().ok())
                        .unwrap_or(0);
                    while raw.len() < end + length {
                        let mut bytes = [0; 4096];
                        let n = stream.read(&mut bytes).await.unwrap();
                        if n == 0 {
                            break;
                        }
                        raw.extend_from_slice(&bytes[..n]);
                    }
                    let body = raw[end..].to_vec();
                    let _ = sender.send(Request {
                        method,
                        path,
                        headers,
                        body,
                    });
                    let reply = replies
                        .lock()
                        .await
                        .pop_front()
                        .or(repeat)
                        .unwrap_or_else(|| Reply::json(500, "{}"));
                    let mut response = format!(
                        "HTTP/1.1 {} Test\r\nContent-Length: {}\r\nConnection: close\r\n",
                        reply.status,
                        reply.body.len()
                    );
                    for (k, v) in reply.headers {
                        response.push_str(&format!("{k}: {v}\r\n"));
                    }
                    response.push_str("\r\n");
                    if stream.write_all(response.as_bytes()).await.is_err() {
                        return;
                    }
                    tokio::time::sleep(reply.body_delay).await;
                    let _ = stream.write_all(&reply.body).await;
                });
            }
        });
        Self {
            url,
            requests,
            task,
        }
    }
    pub async fn next(&mut self) -> Request {
        tokio::time::timeout(Duration::from_secs(3), self.requests.recv())
            .await
            .unwrap()
            .unwrap()
    }
    pub fn try_next(&mut self) -> Option<Request> {
        self.requests.try_recv().ok()
    }
}
impl Drop for Server {
    fn drop(&mut self) {
        self.task.abort();
    }
}
