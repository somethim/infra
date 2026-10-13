#!/usr/bin/env bash
# Runs the verify tasks of edge, watchtower, autoheal, docker and host
# (roles/*/tasks/verify.yml) on localhost against fake docker, iptables and
# swapon that answer from per-case state files. Nothing here touches the
# local Docker daemon, firewall or swap.
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
      running=*) echo "running=$running restarting=$restarting" ;;
      *) echo "$running $restarting" ;;
    esac ;;
  logs*)
    shift; [ "${1:-}" = "--since" ] && shift 2
    cat "$state/$1.log" 2>/dev/null || true ;;
  "version --format")
    cat "$state/docker.version" ;;
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
chmod +x "$work/bin/docker" "$work/bin/iptables" "$work/bin/swapon"

session_ok='time="2026-10-13T10:01:00Z" level=info msg="Update session completed" failed=0 notify=no scanned=3 skipped=0 updated=1'
session_failed='time="2026-10-13T10:01:00Z" level=info msg="Update session completed" failed=1 notify=no scanned=3 skipped=0 updated=0'
too_old='time="2026-10-13T10:00:30Z" level=error msg="Error response from daemon: client version 1.25 is too old. Minimum supported API version is 1.44, please upgrade your client to a newer version"'
blocked='time=2026-10-13T10:00:59Z level=WARN msg="blocked request" reason="path not allowed" method=POST URL=/v1.51/containers/3f4e5d6c7b8a/stop client=172.20.0.3:40122 response=403'
allowed_only='time=2026-10-13T10:00:01Z level=INFO msg="socket-proxy running and listening..."'
hook='-A DOCKER-USER -i eth0 -m conntrack --ctstate NEW -j INFRA-PUBLIC'

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
  printf '%s\n' '-N DOCKER-USER' "$hook" '-A DOCKER-USER -j RETURN' >"$work/state/docker-user.rules"
  echo 2147483648 >"$work/state/swap"
}
run() {
  local role="$1"
  shift
  PATH="$work/bin:$PATH" FAKE_DOCKER_STATE="$work/state" \
    ansible-playbook -i localhost, -c local "$here/verify-tasks.yml" -e "verify_role=$role" \
    -e '{"ansible_facts": {"default_ipv4": {"interface": "eth0"}}}' "$@" \
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

### host

scenario
expect_pass "host: INFRA-PUBLIC hooked first, 2 GiB swap" host

scenario
printf '%s\n' '-N DOCKER-USER' '-A DOCKER-USER -j RETURN' >"$work/state/docker-user.rules"
expect_fail "host: INFRA-PUBLIC hook missing" "DOCKER-USER does not start with the INFRA-PUBLIC hook" host

scenario
printf '%s\n' '-N DOCKER-USER' '-A DOCKER-USER -j RETURN' "$hook" >"$work/state/docker-user.rules"
expect_fail "host: INFRA-PUBLIC hook not first" "DOCKER-USER does not start with the INFRA-PUBLIC hook" host

scenario
printf '%s\n' '-N DOCKER-USER' "${hook/-i eth0/-i eth1}" >"$work/state/docker-user.rules"
expect_fail "host: INFRA-PUBLIC hooked on another interface" "DOCKER-USER does not start with the INFRA-PUBLIC hook" host

scenario
echo 536870912 >"$work/state/swap"
expect_fail "host: less than 1 GiB of swap" "it needs at least 1 GiB" host

echo "verify tasks: all cases behaved"
