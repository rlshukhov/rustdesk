use std::io;

pub(super) trait Interface {
    async fn is_up(&mut self) -> io::Result<bool>;
    async fn set_up(&mut self, up: bool) -> io::Result<()>;
    fn mark_restore(&mut self) -> io::Result<()>;
    fn clear_restore(&mut self) -> io::Result<()>;
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub(super) enum State {
    #[default]
    Idle,
    Paused,
    AlreadyDown,
    Blocked,
    RestorePending,
}

#[derive(Default)]
pub(super) struct Lease {
    pub state: State,
}

impl Lease {
    pub async fn restore(&mut self, interface: &mut impl Interface) -> io::Result<()> {
        if matches!(self.state, State::Paused | State::RestorePending) {
            self.state = State::RestorePending;
            interface.set_up(true).await?;
            interface.clear_restore()?;
        }
        self.state = State::Idle;
        Ok(())
    }

    pub async fn update(&mut self, active: bool, interface: &mut impl Interface) -> io::Result<()> {
        if !active {
            return self.restore(interface).await;
        }
        match self.state {
            State::Idle => {
                // A failed attempt stays blocked until the session ends or the option is disabled.
                self.state = State::Blocked;
                if !interface.is_up().await? {
                    self.state = State::AlreadyDown;
                    return Ok(());
                }
                interface.mark_restore()?;
                self.state = State::RestorePending;
                interface.set_up(false).await?;
                self.state = State::Paused;
            }
            State::Paused if interface.is_up().await? => {
                // macOS can re-enable AWDL during a session. The daemon polls at most once
                // per second; keep the original restore marker while reapplying the opt-in.
                self.state = State::RestorePending;
                interface.set_up(false).await?;
                self.state = State::Paused;
            }
            State::RestorePending => {
                self.restore(interface).await?;
                self.state = State::Blocked;
            }
            _ => {}
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Device {
        up: bool,
        marker: bool,
        changes: Vec<bool>,
        fail_down: bool,
    }

    impl Interface for Device {
        async fn is_up(&mut self) -> io::Result<bool> {
            Ok(self.up)
        }
        async fn set_up(&mut self, up: bool) -> io::Result<()> {
            if !up && self.fail_down {
                return Err(io::ErrorKind::PermissionDenied.into());
            }
            self.up = up;
            self.changes.push(up);
            Ok(())
        }
        fn mark_restore(&mut self) -> io::Result<()> {
            self.marker = true;
            Ok(())
        }
        fn clear_restore(&mut self) -> io::Result<()> {
            self.marker = false;
            Ok(())
        }
    }

    fn device(up: bool) -> Device {
        Device {
            up,
            marker: false,
            changes: vec![],
            fail_down: false,
        }
    }

    #[hbb_common::tokio::test]
    async fn restores_only_after_the_last_session_and_preserves_original_down_state() {
        for initially_up in [true, false] {
            let mut interface = device(initially_up);
            let mut lease = Lease::default();
            for count in [0, 1, 2, 1, 0] {
                lease.update(count > 0, &mut interface).await.unwrap();
                assert_eq!(interface.up, initially_up && count == 0);
            }
            assert_eq!(
                interface.changes,
                if initially_up {
                    vec![false, true]
                } else {
                    vec![]
                }
            );
            assert!(!interface.marker);
        }
    }

    #[hbb_common::tokio::test]
    async fn disabling_or_losing_the_server_and_daemon_recovery_restore_awdl() {
        let mut interface = device(true);
        let mut lease = Lease::default();
        lease.update(true, &mut interface).await.unwrap();
        assert!(interface.marker);
        // Recovery reconstructs the lease from its durable intent marker.
        let mut recovered = Lease {
            state: State::RestorePending,
        };
        recovered.restore(&mut interface).await.unwrap();
        assert!(interface.up);
        assert!(!interface.marker);
        lease = Lease::default();
        lease.update(true, &mut interface).await.unwrap();
        lease.update(false, &mut interface).await.unwrap();
        assert!(interface.up);
    }

    #[hbb_common::tokio::test]
    async fn command_errors_restore_and_external_reenable_is_paused_again() {
        let mut interface = device(true);
        interface.fail_down = true;
        let mut lease = Lease::default();
        assert!(lease.update(true, &mut interface).await.is_err());
        lease.update(true, &mut interface).await.unwrap();
        assert!(interface.up);
        assert!(!interface.marker);
        lease.update(true, &mut interface).await.unwrap();
        assert_eq!(interface.changes, vec![true]);
        lease.update(false, &mut interface).await.unwrap();
        interface.fail_down = false;
        lease.update(true, &mut interface).await.unwrap();
        interface.up = true;
        lease.update(true, &mut interface).await.unwrap();
        lease.update(true, &mut interface).await.unwrap();
        assert!(!interface.up);
        assert!(interface.marker);
        assert_eq!(interface.changes, vec![true, false, false]);
        lease.update(false, &mut interface).await.unwrap();
        assert!(interface.up);
        assert!(!interface.marker);
    }
}
