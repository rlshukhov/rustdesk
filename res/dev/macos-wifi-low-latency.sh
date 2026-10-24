#!/bin/bash
set -euo pipefail

duration_seconds="${1:-900}"
if [[ $# -gt 1 || ! "$duration_seconds" =~ ^[1-9][0-9]*$ ]]; then
    echo "Usage: bash $0 [seconds, default 900]" >&2
    exit 2
fi
if [[ "$(uname -s)" != Darwin ]]; then
    echo "Требуется macOS." >&2
    exit 1
fi
if [[ $EUID -ne 0 ]]; then
    exec sudo /bin/bash "$0" "$duration_seconds"
fi

awdl_state="$(/sbin/ifconfig awdl0)"
if [[ "${awdl_state%%$'\n'*}" != *'<UP,'* ]]; then
    echo "AWDL уже выключен."
    exit 0
fi

restore_awdl() {
    /sbin/ifconfig awdl0 up
    echo "AWDL включён обратно."
}
trap restore_awdl EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

/sbin/ifconfig awdl0 down
echo "AWDL выключен на $duration_seconds с; использующие его функции AirDrop/Continuity недоступны."
echo "Ctrl+C завершает режим и включает AWDL обратно."
sleep "$duration_seconds"
