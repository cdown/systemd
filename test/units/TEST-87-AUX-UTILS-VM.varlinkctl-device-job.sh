#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
set -eux
set -o pipefail

# shellcheck source=test/units/test-control.sh
. "$(dirname "$0")"/test-control.sh

IFNAME=vljobtest
UNIT="sys-subsystem-net-devices-$IFNAME.device"
OUTPUT=/tmp/varlinkctl-device-job.json

at_exit() {
    if [[ -n "${watcher_pid:-}" ]]; then
        kill "$watcher_pid" 2>/dev/null || true
        wait "$watcher_pid" 2>/dev/null || true
    fi
    ip link del "$IFNAME" 2>/dev/null || true
    rm -f "$OUTPUT"
}

start_watcher() {
    rm -f "$OUTPUT"
    varlinkctl --json=short call --more --timeout=infinity /run/systemd/io.systemd.Manager io.systemd.Unit.EnqueueJob \
        '{"names": ["'"$UNIT"'"], "jobType": "start", "notifyJobChanges": true}' >"$OUTPUT" &
    watcher_pid=$!

    # shellcheck disable=SC2016
    timeout 10 bash -c 'until jq --seq --slurp -e ".[0].job.Id" "$1" >/dev/null 2>&1; do sleep 0.1; done' bash "$OUTPUT"
}

testcase_device_appears() {
    trap at_exit EXIT

    # A streaming client waits on device jobs, so they should be intact.
    start_watcher
    systemctl list-jobs --no-legend "$UNIT" | grep -F "$UNIT" >/dev/null
    kill -0 "$watcher_pid"

    ip link add "$IFNAME" type dummy
    timeout 30 tail --pid="$watcher_pid" -f /dev/null
    wait "$watcher_pid"
    watcher_pid=

    jq --seq --slurp -e '.[-1].job.Result == "done"' "$OUTPUT" >/dev/null
    systemctl is-active "$UNIT"
}

testcase_client_disconnects() {
    trap at_exit EXIT

    # Once the client goes away, nobody waits for the job anymore, so it is collected.
    start_watcher
    systemctl list-jobs --no-legend "$UNIT" | grep -F "$UNIT" >/dev/null

    kill "$watcher_pid"
    wait "$watcher_pid" || true
    watcher_pid=

    # shellcheck disable=SC2016
    timeout 10 bash -c 'while systemctl list-jobs --no-legend "$1" | grep -F "$1" >/dev/null; do sleep 0.5; done' bash "$UNIT"
}

run_testcases
