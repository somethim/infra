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
    # state/crashloop/<name> container restarts before every inspect.
    shift 3
    for id in "$@"; do
      line="$(awk -v id="$id" '$1 == id { print $2, $3, $4, $5 }' "$state/containers")"
      [ -n "$line" ] || { echo "Error: No such object: $id" >&2; exit 1; }
      name="${line%% *}"
      name="${name#/}"
      if [ -e "$state/crashloop/$name" ]; then
        echo $(($(cat "$state/restarts/$name" 2>/dev/null || echo 0) + 1)) >"$state/restarts/$name"
        date -u +%Y-%m-%dT%H:%M:%S.%NZ >"$state/started/$name"
      fi
      printf '%s %s %s\n' "$line" "$(cat "$state/restarts/$name" 2>/dev/null || echo 0)" "$(cat "$state/started/$name" 2>/dev/null || echo 2026-01-01T00:00:00.000000000Z)"
    done
    ;;
  container)
    format="$4"
    name="$5"
    case "$format" in
      *Config.Image*)
        [ -f "$state/images/$name" ] || { echo "Error: No such container: $name" >&2; exit 1; }
        cat "$state/images/$name"
        exit 0
        ;;
    esac
    [ -f "$state/running/$name" ] || { echo "Error: No such container: $name" >&2; exit 1; }
    case "$format" in
      *StartedAt*) echo "2026-10-14T10:00:00.000000000Z" ;;
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

cat >"$work/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
host=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = --resolve ]; then host="${2%%:*}"; shift; fi
  shift
done
printf 'curl %s\n' "$host" >>"$FAKE_STATE/calls"
if [ -f "$FAKE_STATE/curl.$host" ]; then cat "$FAKE_STATE/curl.$host"; else printf '403'; fi
exit "$(cat "$FAKE_STATE/curl.$host.rc" 2>/dev/null || echo 0)"
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
d() { printf 'sha256:%064x' "$1"; }

count=0
state=""
new_state() {
  local name
  count=$((count + 1))
  state="$work/state$count"
  mkdir -p "$state/stack" "$state/edge/dynamic" "$state/logs" "$state/running" "$state/docker" "$state/images" "$state/imageinfo" "$state/known" \
    "$state/started" "$state/restarts" "$state/crashloop"
  printf 'http: {}\n' >"$state/edge/dynamic/dynamic.yml"
  printf '%s\n' PUBLIC_INTERFACE=eth0 PUBLIC_PORTS=80,443 ORIGIN_PULL=0 \
    "PORTFOLIO_IMAGE_REPO=$portfolio_repo" "HYPERNOVA_PROVIDER_IMAGE_REPO=$provider_repo" "HYPERNOVA_WEB_IMAGE_REPO=$web_repo" >"$state/host.env"
  printf '%s\n' \
    "c1 /postgresql running always healthy database" \
    "c2 /portfolio running always healthy portfolio" \
    "c3 /prizm-provider running always healthy hypernova" \
    "c4 /prizm-web running always none hypernova" >"$state/containers"
  for name in edge-socket-proxy edge-traefik watchtower-socket-proxy watchtower autoheal-socket-proxy autoheal; do
    echo "true false" >"$state/running/$name"
  done
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
    INFRA_APPLY_WAIT_SECONDS=1 INFRA_APPLY_ROUTE_WAIT_SECONDS=1 INFRA_APPLY_POLL_SECONDS=0.2 \
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
