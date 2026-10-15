#!/usr/bin/env bash
# Runs the verify tasks of edge, watchtower, autoheal, docker, gpu and host
# (roles/*/tasks/verify.yml) on localhost against fake docker, iptables,
# swapon, systemctl, sysctl and nvidia-smi that answer from per-case state files, and the provision
# SSH route (tasks/ssh-route.yml) for LAN, other and tailnet SSH_CONNECTION
# values. Nothing here touches the local Docker daemon, firewall, swap or
# systemd.
#
#   bash ci/verify-tasks.sh
#
# Prints "ok   ..." per case and stops with "FAIL ..." on the first failure.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/state"

cat >"$work/bin/docker" <<'SH'
#!/usr/bin/env bash
state="$FAKE_DOCKER_STATE"
case "$1 ${2:-}" in
  "container inspect")
    shift 2; format=""
    if [ "${1:-}" = "--format" ]; then format="$2"; shift 2; fi
    name="$1"
    [ -f "$state/$name.running" ] || { echo "Error: No such container: $name" >&2; exit 1; }
    read -r running restarting <"$state/$name.running"
    case "$format" in
      "") echo "[{}]" ;;
      *StartedAt*) echo "2026-10-13T10:00:00.123456789Z" ;;
      *PortBindings*) cat "$state/$name.ports" 2>/dev/null || echo "{}" ;;
      running=*) echo "running=$running restarting=$restarting" ;;
      *) echo "$running $restarting" ;;
    esac ;;
  logs*)
    shift; [ "${1:-}" = "--since" ] && shift 2
    cat "$state/$1.log" 2>/dev/null || true ;;
  "version --format")
    cat "$state/docker.version" ;;
  "info --format")
    cat "$state/docker.runtimes" ;;
  "ps --all")
    cat "$state/docker.ps" ;;
  "compose version")
    [ -f "$state/compose.missing" ] && { echo "docker: unknown command: docker compose" >&2; exit 1; }
    echo "Docker Compose version v5.6.0" ;;
  *) echo "fake docker: unsupported: $*" >&2; exit 2 ;;
esac
SH

cat >"$work/bin/iptables" <<'SH'
#!/usr/bin/env bash
[ "$*" = "-S DOCKER-USER" ] || { echo "fake iptables: unsupported: $*" >&2; exit 2; }
cat "$FAKE_DOCKER_STATE/docker-user.rules"
SH

cat >"$work/bin/swapon" <<'SH'
#!/usr/bin/env bash
[ "$*" = "--noheadings --bytes --show=SIZE" ] || { echo "fake swapon: unsupported: $*" >&2; exit 2; }
cat "$FAKE_DOCKER_STATE/swap"
SH
cat >"$work/bin/systemctl" <<'SH'
#!/usr/bin/env bash
if [ "$*" = "reload docker" ]; then
  # A reload picks up daemon.json: the runtimes Docker lists after it.
  [ -f "$FAKE_DOCKER_STATE/docker.runtimes.reloaded" ] && cp "$FAKE_DOCKER_STATE/docker.runtimes.reloaded" "$FAKE_DOCKER_STATE/docker.runtimes"
  exit 0
fi
[ "$1" = is-enabled ] || { echo "fake systemctl: unsupported: $*" >&2; exit 2; }
shift
for unit in "$@"; do
  if [ -f "$FAKE_DOCKER_STATE/$unit.enabled" ]; then cat "$FAKE_DOCKER_STATE/$unit.enabled"; else echo masked; fi
done
SH
cat >"$work/bin/sysctl" <<'SH'
#!/usr/bin/env bash
[ "$*" = "-n net.ipv4.ip_nonlocal_bind" ] || { echo "fake sysctl: unsupported: $*" >&2; exit 2; }
cat "$FAKE_DOCKER_STATE/nonlocal_bind"
SH
cat >"$work/bin/nvidia-smi" <<'SH'
#!/usr/bin/env bash
[ "$*" = "--query-gpu=name,driver_version,memory.total --format=csv,noheader" ] || { echo "fake nvidia-smi: unsupported: $*" >&2; exit 2; }
if [ -f "$FAKE_DOCKER_STATE/nvidia-smi.err" ]; then cat "$FAKE_DOCKER_STATE/nvidia-smi.err" >&2; exit 9; fi
echo "NVIDIA GeForce RTX 2060, 580.95.05, 12288 MiB"
SH
chmod +x "$work/bin/docker" "$work/bin/iptables" "$work/bin/swapon" "$work/bin/systemctl" "$work/bin/sysctl" "$work/bin/nvidia-smi"

session_ok='time="2026-10-13T10:01:00Z" level=info msg="Update session completed" failed=0 notify=no scanned=3 skipped=0 updated=1'
session_failed='time="2026-10-13T10:01:00Z" level=info msg="Update session completed" failed=1 notify=no scanned=3 skipped=0 updated=0'
too_old='time="2026-10-13T10:00:30Z" level=error msg="Error response from daemon: client version 1.25 is too old. Minimum supported API version is 1.44, please upgrade your client to a newer version"'
blocked='time=2026-10-13T10:00:59Z level=WARN msg="blocked request" reason="path not allowed" method=POST URL=/v1.51/containers/3f4e5d6c7b8a/stop client=172.20.0.3:40122 response=403'
allowed_only='time=2026-10-13T10:00:01Z level=INFO msg="socket-proxy running and listening..."'
hook='-A DOCKER-USER -i eth0 -m conntrack --ctstate NEW -j INFRA-PUBLIC'
tailnet_hook='-A DOCKER-USER ! -i tailscale0 -m conntrack --ctstate NEW -m conntrack --ctstate DNAT -j INFRA-PUBLIC'
ts_ip=100.101.102.103

scenario() {
  local name
  rm -rf "${work:?}/state"/*
  for name in edge-socket-proxy edge-traefik watchtower-socket-proxy watchtower autoheal-socket-proxy autoheal; do
    echo "true false" >"$work/state/$name.running"
  done
  for name in edge-socket-proxy watchtower-socket-proxy autoheal-socket-proxy; do
    echo "$allowed_only" >"$work/state/$name.log"
  done
  printf 'time="2026-10-13T10:00:00Z" level=info msg="Watchtower 1.22.1"\n%s\n' "$session_ok" >"$work/state/watchtower.log"
  : >"$work/state/autoheal.log"
  echo "29.1.3" >"$work/state/docker.version"
  echo '{"io.containerd.runc.v2":{"path":"runc"},"nvidia":{"path":"nvidia-container-runtime"},"runc":{"path":"runc"}}' >"$work/state/docker.runtimes"
  printf '%s\n' '-N DOCKER-USER' "$hook" "$tailnet_hook" '-A DOCKER-USER -j RETURN' >"$work/state/docker-user.rules"
  echo 2147483648 >"$work/state/swap"
  echo 1 >"$work/state/nonlocal_bind"
  printf '%s\n' "open-webui $ts_ip:8080->8080/tcp, 8080/tcp" "ollama 11434/tcp" "ollama-pull " "edge-traefik 80/tcp" "postgresql 5432/tcp" \
    "jellyfin $ts_ip:8096->8096/tcp" "audiobookshelf $ts_ip:13378->13378/tcp" "kavita $ts_ip:5000->5000/tcp" "home $ts_ip:80->80/tcp" >"$work/state/docker.ps"
}
run() {
  local role="$1"
  shift
  PATH="$work/bin:$PATH" FAKE_DOCKER_STATE="$work/state" \
    ansible-playbook -i localhost, -c local "$here/verify-tasks.yml" -e "verify_role=$role" \
    -e '{"ansible_facts": {"default_ipv4": {"interface": "eth0"}}}' -e "tailscale_ipv4=$ts_ip" "$@" \
    </dev/null >"$work/out.log" 2>&1
}
expect_pass() {
  local name="$1"
  shift
  if run "$@"; then echo "ok   pass: $name"; else cat "$work/out.log"; echo "FAIL expected pass: $name"; exit 1; fi
}
expect_fail() {
  local name="$1" want="$2"
  shift 2
  if run "$@"; then cat "$work/out.log"; echo "FAIL expected failure: $name"; exit 1; fi
  if ! grep -qF -- "$want" "$work/out.log"; then cat "$work/out.log"; echo "FAIL wrong failure for $name (wanted: $want)"; exit 1; fi
  echo "ok   fail: $name"
}

### edge

scenario
expect_pass "edge healthy: proxy up, no refusals" edge

scenario
echo "true true" >"$work/state/edge-socket-proxy.running"
expect_fail "edge: proxy restart-looping" "edge-socket-proxy is not running" edge

scenario
echo "${blocked/POST URL=\/v1.51\/containers\/3f4e5d6c7b8a\/stop/GET URL=\/v1.51\/networks}" >>"$work/state/edge-socket-proxy.log"
expect_fail "edge: proxy logged a blocked request" "GET URL=/v1.51/networks" edge

scenario
echo '{"80/tcp":[{"HostIp":"","HostPort":"80"}]}' >"$work/state/edge-traefik.ports"
expect_fail "edge: Traefik publishes a host port" "edge-traefik publishes host ports" edge

scenario
echo 'null' >"$work/state/edge-traefik.ports"
expect_pass "edge: Traefik with no port bindings at all" edge

scenario
rm "$work/state/edge-socket-proxy.running" "$work/state/edge-traefik.running"
expect_pass "edge: no containers yet" edge

### watchtower

scenario
expect_pass "watchtower healthy: a clean session completed" watchtower -e watchtower_verify_wait=5

scenario
echo "true true" >"$work/state/watchtower-socket-proxy.running"
expect_fail "watchtower: proxy restart-looping" "watchtower-socket-proxy is not running" watchtower

scenario
echo "$blocked" >>"$work/state/watchtower-socket-proxy.log"
expect_fail "watchtower: proxy logged a blocked request" "/v1.51/containers/3f4e5d6c7b8a/stop" watchtower

scenario
printf '%s\n%s\n' "$too_old" "$session_ok" >>"$work/state/watchtower.log"
expect_fail "watchtower: client version is too old" "Watchtower is not able to use the Docker API" watchtower

scenario
echo 'time="2026-10-13T10:00:00Z" level=info msg="Watchtower 1.22.1"' >"$work/state/watchtower.log"
expect_fail "watchtower: no update session within the wait" "did not complete a clean update session" watchtower -e watchtower_verify_wait=5

scenario
printf '%s\n' "$session_failed" >>"$work/state/watchtower.log"
expect_fail "watchtower: the latest session reports failed containers" "failed=1" watchtower

scenario
rm "$work/state/watchtower.running" "$work/state/watchtower-socket-proxy.running"
expect_pass "watchtower: no containers yet" watchtower

### autoheal

scenario
expect_pass "autoheal healthy: proxy up, no refusals" autoheal

scenario
echo "true true" >"$work/state/autoheal-socket-proxy.running"
expect_fail "autoheal: proxy restart-looping" "autoheal-socket-proxy is not running" autoheal

scenario
echo "${blocked/containers\/3f4e5d6c7b8a\/stop/containers\/3f4e5d6c7b8a\/restart}" >>"$work/state/autoheal-socket-proxy.log"
expect_fail "autoheal: proxy logged a blocked request" "/v1.51/containers/3f4e5d6c7b8a/restart" autoheal

### docker

scenario
expect_pass "docker: the Engine major production.yml pins, compose plugin present" docker

scenario
echo "28.5.2" >"$work/state/docker.version"
expect_fail "docker: Engine major mismatch" "Docker Engine 28.5.2 runs, but production.yml pins" docker

scenario
touch "$work/state/compose.missing"
expect_fail "docker: no compose plugin" "unknown command: docker compose" docker

### gpu

scenario
expect_pass "gpu: nvidia runtime listed, nvidia-smi sees the card" gpu

scenario
echo '{"io.containerd.runc.v2":{"path":"runc"},"runc":{"path":"runc"}}' >"$work/state/docker.runtimes"
expect_fail "gpu: Docker has no nvidia runtime" "docker info lists no nvidia runtime" gpu

scenario
cp "$work/state/docker.runtimes" "$work/state/docker.runtimes.reloaded"
echo '{"io.containerd.runc.v2":{"path":"runc"},"runc":{"path":"runc"}}' >"$work/state/docker.runtimes"
expect_pass "gpu: a Docker that missed its reload gets one and then lists the nvidia runtime" gpu

scenario
echo "Failed to initialize NVML: Driver/library version mismatch" >"$work/state/nvidia-smi.err"
expect_fail "gpu: driver and library differ (update waiting for a reboot)" "Driver/library version mismatch" gpu

scenario
echo "NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver." >"$work/state/nvidia-smi.err"
if ! run gpu -e gpu_just_installed=true; then cat "$work/out.log"; echo "FAIL a driver installed in this run failed the verify instead of asking for a reboot"; exit 1; fi
grep -qF "The NVIDIA driver was installed or updated since the last boot and is not loaded yet" "$work/out.log" || { cat "$work/out.log"; echo "FAIL no reboot notice after a fresh driver install"; exit 1; }
echo "ok   pass: gpu: a driver installed in this run asks for a reboot instead of failing"

scenario
echo "NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver." >"$work/state/nvidia-smi.err"
touch "$work/state/driver.list"
printf 'cpu  1 2 3\nbtime 1000\n' >"$work/state/proc-stat"
if ! run gpu -e "gpu_driver_package_list=$work/state/driver.list" -e "gpu_proc_stat=$work/state/proc-stat"; then
  cat "$work/out.log"; echo "FAIL a driver installed by an earlier run, not yet rebooted into, failed the verify"; exit 1
fi
grep -qF "installed or updated since the last boot" "$work/out.log" || { cat "$work/out.log"; echo "FAIL no reboot notice for a driver installed before this run"; exit 1; }
echo "ok   pass: gpu: a driver installed since the last boot by an earlier run asks for a reboot"

scenario
echo "NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver." >"$work/state/nvidia-smi.err"
touch -d @500 "$work/state/driver.list"
printf 'cpu  1 2 3\nbtime 1000\n' >"$work/state/proc-stat"
expect_fail "gpu: driver installed before the last boot but not loaded" "couldn't communicate with the NVIDIA driver" gpu \
  -e "gpu_driver_package_list=$work/state/driver.list" -e "gpu_proc_stat=$work/state/proc-stat"

### host

scenario
expect_pass "host: INFRA-PUBLIC hooked first and for the tailnet, 2 GiB swap, sleep masked, the four tailnet ports" host

scenario
printf '%s\n' "kavita $ts_ip:8096->8096/tcp" >"$work/state/docker.ps"
expect_fail "host: a tailnet port on the wrong container" "kavita 100.101.102.103:8096->8096/tcp" host

scenario
printf '%s\n' '-N DOCKER-USER' "$hook" '-A DOCKER-USER -j RETURN' >"$work/state/docker-user.rules"
expect_fail "host: the tailnet hook missing" "DOCKER-USER's second rule is not the tailnet hook" host

scenario
printf '%s\n' '-N DOCKER-USER' "$hook" "${tailnet_hook/tailscale0/eth0}" >"$work/state/docker-user.rules"
expect_fail "host: the tailnet hook names another interface" "DOCKER-USER's second rule is not the tailnet hook" host

scenario
echo 0 >"$work/state/nonlocal_bind"
expect_fail "host: non-local binds off" "net.ipv4.ip_nonlocal_bind is 0" host

scenario
printf '%s\n' "open-webui 0.0.0.0:8080->8080/tcp, [::]:8080->8080/tcp" >"$work/state/docker.ps"
expect_fail "host: Open WebUI on every interface" "A container publishes a port that is not a tailnet-only one" host

scenario
printf '%s\n' "open-webui $ts_ip:8080->8080/tcp" "ollama $ts_ip:11434->11434/tcp" >"$work/state/docker.ps"
expect_fail "host: Ollama published on the tailnet" "ollama 100.101.102.103:11434->11434/tcp" host

scenario
printf '%s\n' "open-webui 192.168.1.50:8080->8080/tcp" >"$work/state/docker.ps"
expect_fail "host: Open WebUI on the LAN address" "open-webui 192.168.1.50:8080->8080/tcp" host

scenario
printf '%s\n' "portfolio 0.0.0.0:3000->3000/tcp" >"$work/state/docker.ps"
expect_fail "host: an app container publishing a port" "portfolio 0.0.0.0:3000->3000/tcp" host

scenario
: >"$work/state/docker.ps"
expect_pass "host: no container at all" host

scenario
echo static >"$work/state/suspend.target.enabled"
expect_fail "host: suspend not masked" "The host could still suspend or hibernate" host

scenario
printf '%s\n' '-N DOCKER-USER' '-A DOCKER-USER -j RETURN' >"$work/state/docker-user.rules"
expect_fail "host: INFRA-PUBLIC hook missing" "DOCKER-USER does not start with the INFRA-PUBLIC hook" host

scenario
printf '%s\n' '-N DOCKER-USER' '-A DOCKER-USER -j RETURN' "$hook" >"$work/state/docker-user.rules"
expect_fail "host: INFRA-PUBLIC hook not first" "DOCKER-USER does not start with the INFRA-PUBLIC hook" host

scenario
printf '%s\n' '-N DOCKER-USER' "${hook/-i eth0/-i eth1}" "$tailnet_hook" >"$work/state/docker-user.rules"
expect_fail "host: INFRA-PUBLIC hooked on another interface" "DOCKER-USER does not start with the INFRA-PUBLIC hook" host

scenario
echo 536870912 >"$work/state/swap"
expect_fail "host: less than 1 GiB of swap" "it needs at least 1 GiB" host

### provision SSH route (tasks/ssh-route.yml): only a run whose own connection
### reached a tailnet address may close 22 on the LAN.

expect_route() {
  local name="$1" connection="$2" want="$3"
  shift 3
  if ! run ssh_route -e "{\"ssh_connection\": {\"stdout\": \"$connection\"}}" "$@"; then
    cat "$work/out.log"; echo "FAIL ssh route probe did not run: $name"; exit 1
  fi
  if ! grep -qF "\"msg\": \"ssh_outside_tailnet=$want\"" "$work/out.log"; then
    cat "$work/out.log"; echo "FAIL ssh route: $name: wanted ssh_outside_tailnet=$want"; exit 1
  fi
  echo "ok   ssh route: $name -> ssh_outside_tailnet=$want"
}

expect_route "the LAN (the first run)" "192.168.1.20 51000 192.168.1.50 22" True
expect_route "a 10.x LAN" "10.0.0.20 51000 10.0.0.50 22" True
expect_route "LAN IPv6 (link-local)" "fe80::5 51000 fe80::1 22" True
expect_route "a public IPv4" "203.0.113.5 51000 198.51.100.10 22" True
expect_route "a public IPv6" "2001:db8::5 51000 2001:db8:c012:abcd::1 22" True
expect_route "IPv6 on a host without a default IPv4" "2001:db8::5 51000 2001:db8:c012:abcd::1 22" True -e '{"ansible_facts": {}}'
expect_route "just below 100.64.0.0/10" "203.0.113.5 51000 100.63.255.255 22" True
expect_route "just above 100.64.0.0/10" "203.0.113.5 51000 100.128.0.1 22" True
expect_route "an address that only contains 100.64." "203.0.113.5 51000 1100.64.0.1 22" True
expect_route "IPv4-mapped tailnet address (kept open, fail-safe)" "::ffff:100.101.1.2 51000 ::ffff:100.64.1.2 22" True
expect_route "next to fd7a:115c:a1e0::/48" "2001:db8::5 51000 fd7a:115c:a1e1::1 22" True
expect_route "unreadable SSH_CONNECTION" "" True
expect_route "SSH_CONNECTION with three fields" "203.0.113.5 51000 100.64.0.7" True
expect_route "tailnet IPv4" "100.101.102.103 51000 100.64.0.7 22" False
expect_route "tailnet IPv4, top of the range" "100.101.102.103 51000 100.127.255.254 22" False
expect_route "tailnet IPv6" "fd7a:115c:a1e0::1 51000 fd7a:115c:a1e0:ab12:4843:cd96:6258:b240 22" False
expect_route "tailnet IPv6 in capitals" "fd7a:115c:a1e0::1 51000 FD7A:115C:A1E0::5 22" False

echo "verify tasks: all cases behaved"
