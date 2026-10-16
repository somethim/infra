#!/usr/bin/env bash
# The Drive-style file list (stack/media, service sftpgo) is a script inserted
# into SFTPGo's own webclient/files.html at start. It is written against one
# version of that page: FILES_HTML_SHA256 must be the hash of files.html in the
# pinned image, and the line it is inserted after must still be there. A re-pin
# of SFTPGo fails here until DRIVE_JS is re-checked against the new page and the
# hash updated (docs/agents.md, "Re-pinning third-party images").
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
compose="${FILES_UI_COMPOSE:-$here/../stack/media/docker-compose.yml}"
js="$(mktemp --suffix=.js)"
trap 'rm -f "$js"' EXIT

read -r image want < <(python3 - "$compose" "$js" <<'PY'
import sys, yaml
svc = yaml.safe_load(open(sys.argv[1]))["services"]["sftpgo"]
env = svc["environment"]
js = env["DRIVE_JS"]
problems = []
if "$" in js:
    problems.append("DRIVE_JS contains '$' (Compose interpolates it)")
if "{{" in js:
    problems.append("DRIVE_JS contains '{{' (SFTPGo's template engine reads it)")
if "files-ui.sh" not in " ".join(svc["command"]):
    problems.append("the sftpgo command no longer runs FILES_UI_SH")
if env.get("SFTPGO_HTTPD__TEMPLATES_PATH") != "/tmp/templates":
    problems.append("SFTPGO_HTTPD__TEMPLATES_PATH is not /tmp/templates, where FILES_UI_SH writes the patched copy")
if problems:
    sys.exit("files-ui: " + "; ".join(problems))
open(sys.argv[2], "w").write(js)
print(svc["image"], env["FILES_HTML_SHA256"])
PY
)
if command -v node >/dev/null; then
  node --check "$js" || { echo "files-ui: DRIVE_JS is not valid JavaScript"; exit 1; }
fi

docker pull -q "$image" >/dev/null
have="$(docker run --rm --entrypoint sha256sum "$image" /usr/share/sftpgo/templates/webclient/files.html | cut -d' ' -f1)"
if [ "$have" != "$want" ]; then
  echo "files-ui: $image ships webclient/files.html $have, but FILES_HTML_SHA256 is $want."
  echo "files-ui: check DRIVE_JS against the new page (selectors, row data, the extra_js block), then update the hash."
  exit 1
fi
anchors="$(docker run --rm --entrypoint grep "$image" -c '^{{- define "extra_js"}}$' /usr/share/sftpgo/templates/webclient/files.html || true)"
[ "$anchors" = 1 ] || { echo "files-ui: the line DRIVE_JS is inserted after occurs $anchors times in files.html, expected 1"; exit 1; }
echo "ok   files-ui: $image files.html matches FILES_HTML_SHA256, DRIVE_JS parses and has no \$ or {{"
