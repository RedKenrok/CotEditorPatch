#!/usr/bin/env bash
# Runs local SFTP test servers for the remote build's tests: the system's sshd, as the current user.
#
#   scripts/remote-fixture.sh start [DIR]   (default: .build/remote-fixture)
#   scripts/remote-fixture.sh stop [DIR]
#
# Everything lives in DIR: fresh host and client keys, authorized_keys, the sshd configurations, a
# known_hosts file built from the fixture's own host key, a client ssh_config, the data folder, the
# process IDs and the logs. Nothing of the developer's own SSH configuration, keys or agent is used.
#
# Two servers listen on 127.0.0.1:
#   - one that offers only SFTP (internal-sftp, forced), so tests prove that no shell is needed;
#   - one without an SFTP subsystem, whose sessions run /usr/bin/false.
#
# Paths in the configurations are quoted, since the repository may live in a folder with spaces. sshd
# and ssh refuse key paths with a space even when quoted, so the configurations reach the folder
# through a link in the temporary folder instead.
#
# The client ssh_config defines these hosts:
#   fixture           the SFTP server
#   fixture-command   the same, with a RemoteCommand that CotEditor must override
#   fixture-unknown   the same, with an empty known_hosts file, so the host key is unknown
#   fixture-nosftp    the server without SFTP, which forwards connections to the SFTP server's port only
#   fixture-shell     a third server, which runs a shell with a terminal, as /bin/sh whatever the account's
#                     login shell is, for the tests of remote terminals
#   fixture-jump      the same as fixture, through fixture-nosftp as its ProxyJump
#   fixture-chained   the same, through fixture-jump as its ProxyJump, which CotEditor must refuse, since
#                     that jump host has a ProxyJump of its own
#   fixture-rotated   the same as fixture, with a known_hosts file whose key for it has since been replaced
#   fixture-trust     the same as fixture, with a known_hosts file of its own, empty at the start, where a
#                     test adds the key it trusts
#   fixture-locked    the same as fixture, signing in with the locked client key, whose passphrase ssh asks for
#   fixture-proxy     the SFTP server reached through 127.0.0.1 at the port in `proxy-port`, where a test
#                     runs a relay of its own to the SFTP server's port, in `sftp-port`, that it can
#                     cut on cue; nothing listens there otherwise
#
# The data folder has a folder `readonly` that the user cannot write, with a file `locked.txt` in it
# that the user cannot write either, and a folder `tree` for browsing:
#   src/app.js, src/lib/util.js   nested folders
#   empty/                        an empty folder
#   unreadable/                   a folder the user cannot list
#   large/                        30 files, more than a test's small listing limit
#   .hidden                       a hidden file
#   cafe<U+0301>.txt              a name in decomposed form (APFS cannot hold it beside the composed
#                                 form, so that pair is tested against the fake server only)
#   link-to-src -> src            a link to a folder inside the tree
#   loop -> .                     a link to the folder that contains it
#   outside -> ../readonly        a link to a folder outside the tree
#
# While the servers run, scripts/build.sh passes DIR to the tests, which then also run against them.
# `stop` ends only the sshd processes whose IDs were recorded here, and keeps the logs.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() { echo "Usage: $0 start|stop [DIR]" >&2; exit 2; }

[[ $# -ge 1 && $# -le 2 ]] || usage
command="$1"
fixture="${2:-$build_root/remote-fixture}"

free_port() {
    python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

# Ends a recorded sshd, only if the process with that ID is still an sshd.
stop_server() {
    local pid_file="$1" pid
    [[ -f "$pid_file" ]] || return 0
    pid="$(cat "$pid_file")"
    if [[ "$pid" =~ ^[0-9]+$ ]] && ps -p "$pid" -o comm= 2>/dev/null | grep -q sshd; then
        kill "$pid"
        note "stopped sshd $pid"
    fi
    rm -f "$pid_file"
}

case "$command" in
    start)
        if [[ -f "$fixture/sshd.pid" ]] && kill -0 "$(cat "$fixture/sshd.pid")" 2>/dev/null; then
            die "the fixture is already running in $fixture; stop it first"
        fi
        mkdir -p "$fixture"
        fixture="$(cd "$fixture" && pwd)"
        # Keys and configurations are made fresh each time; data and logs of earlier runs go.
        [[ -d "$fixture/data/readonly" ]] && chmod 755 "$fixture/data/readonly"
        [[ -d "$fixture/data/tree/unreadable" ]] && chmod 755 "$fixture/data/tree/unreadable"
        rm -rf "$fixture/data" "$fixture"/*.log
        rm -f "$fixture"/host_key* "$fixture"/other_host_key* "$fixture"/client_key* "$fixture"/authorized_keys "$fixture"/known_hosts* "$fixture"/*_config "$fixture/proxy-port" "$fixture/sftp-port"
        mkdir -p "$fixture/data/readonly"
        chmod 700 "$fixture"

        ssh-keygen -q -t ed25519 -N '' -C fixture-host -f "$fixture/host_key"
        ssh-keygen -q -t ed25519 -N '' -C fixture-client -f "$fixture/client_key"
        # a key the server does not have, standing in for the one it had before its key was replaced
        ssh-keygen -q -t ed25519 -N '' -C fixture-old-host -f "$fixture/other_host_key"
        # A second client key, locked with the passphrase in `client_key_locked.passphrase`, for the tests of questions.
        echo "fixture passphrase" > "$fixture/client_key_locked.passphrase"
        ssh-keygen -q -t ed25519 -N "fixture passphrase" -C fixture-locked -f "$fixture/client_key_locked"
        cat "$fixture/client_key.pub" "$fixture/client_key_locked.pub" > "$fixture/authorized_keys"
        chmod 600 "$fixture/authorized_keys"

        # the link that sshd's configurations go through
        link_folder="$(mktemp -d "${TMPDIR:-/tmp}/cot-tabs-fixture.XXXXXX")"
        ln -s "$fixture" "$link_folder/fixture"
        echo "$link_folder" > "$fixture/link-folder"
        server="$link_folder/fixture"

        port="$(free_port)"
        nosftp_port="$(free_port)"
        [[ "$port" != "$nosftp_port" ]] || nosftp_port="$(free_port)"
        shell_port="$(free_port)"
        while [[ "$shell_port" == "$port" || "$shell_port" == "$nosftp_port" ]]; do shell_port="$(free_port)"; done
        proxy_port="$(free_port)"
        echo "$proxy_port" > "$fixture/proxy-port"
        echo "$port" > "$fixture/sftp-port"

        # sshd drops some connections that have not signed in yet once ten are pending (MaxStartups
        # 10:30:100), and the tests sign in many at once. The limits are raised so that no test
        # connection is ever dropped for that.
        common_config="ListenAddress 127.0.0.1
MaxStartups 200
MaxSessions 100
HostKey "$server/host_key"
AuthorizedKeysFile "$server/authorized_keys"
UsePAM no
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowTcpForwarding no
X11Forwarding no"

        cat > "$fixture/sshd_config" <<EOF
$common_config
Port $port
PidFile "$server/sshd.pid"
Subsystem sftp internal-sftp
ForceCommand internal-sftp
EOF
        # A jump host forwards a connection (ssh -W) without a session, which ForceCommand does not stop.
        # sshd keeps the first value of an option, so the forwarding that the common part turns off is
        # allowed in a Match block, whose values replace it, and only to the SFTP server.
        cat > "$fixture/sshd_nosftp_config" <<EOF
$common_config
Port $nosftp_port
PidFile "$server/sshd-nosftp.pid"
ForceCommand /usr/bin/false
Match all
  AllowTcpForwarding yes
  PermitOpen 127.0.0.1:$port
EOF
        # The shell server sets SHELL for its sessions, so that the tests never run the developer's own
        # login shell and its startup files; ENV names no startup file for sh.
        cat > "$fixture/sshd_shell_config" <<EOF
$common_config
Port $shell_port
PidFile "$server/sshd-shell.pid"
PermitTTY yes
SetEnv SHELL=/bin/sh ENV=/dev/null
EOF

        host_key="$(cut -d' ' -f1-2 "$fixture/host_key.pub")"
        {
            echo "[127.0.0.1]:$port $host_key"
            echo "[127.0.0.1]:$nosftp_port $host_key"
            echo "[127.0.0.1]:$shell_port $host_key"
        } > "$fixture/known_hosts"
        : > "$fixture/known_hosts_empty"
        : > "$fixture/known_hosts_trust"
        echo "[127.0.0.1]:$port $(cut -d' ' -f1-2 "$fixture/other_host_key.pub")" > "$fixture/known_hosts_rotated"
        echo "[127.0.0.1]:$proxy_port $host_key" > "$fixture/known_hosts_proxy"

        client_common="  HostName 127.0.0.1
  User $(id -un)
  IdentityFile "$server/client_key"
  IdentitiesOnly yes
  IdentityAgent none
  GlobalKnownHostsFile /dev/null
  UpdateHostKeys no"
        cat > "$fixture/ssh_config" <<EOF
Host fixture
  Port $port
  UserKnownHostsFile "$server/known_hosts"
$client_common

Host fixture-command
  Port $port
  UserKnownHostsFile "$server/known_hosts"
  RemoteCommand /bin/echo unexpected
$client_common

Host fixture-unknown
  Port $port
  UserKnownHostsFile "$server/known_hosts_empty"
$client_common

Host fixture-nosftp
  Port $nosftp_port
  UserKnownHostsFile "$server/known_hosts"
$client_common

Host fixture-shell
  Port $shell_port
  UserKnownHostsFile "$server/known_hosts"
$client_common

Host fixture-jump
  Port $port
  UserKnownHostsFile "$server/known_hosts"
  ProxyJump fixture-nosftp
$client_common
Host fixture-chained
  Port $port
  UserKnownHostsFile "$server/known_hosts"
  ProxyJump fixture-jump
$client_common
Host fixture-locked
  Port $port
  UserKnownHostsFile "$server/known_hosts"
  HostName 127.0.0.1
  User $(id -un)
  IdentityFile "$server/client_key_locked"
  IdentitiesOnly yes
  IdentityAgent none
  GlobalKnownHostsFile /dev/null
  UpdateHostKeys no
Host fixture-trust
  Port $port
  UserKnownHostsFile "$server/known_hosts_trust"
$client_common
Host fixture-rotated
  Port $port
  UserKnownHostsFile "$server/known_hosts_rotated"
$client_common
Host fixture-proxy
  Port $proxy_port
  UserKnownHostsFile "$server/known_hosts_proxy"
$client_common
EOF

        # sshd must be started with its absolute path; -D keeps it attached, so it is sent to the background here.
        # Their standard streams are detached, so that the servers never hold the caller's output open.
        /usr/sbin/sshd -D -f "$server/sshd_config" -E "$server/sshd.log" < /dev/null > /dev/null 2>&1 &
        /usr/sbin/sshd -D -f "$server/sshd_nosftp_config" -E "$server/sshd-nosftp.log" < /dev/null > /dev/null 2>&1 &
        /usr/sbin/sshd -D -f "$server/sshd_shell_config" -E "$server/sshd-shell.log" < /dev/null > /dev/null 2>&1 &

        for _ in $(seq 50); do
            [[ -s "$fixture/sshd.pid" && -s "$fixture/sshd-nosftp.pid" && -s "$fixture/sshd-shell.pid" ]] && break
            sleep 0.1
        done
        [[ -s "$fixture/sshd.pid" && -s "$fixture/sshd-nosftp.pid" && -s "$fixture/sshd-shell.pid" ]] \
            || die "sshd did not start; see $fixture/sshd.log, $fixture/sshd-nosftp.log and $fixture/sshd-shell.log"

        # The fixture is usable only if a real SFTP session works through it.
        echo "hello" > "$fixture/data/probe.txt"
        if ! echo "get \"$fixture/data/probe.txt\" \"$fixture/probe-copy.txt\"" | /usr/bin/sftp -q -F "$fixture/ssh_config" -b - fixture >/dev/null 2>&1; then
            stop_server "$fixture/sshd.pid"
            stop_server "$fixture/sshd-nosftp.pid"
            stop_server "$fixture/sshd-shell.pid"
            die "an SFTP session through the fixture failed; see $fixture/sshd.log"
        fi
        rm -f "$fixture/data/probe.txt" "$fixture/probe-copy.txt"
        # An access control list inherited from the repository's folder would grant what the modes deny, so it goes.
        echo "read only" > "$fixture/data/readonly/locked.txt"
        chmod -N "$fixture/data/readonly/locked.txt" "$fixture/data/readonly"
        chmod 444 "$fixture/data/readonly/locked.txt"
        chmod 555 "$fixture/data/readonly"

        tree="$fixture/data/tree"
        mkdir -p "$tree/src/lib" "$tree/empty" "$tree/unreadable" "$tree/large"
        echo "app" > "$tree/src/app.js"
        echo "util" > "$tree/src/lib/util.js"
        echo "secret" > "$tree/.hidden"
        echo "decomposed" > "$tree/$(printf 'cafe\xcc\x81.txt')"
        for index in $(seq 1 30); do : > "$tree/large/file $index.txt"; done
        ln -s src "$tree/link-to-src"
        ln -s . "$tree/loop"
        ln -s ../readonly "$tree/outside"
        chmod -N "$tree/unreadable"
        chmod 000 "$tree/unreadable"

        note "SFTP fixture on 127.0.0.1:$port, without SFTP on 127.0.0.1:$nosftp_port, with a shell on 127.0.0.1:$shell_port"
        note "configuration: $fixture/ssh_config"
        echo "$fixture"
        ;;
    stop)
        [[ -d "$fixture" ]] || die "no fixture in $fixture"
        stop_server "$fixture/sshd.pid"
        stop_server "$fixture/sshd-nosftp.pid"
        stop_server "$fixture/sshd-shell.pid"
        if [[ -f "$fixture/link-folder" ]]; then
            link_folder="$(cat "$fixture/link-folder")"
            [[ -L "$link_folder/fixture" ]] && rm "$link_folder/fixture" && rmdir "$link_folder"
            rm -f "$fixture/link-folder"
        fi
        [[ -d "$fixture/data/readonly" ]] && chmod 755 "$fixture/data/readonly"
        [[ -d "$fixture/data/tree/unreadable" ]] && chmod 755 "$fixture/data/tree/unreadable"
        note "logs kept in $fixture"
        ;;
    *) usage ;;
esac
