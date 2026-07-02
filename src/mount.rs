//! Mount runtime — the host side of the Bridge tier-4 protocol.
//!
//! A `MountSession` owns a spawned sibling subprocess + a Unix
//! socket connection to it. The sibling streams `Frame` messages
//! (cells + style) over the socket; mnml stamps them into its own
//! `ratatui::Frame` so the host terminal does the actual glyph
//! rendering.
//!
//! Lifecycle:
//!   1. `MountSession::spawn(profile)` binds a UDS in a temp path,
//!      sets `MNML_MOUNT_SOCKET` on the profile, and forks the
//!      sibling.
//!   2. A worker thread accepts the connect, sends a `Hello` with
//!      the initial geometry, then loops on `read_message` —
//!      decoded frames are pushed into `MountSession::frame_rx`.
//!   3. The render loop calls `MountSession::pump()` once per
//!      frame, which drains the channel into `latest_frame`.
//!   4. The pane's render fn reads `latest_frame` and stamps it
//!      into the ratatui buffer.
//!   5. Input flows the other way via `MountSession::send_input`
//!      which writes a `HostMessage::Input` to the socket.
//!
//! The socket lives at
//! `<MNML_IPC_DIR>/mounts/<id>.sock`; the id is a monotonic
//! counter so successive mounts in the same session don't collide.

use std::io::Write;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::{Receiver, Sender, TryRecvError};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use mnml_bridge::{Cell, Geometry, HostMessage, InputEvent, SiblingMessage};

static NEXT_MOUNT_ID: AtomicUsize = AtomicUsize::new(0);

/// A single hosted-sibling mount.
pub struct MountSession {
    /// The sibling subprocess (`Child::wait` is used to detect
    /// crashes; we don't stream stdout/stderr — siblings using
    /// Mount don't print to a terminal).
    pub child: std::process::Child,
    /// The socket path mnml is listening on. Deleted when the
    /// mount drops.
    pub socket_path: PathBuf,
    /// The connected write half — used to push `HostMessage`s to
    /// the sibling. `None` until the sibling has connected.
    pub writer: Arc<Mutex<Option<UnixStream>>>,
    /// Channel the reader thread feeds with decoded `Frame`s.
    pub frame_rx: Receiver<SiblingMessage>,
    /// The latest accepted frame — rendered each tick. None until
    /// the sibling sends its first Frame.
    pub latest_frame: Option<Vec<Vec<Cell>>>,
    /// Current geometry the sibling has been told about (so we
    /// can detect resize and emit `HostMessage::Resize`).
    pub geometry: Geometry,
    /// Label for the pane chrome ("custom-tests", "runs", …).
    pub label: String,
    /// True once the sibling closed its socket (clean exit or crash).
    pub disconnected: bool,
}

/// Errors during `MountSession::spawn`.
#[derive(Debug)]
pub enum MountError {
    Io(std::io::Error),
    SpawnFailed(std::io::Error),
    BindFailed(std::io::Error, PathBuf),
}

impl std::fmt::Display for MountError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            MountError::Io(e) => write!(f, "mount IO: {e}"),
            MountError::SpawnFailed(e) => write!(f, "mount spawn: {e}"),
            MountError::BindFailed(e, p) => write!(f, "mount bind {}: {e}", p.display()),
        }
    }
}

/// Where the per-mount UDS lives — under the workspace IPC dir.
pub fn mounts_dir(workspace: &std::path::Path) -> PathBuf {
    workspace.join(".mnml").join("ipc").join("mounts")
}

impl MountSession {
    /// Spawn a sibling and bind the UDS. The sibling reads
    /// `MNML_MOUNT_SOCKET` from env and connects to it. The
    /// accept happens on a worker thread so spawn returns
    /// immediately; the first frame may not arrive for a few
    /// hundred ms.
    pub fn spawn(
        workspace: &std::path::Path,
        label: String,
        exe: &str,
        args: &[String],
        env: &[(String, String)],
        cwd: Option<&std::path::Path>,
        geometry: Geometry,
    ) -> Result<Self, MountError> {
        let dir = mounts_dir(workspace);
        std::fs::create_dir_all(&dir).map_err(MountError::Io)?;
        let id = NEXT_MOUNT_ID.fetch_add(1, Ordering::Relaxed);
        let pid = std::process::id();
        let socket_path = dir.join(format!("{pid}-{id}.sock"));
        // Stale file from a prior session of this same pid+id
        // would block bind; remove it.
        let _ = std::fs::remove_file(&socket_path);
        let listener = UnixListener::bind(&socket_path)
            .map_err(|e| MountError::BindFailed(e, socket_path.clone()))?;
        listener.set_nonblocking(true).map_err(MountError::Io)?;
        let writer: Arc<Mutex<Option<UnixStream>>> = Arc::new(Mutex::new(None));
        let (frame_tx, frame_rx) = std::sync::mpsc::channel();

        // Worker thread: accept + read messages.
        let writer_clone = writer.clone();
        thread::spawn(move || {
            accept_and_read(listener, writer_clone, frame_tx, geometry);
        });

        // Spawn the sibling. `MNML_MOUNT_SOCKET` is the contract.
        let mut cmd = std::process::Command::new(exe);
        cmd.args(args);
        for (k, v) in env {
            cmd.env(k, v);
        }
        cmd.env("MNML_MOUNT_SOCKET", socket_path.display().to_string());
        if let Some(c) = cwd {
            cmd.current_dir(c);
        }
        // Capture stderr so a crashing sibling's panic trace is
        // visible; stdout is unused for Mount siblings.
        cmd.stdin(std::process::Stdio::null());
        cmd.stdout(std::process::Stdio::null());
        cmd.stderr(std::process::Stdio::piped());
        let child = cmd.spawn().map_err(MountError::SpawnFailed)?;

        Ok(MountSession {
            child,
            socket_path,
            writer,
            frame_rx,
            latest_frame: None,
            geometry,
            label,
            disconnected: false,
        })
    }

    /// Drain pending frames + check for sibling exit. Call once
    /// per tick. Updates `latest_frame` + `disconnected`.
    pub fn pump(&mut self) {
        loop {
            match self.frame_rx.try_recv() {
                Ok(SiblingMessage::Frame { cells }) => {
                    self.latest_frame = Some(cells);
                }
                Ok(SiblingMessage::Bye) => {
                    self.disconnected = true;
                    break;
                }
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => {
                    self.disconnected = true;
                    break;
                }
            }
        }
        if !self.disconnected
            && let Ok(Some(_)) = self.child.try_wait()
        {
            self.disconnected = true;
        }
    }

    /// Forward a key/mouse event to the sibling. Best-effort —
    /// IO errors mark the session disconnected.
    pub fn send_input(&mut self, event: InputEvent) {
        let msg = HostMessage::Input { event };
        if let Err(_e) = self.write_message(&msg) {
            self.disconnected = true;
        }
    }

    /// Tell the sibling the area resized.
    pub fn resize(&mut self, geometry: Geometry) {
        if self.geometry.cols == geometry.cols && self.geometry.rows == geometry.rows {
            return;
        }
        self.geometry = geometry;
        let msg = HostMessage::Resize { geometry };
        if let Err(_e) = self.write_message(&msg) {
            self.disconnected = true;
        }
    }

    fn write_message(&self, msg: &HostMessage) -> std::io::Result<()> {
        let guard = self
            .writer
            .lock()
            .map_err(|e| std::io::Error::other(format!("mount writer mutex: {e}")))?;
        let Some(stream) = guard.as_ref() else {
            return Err(std::io::Error::new(
                std::io::ErrorKind::NotConnected,
                "mount: sibling has not connected yet",
            ));
        };
        let mut s = stream.try_clone()?;
        mnml_bridge::write_message(&mut s, msg)?;
        s.flush()?;
        Ok(())
    }
}

impl Drop for MountSession {
    fn drop(&mut self) {
        // Send Goodbye if still connected — siblings can clean up
        // gracefully (close DB connections etc.) before the socket
        // dies.
        let _ = self.write_message(&HostMessage::Goodbye);
        // Then kill the process; the socket file goes too.
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_file(&self.socket_path);
    }
}

/// Worker thread: accept once, then loop reading `SiblingMessage`s.
fn accept_and_read(
    listener: UnixListener,
    writer: Arc<Mutex<Option<UnixStream>>>,
    frame_tx: Sender<SiblingMessage>,
    geometry: Geometry,
) {
    // Poll-accept with a short backoff — the sibling typically
    // connects within 100-300ms, but we don't want to busy-loop.
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    let stream = loop {
        match listener.accept() {
            Ok((s, _addr)) => break s,
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                if std::time::Instant::now() > deadline {
                    // Sibling never connected — give up. The pane
                    // will show "sibling exited" once the parent
                    // notices.
                    return;
                }
                thread::sleep(Duration::from_millis(50));
            }
            Err(_) => return,
        }
    };
    // We need a duplicate handle: one for the reader thread to
    // read from, one stashed for the host to write into.
    let writer_stream = match stream.try_clone() {
        Ok(s) => s,
        Err(_) => return,
    };
    // Send Hello with the initial geometry + theme name.
    {
        let hello = HostMessage::Hello {
            geometry,
            theme: std::env::var("MNML_THEME").unwrap_or_else(|_| "cyberdream".to_string()),
        };
        let mut w = writer_stream;
        if mnml_bridge::write_message(&mut w, &hello).is_err() {
            return;
        }
        if w.flush().is_err() {
            return;
        }
        if let Ok(mut g) = writer.lock() {
            *g = Some(w);
        }
    }
    // Read loop.
    let mut reader = stream;
    loop {
        match mnml_bridge::read_message::<_, SiblingMessage>(&mut reader) {
            Ok(Some(msg)) => {
                if frame_tx.send(msg).is_err() {
                    return;
                }
            }
            Ok(None) | Err(_) => {
                // Clean EOF or transport error — drop, host
                // notices via the channel's Disconnected error.
                return;
            }
        }
    }
}
