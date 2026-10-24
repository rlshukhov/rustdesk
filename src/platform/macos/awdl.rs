//! Session-scoped AWDL control. Only the root daemon can change the interface.
mod lease;

use self::lease::{Interface, Lease, State};
use base::config::keys::OPTION_MACOS_PAUSE_AWDL;
use hbb_common::{anyhow::anyhow, libc, log, tokio, ResultType};
use std::{
    ffi::CStr,
    fs::{self, File, OpenOptions},
    io::{self, Read, Write},
    os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
    path::PathBuf,
    time::Duration,
};

const IPC_TIMEOUT_MS: u64 = 500;

fn directory() -> ResultType<PathBuf> {
    let name = crate::get_app_name();
    super::super::validate_install_app_name(&name)?;
    Ok(PathBuf::from(format!("/var/run/{}-awdl", name)))
}

fn checked_directory() -> ResultType<PathBuf> {
    let directory = directory()?;
    let metadata = fs::symlink_metadata(&directory)?;
    if !metadata.is_dir() || metadata.uid() != 0 || metadata.mode() & 0o022 != 0 {
        return Err(anyhow!(
            "AWDL state directory must be owned and writable only by root"
        ));
    }
    Ok(directory)
}

fn open_state(name: &str, write: bool) -> ResultType<File> {
    let path = checked_directory()?.join(name);
    let file = OpenOptions::new()
        .read(true)
        .write(write)
        .create(write)
        .mode(if name == "status" { 0o644 } else { 0o600 })
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.uid() != 0 || metadata.mode() & 0o022 != 0 {
        return Err(anyhow!("Untrusted AWDL state file"));
    }
    Ok(file)
}

/// Public, non-sensitive status read by the macOS settings page, without new FFI.
pub(crate) fn status() -> String {
    let read = || -> ResultType<String> {
        let mut value = String::new();
        open_state("status", false)?
            .take(128)
            .read_to_string(&mut value)?;
        let mut lines = value.lines();
        let pid = lines
            .next()
            .and_then(|v| v.parse::<i32>().ok())
            .filter(|v| *v > 0)
            .ok_or_else(|| anyhow!("Missing AWDL daemon PID"))?;
        if unsafe { libc::kill(pid, 0) } != 0
            && io::Error::last_os_error().kind() != io::ErrorKind::PermissionDenied
        {
            return Err(anyhow!("AWDL daemon is not running"));
        }
        match lines.next() {
            Some(value @ ("ready" | "paused" | "already-down" | "error")) => Ok(value.to_owned()),
            _ => Err(anyhow!("Unsupported AWDL service status")),
        }
    };
    read().unwrap_or_else(|_| "unavailable".to_owned())
}

struct SystemInterface {
    directory: PathBuf,
    // Kept open for the lifetime of the daemon task, excluding another controller.
    _lock: File,
}

impl SystemInterface {
    fn new() -> ResultType<Self> {
        let path = directory()?;
        match fs::create_dir(&path) {
            Ok(()) => fs::set_permissions(&path, fs::Permissions::from_mode(0o755))?,
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error.into()),
        }
        let directory = checked_directory()?;
        let lock = open_state("lock", true)?;
        if unsafe {
            libc::flock(
                std::os::unix::io::AsRawFd::as_raw_fd(&lock),
                libc::LOCK_EX | libc::LOCK_NB,
            )
        } != 0
        {
            return Err(io::Error::last_os_error().into());
        }
        Ok(Self {
            directory,
            _lock: lock,
        })
    }

    fn publish(&self, status: &str) -> ResultType<()> {
        let mut file = open_state("status", true)?;
        file.set_len(0)?;
        write!(file, "{}\n{}\n", std::process::id(), status)?;
        Ok(())
    }

    fn restore_pending(&self) -> ResultType<bool> {
        match open_state("restore-up", false) {
            Ok(mut file) => {
                let mut value = String::new();
                file.read_to_string(&mut value)?;
                if value != "restore-up\n" {
                    return Err(anyhow!("Invalid AWDL recovery marker"));
                }
                Ok(true)
            }
            Err(error)
                if error.downcast_ref::<io::Error>().map(|e| e.kind())
                    == Some(io::ErrorKind::NotFound) =>
            {
                Ok(false)
            }
            Err(error) => Err(error),
        }
    }
}

impl Interface for SystemInterface {
    async fn is_up(&mut self) -> io::Result<bool> {
        let mut addresses = std::ptr::null_mut();
        if unsafe { libc::getifaddrs(&mut addresses) } != 0 {
            return Err(io::Error::last_os_error());
        }
        let mut current = addresses;
        let mut up = None;
        while !current.is_null() {
            let entry = unsafe { &*current };
            if !entry.ifa_name.is_null()
                && unsafe { CStr::from_ptr(entry.ifa_name) }.to_bytes() == b"awdl0"
            {
                up = Some(entry.ifa_flags & libc::IFF_UP as u32 != 0);
                break;
            }
            current = entry.ifa_next;
        }
        unsafe { libc::freeifaddrs(addresses) };
        up.ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "awdl0 is unavailable"))
    }

    async fn set_up(&mut self, up: bool) -> io::Result<()> {
        let mut command = tokio::process::Command::new("/sbin/ifconfig");
        command
            .args(["awdl0", if up { "up" } else { "down" }])
            .env_clear()
            .stdin(std::process::Stdio::null())
            .kill_on_drop(true);
        let output = tokio::time::timeout(Duration::from_secs(2), command.output())
            .await
            .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "ifconfig timed out"))??;
        if !output.status.success() {
            return Err(io::Error::new(
                io::ErrorKind::Other,
                format!(
                    "ifconfig failed: {}",
                    String::from_utf8_lossy(&output.stderr).trim()
                ),
            ));
        }
        if self.is_up().await? != up {
            return Err(io::Error::new(
                io::ErrorKind::Other,
                "AWDL did not reach the requested state",
            ));
        }
        Ok(())
    }

    fn mark_restore(&mut self) -> io::Result<()> {
        let mut file = open_state("restore-up", true).map_err(io::Error::other)?;
        file.set_len(0)?;
        file.write_all(b"restore-up\n")?;
        file.sync_all()?;
        File::open(&self.directory)?.sync_all()
    }

    fn clear_restore(&mut self) -> io::Result<()> {
        fs::remove_file(self.directory.join("restore-up"))?;
        File::open(&self.directory)?.sync_all()
    }
}

async fn user_wants_pause(uid: u32) -> ResultType<bool> {
    use crate::ipc::Data;
    let mut connection = crate::ipc::connect_for_uid(IPC_TIMEOUT_MS, uid, "").await?;
    connection.send(&Data::Options(None)).await?;
    match connection.next_timeout(IPC_TIMEOUT_MS).await? {
        Some(Data::Options(Some(options)))
            if options.get(OPTION_MACOS_PAUSE_AWDL).map(String::as_str) == Some("Y")
                && options.get("stop-service").map(String::as_str) != Some("Y") => {}
        _ => return Ok(false),
    }
    connection.send(&Data::VideoConnCount(None)).await?;
    Ok(
        matches!(connection.next_timeout(IPC_TIMEOUT_MS).await?, Some(Data::VideoConnCount(Some(count))) if count > 0),
    )
}

async fn desired() -> bool {
    let Ok(uids) = tokio::task::spawn_blocking(super::get_logged_in_uids).await else {
        return false;
    };
    for uid in uids {
        if matches!(
            tokio::time::timeout(Duration::from_millis(750), user_wants_pause(uid)).await,
            Ok(Ok(true))
        ) {
            return true;
        }
    }
    false
}

pub(crate) fn start() {
    if unsafe { libc::geteuid() } != 0 {
        return;
    }
    tokio::spawn(async {
        if let Err(error) = run().await {
            log::error!("[awdl] Controller could not start: {}", error);
        }
    });
}

async fn run() -> ResultType<()> {
    use tokio::signal::unix::{signal, SignalKind};
    let mut interface = SystemInterface::new()?;
    let restore_pending = interface.restore_pending()?;
    let mut terminate = signal(SignalKind::terminate())?;
    let mut interrupt = signal(SignalKind::interrupt())?;
    let mut lease = Lease::default();
    if restore_pending {
        lease.state = State::RestorePending;
        if let Err(error) = lease.restore(&mut interface).await {
            log::error!("[awdl] Startup recovery failed; will retry: {}", error);
        }
    }
    let mut previous_status = String::new();
    let mut tick = tokio::time::interval(Duration::from_secs(1));
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    loop {
        tokio::select! {
            _ = terminate.recv() => break,
            _ = interrupt.recv() => break,
            _ = tick.tick() => {
                let active = tokio::time::timeout(Duration::from_secs(3), desired()).await.unwrap_or(false);
                let result = lease.update(active, &mut interface).await;
                let failed = result.is_err();
                if let Err(error) = result {
                    hbb_common::throttled_log!(Duration::from_secs(60), warn, "[awdl] Interface control failed: {}", error);
                }
                let status = if failed { "error" } else { match lease.state {
                    State::Idle => "ready",
                    State::Paused => "paused",
                    State::AlreadyDown => "already-down",
                    State::Blocked | State::RestorePending => "error",
                }};
                if status != previous_status {
                    match interface.publish(status) {
                        Ok(()) => {
                            hbb_common::throttled_log!(Duration::from_secs(5), info, "[awdl] {}", status);
                            previous_status = status.to_owned();
                        }
                        Err(error) => hbb_common::throttled_log!(Duration::from_secs(60), warn, "[awdl] Status publication failed: {}", error),
                    }
                }
            }
        }
    }
    // launchd gives the daemon a termination grace period before removing its job.
    for _ in 0..3 {
        if lease.restore(&mut interface).await.is_ok() {
            break;
        }
    }
    if matches!(lease.state, State::RestorePending | State::Paused) {
        log::error!("[awdl] Restore failed during shutdown; recovery marker retained");
    }
    if let Err(error) = fs::remove_file(interface.directory.join("status")) {
        log::warn!("[awdl] Failed to remove service status: {}", error);
    }
    std::process::exit(0);
}
