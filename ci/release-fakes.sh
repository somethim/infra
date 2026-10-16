# shellcheck shell=bash disable=SC2154 # work, apply, guard and secrets come from the caller
# Fakes shared by ci/release-scripts.sh and ci/rollback-scripts.sh: docker,
# curl and sudo on $work/bin, a host state per case (new_state, running_image),
# and run_apply / expect_ok / expect_refused around infra-apply. Sourced, not
# run. The caller sets work (a temp dir with work/bin), apply and guard, and
# the secrets array no_secret_in scans for. `docker compose config` is
# delegated to the real Docker CLI (it needs no daemon).
unset SUDO_USER
REAL_DOCKER="$(command -v docker)" || { echo "FAIL the release fakes need docker with the compose plugin to resolve compose files"; exit 1; }
export REAL_DOCKER
"$REAL_DOCKER" compose version >/dev/null 2>&1 || { echo "FAIL the release fakes need the docker compose plugin"; exit 1; }

cat >"$work/bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
state="$FAKE_STATE"
printf '%s\n' "$*" >>"$state/calls"
if [ "$1" = compose ]; then
  args=("$@")
  shift
  stack=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project-directory) stack="$(basename "$2")"; shift 2 ;;
      --file) shift 2 ;;
      *) break ;;
    esac
  done
  case "$1" in
    config)
      [ ! -f "$state/config.rc" ] || exit "$(cat "$state/config.rc")"
      exec "$REAL_DOCKER" "${args[@]}"
      ;;
    pull) exit "$(cat "$state/pull.rc" 2>/dev/null || echo 0)" ;;
    up) exit "$(cat "$state/up.$stack.rc" 2>/dev/null || echo 0)" ;;
    ps)
      if [ "${2:-}" = --all ] && [ "${3:-}" = --quiet ]; then
        [ ! -f "$state/ps.$stack.rc" ] || exit "$(cat "$state/ps.$stack.rc")"
        awk -v stack="$stack" '$NF == stack { print $1 }' "$state/containers"
      else
        printf 'NAME IMAGE STATUS (%s)\n' "$stack"
      fi
      exit 0
      ;;
  esac
  echo "fake docker: unsupported compose call: ${args[*]}" >&2
  exit 2
fi
case "$1" in
  login)
    cat >"$state/login.stdin"
    exit "$(cat "$state/login.rc" 2>/dev/null || echo 0)"
    ;;
  exec)
    [ "$2 $3 $4" = "-i postgresql psql" ] || { echo "fake docker: unsupported exec: $*" >&2; exit 2; }
    cat >"$state/psql.stdin"
    if [ -f "$state/psql.rc" ]; then
      printf "psql:<stdin>:6: ERROR:  role \"prizm\" cannot be altered with password '%s'\n" "$(sed -n "s/^ALTER ROLE prizm WITH LOGIN PASSWORD '\\(.*\\)';$/\\1/p" "$state/psql.stdin")" >&2
      exit "$(cat "$state/psql.rc")"
    fi
    ;;
  inspect)
    # Name, status, restart policy, health, then RestartCount and StartedAt:
    # state/started/<name> (default: long ago) and state/restarts/<name>. A
    # state/crashloop/<name> container restarts before every inspect. Like
    # the real CLI, an id that is gone (unknown, or state/vanished/<id>: removed
    # since `compose ps` listed it; state/vanished-once/<id> for one inspect
    # only) is reported on stderr, the other ids are
    # still printed, and the exit status is 1.
    shift 3
    rc=0
    for id in "$@"; do
      line="$(awk -v id="$id" '$1 == id { print $2, $3, $4, $5 }' "$state/containers")"
      if [ -z "$line" ] || [ -e "$state/vanished/$id" ] || [ -e "$state/vanished-once/$id" ]; then
        rm -f "$state/vanished-once/$id"
        echo "Error: No such object: $id" >&2
        rc=1
        continue
      fi
      name="${line%% *}"
      name="${name#/}"
      if [ -e "$state/crashloop/$name" ]; then
        echo $(($(cat "$state/restarts/$name" 2>/dev/null || echo 0) + 1)) >"$state/restarts/$name"
        date -u +%Y-%m-%dT%H:%M:%S.%NZ >"$state/started/$name"
      fi
      printf '%s %s %s\n' "$line" "$(cat "$state/restarts/$name" 2>/dev/null || echo 0)" "$(cat "$state/started/$name" 2>/dev/null || echo 2026-01-01T00:00:00.000000000Z)"
    done
    exit "$rc"
    ;;
  container)
    format="$4"
    name="$5"
    case "$format" in
      *PortBindings*)
        # state/ports/<name>: the bindings Docker applied (default: none).
        [ -f "$state/running/$name" ] || { echo "Error: No such container: $name" >&2; exit 1; }
        cat "$state/ports/$name" 2>/dev/null || echo '{}'
        exit 0
        ;;
      *Config.Image*)
        [ -f "$state/images/$name" ] || { echo "Error: No such container: $name" >&2; exit 1; }
        cat "$state/images/$name"
        exit 0
        ;;
      *ExitCode*)
        # A one-shot's end: state/oneshot/<name> (default "exited 0"); a
        # state/oneshot-missing/<name> was never created.
        [ ! -e "$state/oneshot-missing/$name" ] || { echo "Error: No such container: $name" >&2; exit 1; }
        cat "$state/oneshot/$name" 2>/dev/null || echo "exited 0"
        exit 0
        ;;
    esac
    [ -f "$state/running/$name" ] || { echo "Error: No such container: $name" >&2; exit 1; }
    case "$format" in
      *StartedAt*) echo "2026-10-14T10:00:00.000000000Z" ;;
      *IPAddress*) cat "$state/ip/$name" 2>/dev/null || echo ;;
      *) cat "$state/running/$name" ;;
    esac
    ;;
  image)
    case "$2" in
      inspect)
        [ -f "$state/imageinfo/$5" ] || { echo "Error: No such image: $5" >&2; exit 1; }
        cat "$state/imageinfo/$5"
        ;;
      ls)
        cat "$state/known/$(printf '%s' "${!#}" | tr / _)" 2>/dev/null || true
        ;;
      *) echo "fake docker: unsupported: $*" >&2; exit 2 ;;
    esac
    ;;
  logs)
    cat "$state/logs/$4" 2>/dev/null || true
    ;;
  stop)
    name="${!#}"
    [ -f "$state/running/$name" ] || { echo "Error: No such container: $name" >&2; exit 1; }
    [ ! -f "$state/stop.rc" ] || exit "$(cat "$state/stop.rc")"
    echo "false false" >"$state/running/$name"
    ;;
  start)
    [ -f "$state/running/$2" ] || { echo "Error: No such container: $2" >&2; exit 1; }
    [ ! -f "$state/start.rc" ] || exit "$(cat "$state/start.rc")"
    echo "true false" >"$state/running/$2"
    ;;
  *)
    echo "fake docker: unsupported: $*" >&2
    exit 2
    ;;
esac
SH

# curl: a route check sends -H "Host: <host>" to Traefik's edge address and
# gets state/curl.<host> (default 301 for www., else 200); the tunnel check
# (no Host header) asks cloudflared's /ready and gets state/curl.ready
# (default 200); the public check (a URL by name, no Host header) gets
# state/curl.public.<scheme>.<host> (default 301 for www. and plain http, else 200);
# home-tls's certificate check (--resolve <name>:443:<tailnet ip>) gets
# state/curl.tls.<host> (default 200). state/curl.<key>.rc sets the exit status.
cat >"$work/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
host=""
url=""
resolve=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -H)
      case "$2" in "Host: "*) host="${2#Host: }" ;; esac
      shift 2
      ;;
    --resolve) resolve="$2"; shift 2 ;;
    -o | -w | --max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
if [ -n "$resolve" ] && [[ "$url" =~ ^https://([a-z][a-z0-9.-]*)/ ]]; then
  # home-tls's certificate check: https by name, pinned to the Tailscale address.
  key="tls.${BASH_REMATCH[1]}"
  default=200
  printf 'curl tls %s %s\n' "$resolve" "$url" >>"$FAKE_STATE/calls"
elif [ -z "$host" ] && [[ "$url" =~ ^(https?)://([a-z][a-z0-9.-]*)(/.*)?$ ]]; then
  # The public check: a visitor's request by name, through Cloudflare.
  key="public.${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
  default=200
  case "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}" in "https www."* | "http "*) default=301 ;; esac
  printf 'curl public %s\n' "$url" >>"$FAKE_STATE/calls"
elif [ -n "$host" ]; then
  key="$host"
  default=200
  case "$host" in www.*) default=301 ;; esac
  printf 'curl route %s %s\n' "$host" "$url" >>"$FAKE_STATE/calls"
else
  key=ready
  default=200
  printf 'curl ready %s\n' "$url" >>"$FAKE_STATE/calls"
fi
if [ -f "$FAKE_STATE/curl.$key" ]; then cat "$FAKE_STATE/curl.$key"; else printf '%s' "$default"; fi
exit "$(cat "$FAKE_STATE/curl.$key.rc" 2>/dev/null || echo 0)"
SH

cat >"$work/bin/sudo" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"$FAKE_STATE/sudo.args"
cat >"$FAKE_STATE/sudo.stdin"
SH
chmod +x "$work/bin/docker" "$work/bin/curl" "$work/bin/sudo"

readonly portfolio_repo=ghcr.io/somethim/portfolio
readonly provider_repo=ghcr.io/hypernova3643725/hypernova-provider
readonly web_repo=ghcr.io/hypernova3643725/hypernova-web
readonly tailscale_ip=100.101.102.103
d() { printf 'sha256:%064x' "$1"; }

# tailnet_binding <container> <port> [address]: Docker bound the port to that
# address (default: the host's Tailscale address).
tailnet_binding() {
  printf '{"%s/tcp":[{"HostIp":"%s","HostPort":"%s"}]}\n' "$2" "${3:-$tailscale_ip}" "$2" >"$state/ports/$1"
}

count=0
state=""
new_state() {
  local name
  count=$((count + 1))
  state="$work/state$count"
  mkdir -p "$state/stack" "$state/edge" "$state/logs" "$state/running" "$state/docker" "$state/images" "$state/imageinfo" "$state/known" \
    "$state/started" "$state/restarts" "$state/crashloop" "$state/vanished" "$state/vanished-once" "$state/ip" "$state/ports" "$state/oneshot" "$state/oneshot-missing"
  printf 'name: edge\n' >"$state/edge/docker-compose.yml"
  # infra-apply points DOCKER_CONFIG at $state/docker, which hides a Compose plugin installed in
  # ~/.docker/cli-plugins (CI installs the host's pinned version there). Link it in so every case
  # resolves compose files with the same Compose the job pinned, not the runner's own.
  if [ -d "${HOME}/.docker/cli-plugins" ]; then
    ln -s "${HOME}/.docker/cli-plugins" "$state/docker/cli-plugins"
  fi
  printf '%s\n' PUBLIC_INTERFACE=eth0 PUBLIC_PORTS= "TAILSCALE_IP=$tailscale_ip" AI_USER=2001:2001 MEDIA_USER=2000:2000 \
    "PORTFOLIO_IMAGE_REPO=$portfolio_repo" "HYPERNOVA_PROVIDER_IMAGE_REPO=$provider_repo" "HYPERNOVA_WEB_IMAGE_REPO=$web_repo" >"$state/host.env"
  # ollama-pull, webui-presets, comfyui-fetch, beszel-pair, garage-config, garage-setup and immich-admin
  # are one-shots (restart: "no"): verify does not wait for them to run, but checks that beszel-pair,
  # garage-setup and immich-admin ended with status 0 (state/oneshot/<name>).
  printf '%s\n' \
    "c1 /postgresql running always healthy database" \
    "c2 /portfolio running always healthy portfolio" \
    "c3 /prizm-provider running always healthy hypernova" \
    "c4 /prizm-web running always none hypernova" \
    "c5 /cloudflared running always healthy tunnel" \
    "c6 /ollama running always healthy ai" \
    "c7 /ollama-pull exited no none ai" \
    "c8 /open-webui running always healthy ai" \
    "c9 /jellyfin running always healthy media" \
    "c10 /audiobookshelf running always healthy media" \
    "c11 /kavita running always healthy media" \
    "c12 /home running always healthy media" \
    "c13 /home-tls running always healthy media" \
    "c14 /searxng running always healthy ai" \
    "c15 /comfyui running always healthy ai" \
    "c16 /webui-presets exited no none ai" \
    "c17 /comfyui-fetch exited no none ai" \
    "c18 /beszel running always healthy media" \
    "c19 /beszel-pair exited no none media" \
    "c20 /beszel-agent running always healthy media" \
    "c21 /garage-config exited no none media" \
    "c22 /garage running always healthy media" \
    "c23 /garage-setup exited no none media" \
    "c24 /sftpgo running always healthy media" \
    "c25 /immich-postgres running always healthy media" \
    "c26 /immich-valkey running always healthy media" \
    "c27 /immich-server running always healthy media" \
    "c28 /immich-machine-learning running always healthy media" \
    "c29 /immich-admin exited no none media" >"$state/containers"
  for name in edge-socket-proxy edge-traefik watchtower-socket-proxy watchtower autoheal-socket-proxy autoheal beszel-socket-proxy cloudflared ollama open-webui searxng comfyui jellyfin audiobookshelf kavita home home-tls beszel beszel-agent garage sftpgo \
    immich-postgres immich-valkey immich-server immich-machine-learning; do
    echo "true false" >"$state/running/$name"
  done
  tailnet_binding open-webui 8080
  tailnet_binding jellyfin 8096
  tailnet_binding audiobookshelf 13378
  tailnet_binding kavita 5000
  tailnet_binding home 80
  tailnet_binding home-tls 443
  tailnet_binding beszel 8090
  tailnet_binding garage 3900
  tailnet_binding sftpgo 8091
  tailnet_binding immich-server 2283
  echo 172.18.0.2 >"$state/ip/edge-traefik"
  echo 172.18.0.9 >"$state/ip/cloudflared"
  running_image portfolio "$portfolio_repo:latest" 11
  running_image prizm-provider "$provider_repo:latest" 21
  running_image prizm-web "$web_repo:latest" 31
  : >"$state/calls"
}

# running_image <container> <ref> <digest number>: the container runs that digest.
running_image() {
  local name="$1" ref="$2" n="$3" repo="${2%@*}"
  repo="${repo%:*}"
  printf '%s|sha256:image%s\n' "$ref" "$n" >"$state/images/$name"
  printf '2026-10-%02dT10:00:00Z other.example/mirror@%s %s@%s\n' "$((n % 28 + 1))" "$(d 99)" "$repo" "$(d "$n")" >"$state/imageinfo/sha256:image$n"
}

run_apply() {
  local input="$1"
  shift
  PATH="$work/bin:$PATH" FAKE_STATE="$state" \
    INFRA_APPLY_STACK_DIR="$state/stack" INFRA_APPLY_EDGE_DIR="$state/edge" INFRA_APPLY_DOCKER_CONFIG="$state/docker" \
    INFRA_APPLY_HOST_FILE="$state/host.env" INFRA_APPLY_GUARD="$guard" \
    INFRA_APPLY_WAIT_SECONDS="${apply_wait_seconds:-1}" INFRA_APPLY_ROUTE_WAIT_SECONDS=1 INFRA_APPLY_PUBLIC_WAIT_SECONDS=1 INFRA_APPLY_HOME_TLS_WAIT_SECONDS=1 INFRA_APPLY_POLL_SECONDS=0.2 \
    "$apply" "$@" <"$input" >"$work/out" 2>&1
}

no_secret_in() {
  local file="$1" label="$2" secret
  for secret in "${secrets[@]}"; do
    if grep -qF -- "$secret" "$file"; then cat "$file"; echo "FAIL $label printed a secret"; exit 1; fi
  done
}

expect_ok() {
  local name="$1" want="$2" input="$3"
  shift 3
  if ! run_apply "$input" "$@"; then cat "$work/out"; echo "FAIL expected success: $name"; exit 1; fi
  if ! grep -qE -- "$want" "$work/out"; then cat "$work/out"; echo "FAIL missing '$want': $name"; exit 1; fi
  no_secret_in "$work/out" "$name"
  echo "ok   applied: $name"
}

expect_refused() {
  local name="$1" want="$2" input="$3"
  shift 3
  if run_apply "$input" "$@"; then cat "$work/out"; echo "FAIL expected refusal: $name"; exit 1; fi
  if ! grep -qE -- "$want" "$work/out"; then cat "$work/out"; echo "FAIL refused for the wrong reason (wanted '$want'): $name"; exit 1; fi
  no_secret_in "$work/out" "$name"
  echo "ok   refused: $name"
}
