#!/usr/bin/env python3
"""Checks that the access model in the roles matches the Deploy workflow.

    python3 ci/check_access.py [--self-test]

Rules (each problem is printed as a ::error:: line):
  1. infra-deploy-gate allows exactly {release, status}, hands them to sudo -n infra-apply and
     refuses everything else; infra-apply dispatches the same verbs, and so does the sudo rule.
     deploy.yml offers release, resume, rollback and status, and its ssh calls send only release
     (every action but status) or status (status and rollback), always as the checked DEPLOY_USER.
  2. deploy_sudo_rule is exactly the two infra-apply verbs, NOPASSWD; the admin's sudoers line is
     "admin ALL=(ALL:ALL) ALL"; both files are written with validate: /usr/sbin/visudo -cf %s.
  3. deploy_user.yml writes the deploy user's authorized_keys whole, root-owned, as one line
     starting restrict,command="/usr/local/sbin/infra-deploy-gate"; the deploy user has
     groups: "", append: false and password: "!".
  4. 10-hardening.conf.j2 renders PasswordAuthentication no, KbdInteractiveAuthentication no,
     PermitRootLogin no and ExposeAuthInfo yes; ssh_permit_root_login defaults to "no";
     ssh_access.yml removes 50-cloud-init.conf and asserts the policy sshd -T reports.
  5. ufw_allowed is exactly SSH and the tailnet-only ports on tailscale0 (no web port: the public
     arrives through the Cloudflare Tunnel); the tailnet-only ports are the same in roles/host's
     tailnet_ports, the compose guard's TAILNET_PORTS, infra-apply's tailnet_ports and
     ci/check_templates.py's TAILNET_PORTS; firewall.yml opens LAN 22 only when ssh_outside_tailnet and deletes it only
     when not ssh_outside_tailnet; ssh_outside_tailnet is set only by tasks/ssh-route.yml (tested in
     ci/verify-tasks.sh), which provision-checks.yml imports; production.yml's public_ports is empty.
  6. provision.yml runs provision-checks as a pre_task and ssh_access as a post_task, and neither
     it nor anything it runs references a Deploy secret.
  7. deploy.yml refuses every ref but refs/heads/master, runs in the production Environment,
     joins the tailnet as tag:infra-ci and refuses SERVER_USER root or the admin user.
  8. Walking provision.yml in run order (pre_tasks, roles, post_tasks, through import_tasks and
     import_role), /etc/apt/preferences.d/docker is written from docker-apt-pin.j2, pinning
     docker-ce, docker-ce-cli and docker-ce-rootless-extras to 5:<docker_engine_major>.*, before
     any apt task that upgrades or installs a Docker package.

--self-test first seeds at least one violation per rule into a temp copy of the tree and requires
each to be caught, then checks the real tree.
"""
from __future__ import annotations

import pathlib
import re
import shutil
import sys
import tempfile

import jinja2
import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKFLOW = ".github/workflows/deploy.yml"
EXTRA_VARS_STEP = "Build extra-vars file from secrets"

VERBS = {"release", "status"}
WORKFLOW_ACTIONS = {"release", "resume", "rollback", "status"}
GATE = "/usr/local/sbin/infra-deploy-gate"
APPLY = "/usr/local/sbin/infra-apply"
DEPLOY_SUDO_RULE = f"(root) NOPASSWD: {APPLY} release, {APPLY} status"
ADMIN_SUDOERS = "admin ALL=(ALL:ALL) ALL\n"
VISUDO = "/usr/sbin/visudo -cf %s"
AUTHORIZED_KEY_PREFIX = f'restrict,command="{GATE}" '
HARDENING_LINES = ("PasswordAuthentication no", "KbdInteractiveAuthentication no", "PermitRootLogin no", "ExposeAuthInfo yes")
UFW_SSH = "in on tailscale0 proto tcp to any port 22"
UFW_TAILNET = "in on tailscale0 proto tcp to any port {port}"
DOCKER_PIN = "/etc/apt/preferences.d/docker"
DOCKER_PINNED = {"docker-ce", "docker-ce-cli", "docker-ce-rootless-extras"}


def load_yaml(path: pathlib.Path):
    return yaml.safe_load(path.read_text())


def tasks_in(root: pathlib.Path, rel: str) -> list[dict]:
    return load_yaml(root / rel) or []


def module_args(task: dict, module: str) -> dict | None:
    for key in (f"ansible.builtin.{module}", module):
        if key in task:
            value = task[key]
            return value if isinstance(value, dict) else {"_raw": value}
    return None


def render(text: str, context: dict) -> str:
    return jinja2.Environment(undefined=jinja2.StrictUndefined, keep_trailing_newline=True).from_string(text).render(**context)


def defaults(root: pathlib.Path) -> dict:
    return load_yaml(root / "roles/common/defaults/main.yml") or {}


def copies_to(tasks: list[dict], dest_pattern: str) -> list[dict]:
    return [a for a in (module_args(t, "copy") for t in tasks) if a is not None and re.search(dest_pattern, str(a.get("dest", "")))]


def steps_of(workflow: dict) -> list[dict]:
    return [s for job in (workflow.get("jobs") or {}).values() for s in job.get("steps") or []]


def ssh_lines(run: str) -> list[str]:
    return [line for line in run.splitlines() if re.search(r"(^|[\s;(|&])ssh\s", line) and not line.lstrip().startswith("#")]


def gate_verbs(text: str) -> tuple[set[str], list[str]]:
    problems = []
    arms = re.findall(r"^\s*([^\s()#]+)\)\s*$", text, re.M)
    allowed = [a for a in arms if a != "*"]
    if len(allowed) != 1 or "*" not in arms:
        return set(), ["rule 1: infra-deploy-gate: expected one case arm of allowed verbs and a * arm that refuses"]
    if f'exec sudo -n {APPLY} "$SSH_ORIGINAL_COMMAND"' not in text:
        problems.append(f'rule 1: infra-deploy-gate: an allowed verb must hand off exactly as exec sudo -n {APPLY} "$SSH_ORIGINAL_COMMAND"')
    refusal = text.split("*)", 1)[1]
    if not re.search(r"exit [1-9]", refusal):
        problems.append("rule 1: infra-deploy-gate: the * arm must exit non-zero")
    if re.search(r"\beval\b|\bsh -c\b|\bbash -c\b", text):
        problems.append("rule 1: infra-deploy-gate: must never evaluate the command it was given")
    return set(allowed[0].split("|")), problems


# Rule 1
def check_verbs(root: pathlib.Path, workflow: dict) -> list[str]:
    files = root / "roles/common/files"
    gate = (files / "infra-deploy-gate").read_text()
    verbs, problems = gate_verbs(gate)
    if verbs and verbs != VERBS:
        problems.append(f"rule 1: infra-deploy-gate: allows {sorted(verbs)}, expected exactly {sorted(VERBS)}")
    apply = (files / "infra-apply").read_text()
    dispatch = set(re.findall(r"^  (\w+)\) do_\w+ ;;$", apply, re.M))
    if dispatch != VERBS:
        problems.append(f"rule 1: infra-apply: dispatches {sorted(dispatch)}, expected exactly {sorted(VERBS)}")
    sudo_verbs = set(re.findall(rf"{re.escape(APPLY)} (\w+)", str(defaults(root).get("deploy_sudo_rule", ""))))
    if sudo_verbs != VERBS:
        problems.append(f"rule 1: deploy_sudo_rule allows {sorted(sudo_verbs)}, expected exactly {sorted(VERBS)}")
    for name, text in (("infra-deploy-gate", gate), ("infra-apply", apply)):
        if not text.startswith("#!/bin/bash\n") or not re.search(r"^set -euo pipefail$", text, re.M):
            problems.append(f"rule 1: {name}: must start with #!/bin/bash and set -euo pipefail")
    on = workflow.get("on", workflow.get(True)) or {}
    inputs = (on.get("workflow_dispatch") or {}).get("inputs") or {}
    if set((inputs.get("action") or {}).get("options") or []) != WORKFLOW_ACTIONS:
        problems.append(f"rule 1: {WORKFLOW}: the action input must offer exactly {sorted(WORKFLOW_ACTIONS)}")
    sends: dict[str, list[str]] = {}
    for step in steps_of(workflow):
        for line in ssh_lines(step.get("run") or ""):
            m = re.search(r'"\$\{DEPLOY_USER\}@\$\{SERVER_SSH_HOST\}" (\w+)\b', line)
            if not m:
                problems.append(f"rule 1: {WORKFLOW}: step {step.get('name')!r} runs ssh other than as \"${{DEPLOY_USER}}@${{SERVER_SSH_HOST}}\" <verb>")
                continue
            if m.group(1) not in VERBS:
                problems.append(f"rule 1: {WORKFLOW}: step {step.get('name')!r} sends {m.group(1)!r}; the gate accepts only {sorted(VERBS)}")
            sends.setdefault(m.group(1), []).append(str(step.get("if", "")))
    release_if = sends.get("release", [])
    status_if = sends.get("status", [])
    if len(release_if) != 1 or "inputs.action != 'status'" not in release_if[0]:
        problems.append(f"rule 1: {WORKFLOW}: exactly one ssh call must send release, for every action but status (if: inputs.action != 'status' ...)")
    if len(status_if) != 1 or "inputs.action == 'status'" not in status_if[0] or "inputs.action == 'rollback'" not in status_if[0]:
        problems.append(f"rule 1: {WORKFLOW}: exactly one ssh call must send status, for status and rollback")
    return problems


# Rule 2
def check_sudo(root: pathlib.Path) -> list[str]:
    problems = []
    values = defaults(root)
    if values.get("deploy_sudo_rule") != DEPLOY_SUDO_RULE:
        problems.append(f"rule 2: roles/common/defaults/main.yml: deploy_sudo_rule must be exactly {DEPLOY_SUDO_RULE!r}")
    for rel, user, want in (("roles/common/tasks/deploy_user.yml", "deploy", f"deploy ALL={DEPLOY_SUDO_RULE}\n"),
                            ("roles/common/tasks/admin_user.yml", "admin", ADMIN_SUDOERS)):
        sudoers = copies_to(tasks_in(root, rel), r"^/etc/sudoers\.d/")
        if len(sudoers) != 1:
            problems.append(f"rule 2: {rel}: expected exactly one sudoers file for the {user} user")
        for args in sudoers:
            content = render(str(args.get("content", "")), {**values, "deploy_sudo_rule": values.get("deploy_sudo_rule")})
            if content != want:
                problems.append(f"rule 2: {rel}: the {user} user's sudoers rule must be exactly {want!r}, got {content!r}")
            if args.get("validate") != VISUDO:
                problems.append(f"rule 2: {rel}: the {user} user's sudoers file must be written with validate: {VISUDO}")
    for path in sorted(root.glob("roles/*/tasks/*.yml")):
        for task in load_yaml(path) or []:
            args = module_args(task, "copy") or {}
            content = str(args.get("content", ""))
            if "NOPASSWD" in content and path.name != "deploy_user.yml":
                problems.append(f"rule 2: {path.relative_to(root)}: writes a NOPASSWD sudo rule; only the deploy user's rule may skip the password")
            if "SETENV" in content:
                problems.append(f"rule 2: {path.relative_to(root)}: a sudo rule with SETENV would let the caller pass environment to infra-apply")
    return problems


# Rule 3
def check_deploy_user(root: pathlib.Path) -> list[str]:
    problems = []
    rel = "roles/common/tasks/deploy_user.yml"
    tasks = tasks_in(root, rel)
    users = [u for u in (module_args(t, "user") for t in tasks) if u is not None and u.get("name") == "{{ deploy_user }}"]
    if len(users) != 1:
        problems.append(f"rule 3: {rel}: expected exactly one user task for {{{{ deploy_user }}}}")
    for user in users:
        if user.get("groups") != "" or user.get("append") is not False:
            problems.append(f"rule 3: {rel}: the deploy user must have groups: \"\" and append: false, so it is in no docker or sudo group")
        if str(user.get("password")) != "!":
            problems.append(f"rule 3: {rel}: the deploy user's password must stay locked (password: \"!\")")
    keys = copies_to(tasks, r"authorized_keys$")
    if len(keys) != 1:
        problems.append(f"rule 3: {rel}: expected exactly one copy task writing the deploy user's authorized_keys")
    for args in keys:
        content = render(str(args.get("content", "")), {"ci_key_line": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKE ci"})
        lines = content.splitlines()
        if len(lines) != 1 or not lines[0].startswith(AUTHORIZED_KEY_PREFIX):
            problems.append(f"rule 3: {rel}: the deploy user's authorized_keys must be exactly one line starting with {AUTHORIZED_KEY_PREFIX!r}")
        if args.get("owner") != "root":
            problems.append(f"rule 3: {rel}: the deploy user's authorized_keys must be owned by root")
    for task in tasks:
        if any(module_args(task, m) is not None for m in ("lineinfile", "blockinfile", "authorized_key", "ansible.posix.authorized_key")) \
                and "authorized_keys" in yaml.safe_dump(task):
            problems.append(f"rule 3: {rel}: authorized_keys must be written whole by one copy task, not edited in place")
    checks = [t for t in tasks if module_args(t, "assert") is not None and "ci_prefix" in (t.get("vars") or {})]
    if len(checks) != 1 or checks[0]["vars"]["ci_prefix"] != AUTHORIZED_KEY_PREFIX:
        problems.append(f"rule 3: {rel}: expected one assert that reads authorized_keys back with ci_prefix {AUTHORIZED_KEY_PREFIX!r}")
    return problems


# Rule 4
def check_sshd(root: pathlib.Path) -> list[str]:
    problems = []
    values = defaults(root)
    if values.get("ssh_permit_root_login") != "no":
        problems.append("rule 4: roles/common/defaults/main.yml: ssh_permit_root_login must default to \"no\"")
    rendered = render((root / "roles/common/templates/10-hardening.conf.j2").read_text(), values).splitlines()
    for line in HARDENING_LINES:
        if line not in rendered:
            problems.append(f"rule 4: roles/common/templates/10-hardening.conf.j2: must render {line!r}")
    rel = "roles/common/tasks/ssh_access.yml"
    tasks = tasks_in(root, rel)
    removes = [a for a in (module_args(t, "file") for t in tasks) if a and a.get("path") == "/etc/ssh/sshd_config.d/50-cloud-init.conf" and a.get("state") == "absent"]
    if len(removes) != 1:
        problems.append(f"rule 4: {rel}: must remove /etc/ssh/sshd_config.d/50-cloud-init.conf (state: absent)")
    effective = [t for t in tasks if str((module_args(t, "command") or {}).get("_raw", "")).strip() == "/usr/sbin/sshd -T"]
    registered = {t.get("register") for t in effective}
    asserted = [t for t in tasks if module_args(t, "assert") is not None and any(r and r in yaml.safe_dump(t) for r in registered)]
    if not effective or not any("passwordauthentication no" in yaml.safe_dump(t) for t in asserted):
        problems.append(f"rule 4: {rel}: must read /usr/sbin/sshd -T and assert passwordauthentication no from it")
    for path in sorted(root.glob("roles/*/tasks/*.yml")):
        for task in load_yaml(path) or []:
            args = module_args(task, "set_fact")
            if args and "ssh_permit_root_login" in args and (args["ssh_permit_root_login"] != "prohibit-password" or str(task.get("when", "")) != "ssh_login_user.stdout == 'root'"):
                problems.append(f"rule 4: {path.relative_to(root)}: ssh_permit_root_login may only become prohibit-password, and only while the run itself logs in as root")
    return problems


def tailnet_port_lists(root: pathlib.Path) -> dict[str, list[tuple[str, int]]]:
    """(container, port) pairs, sorted, from each place that lists the tailnet-only ports."""
    host = load_yaml(root / "roles/host/defaults/main.yml") or {}
    guard = (root / "roles/common/files/infra-compose-guard").read_text()
    apply = (root / "roles/common/files/infra-apply").read_text()
    templates = (root / "ci/check_templates.py").read_text()

    def py_dict(text: str) -> list[tuple[str, int]]:
        body = re.search(r"^TAILNET_PORTS = \{(.*?)^\}", text, re.M | re.S)
        return sorted((s, int(p)) for _, s, p in re.findall(r'\("(\w+)", "([\w-]+)"\): (\d+)', body.group(1) if body else ""))

    apply_body = re.search(r"^readonly tailnet_ports=\((.*?)\)", apply, re.M | re.S)
    return {
        "roles/host/defaults/main.yml tailnet_ports": sorted((str(e["container"]), int(e["port"])) for e in host.get("tailnet_ports") or []),
        "roles/common/files/infra-compose-guard TAILNET_PORTS": py_dict(guard),
        "roles/common/files/infra-apply tailnet_ports": sorted((n, int(p)) for n, p in re.findall(r'"([\w-]+) (\d+)"', apply_body.group(1) if apply_body else "")),
        "ci/check_templates.py TAILNET_PORTS": py_dict(templates),
    }


# Rule 5
def check_firewall(root: pathlib.Path) -> list[str]:
    problems = []
    lists = tailnet_port_lists(root)
    reference = lists["roles/host/defaults/main.yml tailnet_ports"]
    if not reference:
        problems.append("rule 5: roles/host/defaults/main.yml: tailnet_ports is empty or unreadable")
    for where, pairs in lists.items():
        if pairs != reference:
            problems.append(f"rule 5: {where} lists {pairs}, but roles/host/defaults/main.yml tailnet_ports lists {reference}")
    ufw_allowed = [UFW_SSH] + [UFW_TAILNET.format(port=port) for port in sorted({p for _, p in reference})]
    if defaults(root).get("ufw_allowed") != ufw_allowed:
        problems.append(f"rule 5: roles/common/defaults/main.yml: ufw_allowed must be exactly {ufw_allowed}")
    rel = "roles/common/tasks/firewall.yml"
    tasks = tasks_in(root, rel)
    for command, when in (("ufw allow 22/tcp", "ssh_outside_tailnet"), ("ufw delete allow 22/tcp", "not ssh_outside_tailnet")):
        found = [t for t in tasks if str((module_args(t, "command") or {}).get("_raw", "")).strip() == command]
        if len(found) != 1 or str(found[0].get("when", "")).strip() != when:
            problems.append(f"rule 5: {rel}: {command!r} must run exactly once, only when: {when}")
    for task in tasks:
        raw = str((module_args(task, "command") or {}).get("_raw", ""))
        if re.search(r"ufw (allow|delete allow)", raw) and raw.strip() not in ("ufw allow {{ item }}", "ufw allow 22/tcp", "ufw delete allow 22/tcp"):
            problems.append(f"rule 5: {rel}: an extra ufw rule {raw.strip()!r}; list allowed ports in ufw_allowed")
    setters = sorted(str(p.relative_to(root)) for p in [root / "provision.yml", *root.glob("tasks/*.yml"), *root.glob("roles/**/*.yml")]
                     if any("ssh_outside_tailnet" in (module_args(t, "set_fact") or {}) for t in (load_yaml(p) or []) if isinstance(t, dict)))
    imports = [module_args(t, "import_tasks") for t in tasks_in(root, "tasks/provision-checks.yml")]
    if setters != ["tasks/ssh-route.yml"] or not any(a and a.get("_raw") == "ssh-route.yml" for a in imports):
        problems.append(f"rule 5: ssh_outside_tailnet must be set only by tasks/ssh-route.yml, imported by tasks/provision-checks.yml (set by {setters})")
    if (load_yaml(root / "production.yml") or {}).get("public_ports") != []:
        problems.append("rule 5: production.yml: public_ports must be [] (the LAN-facing interface reaches no Docker-published port)")
    return problems


def extra_var_keys(workflow: dict) -> set[str]:
    steps = [s for s in steps_of(workflow) if s.get("name") == EXTRA_VARS_STEP]
    if len(steps) != 1:
        return set()
    return set(re.findall(r"^\s*([a-z0-9_]+):\s*env\.", steps[0].get("run") or "", re.M))


# Rule 6
def check_provision(root: pathlib.Path, workflow: dict) -> list[str]:
    problems = []
    plays = load_yaml(root / "provision.yml") or []
    if len(plays) != 1:
        return ["rule 6: provision.yml: expected exactly one play"]
    play = plays[0]
    pre = [module_args(t, "import_tasks") for t in play.get("pre_tasks") or []]
    if not any(a and a.get("_raw") == "tasks/provision-checks.yml" for a in pre):
        problems.append("rule 6: provision.yml: pre_tasks must import tasks/provision-checks.yml")
    post = [module_args(t, "import_role") for t in play.get("post_tasks") or []]
    if not any(a and a.get("name") == "common" and a.get("tasks_from") == "ssh_access" for a in post):
        problems.append("rule 6: provision.yml: post_tasks must import_role common, tasks_from: ssh_access")
    secrets = extra_var_keys(workflow)
    if not secrets:
        problems.append(f"rule 6: {WORKFLOW}: the {EXTRA_VARS_STEP!r} step's keys were not found")
    scanned = [root / "provision.yml", root / "production.yml", *root.glob("tasks/*.yml"), *root.glob("roles/**/*.yml"), *root.glob("roles/*/templates/*.j2")]
    for path in sorted(set(scanned)):
        text = path.read_text()
        for key in sorted(secrets):
            if re.search(rf"\b{re.escape(key)}\b", text):
                problems.append(f"rule 6: {path.relative_to(root)}: references the Deploy secret {key!r}; provisioning holds no app secrets")
    return problems


# Rule 7
def check_workflow(workflow: dict) -> list[str]:
    problems = []
    steps = steps_of(workflow)
    runs = "\n".join(s.get("run") or "" for s in steps)
    if not re.search(r'if \[ "\$GITHUB_REF" != refs/heads/master \]; then\n(.*\n)*?\s*exit 1', runs):
        problems.append(f"rule 7: {WORKFLOW}: must refuse every ref but refs/heads/master ([ \"$GITHUB_REF\" != refs/heads/master ] ... exit 1)")
    for name, job in (workflow.get("jobs") or {}).items():
        if job.get("environment") != "production":
            problems.append(f"rule 7: {WORKFLOW}: job {name!r} must run in environment: production")
    tailnet = [s for s in steps if str(s.get("uses", "")).startswith("tailscale/github-action@")]
    if len(tailnet) != 1 or (tailnet[0].get("with") or {}).get("tags") != "tag:infra-ci":
        problems.append(f"rule 7: {WORKFLOW}: exactly one tailscale/github-action step must join with tags: tag:infra-ci")
    guards = [s for s in steps if "SERVER_USER" in (s.get("env") or {})]
    if len(guards) != 1:
        problems.append(f"rule 7: {WORKFLOW}: exactly one step must read SERVER_USER")
    for step in guards:
        run = step.get("run") or ""
        if '"${SERVER_USER:-deploy}"' not in run or not re.search(r'root \| admin \| "\$admin_user"\)', run) or "exit 1" not in run:
            problems.append(f"rule 7: {WORKFLOW}: the SERVER_USER step must default to deploy and refuse root, admin and the admin_user of roles/common/defaults/main.yml")
    return problems


def provision_tasks(root: pathlib.Path) -> list[tuple[str, dict]]:
    """Every task provision.yml runs, in run order, as (file, task), through static imports."""
    def expand(rel: str, role: str | None, seen: tuple[str, ...]) -> list[tuple[str, dict]]:
        if rel in seen:
            raise ValueError(f"import loop at {rel}")
        out: list[tuple[str, dict]] = []
        for task in tasks_in(root, rel):
            inc = module_args(task, "import_tasks") or module_args(task, "include_tasks")
            ref = module_args(task, "import_role") or module_args(task, "include_role")
            if inc is not None:
                target = str(inc.get("_raw") or inc.get("file"))
                base = f"roles/{role}/tasks" if role else str(pathlib.PurePosixPath(rel).parent)
                out += expand(str(pathlib.PurePosixPath(base) / target), role, (*seen, rel))
            elif ref is not None:
                name = str(ref["name"])
                out += expand(f"roles/{name}/tasks/{ref.get('tasks_from', 'main')}.yml", name, (*seen, rel))
            else:
                out.append((rel, task))
        return out

    play = (load_yaml(root / "provision.yml") or [{}])[0]
    ordered: list[tuple[str, dict]] = []
    for task in play.get("pre_tasks") or []:
        inc = module_args(task, "import_tasks")
        ordered += expand(str(inc["_raw"]), None, ()) if inc else [("provision.yml", task)]
    for entry in play.get("roles") or []:
        name = entry["role"] if isinstance(entry, dict) else entry
        ordered += expand(f"roles/{name}/tasks/main.yml", name, ())
    for task in play.get("post_tasks") or []:
        ref = module_args(task, "import_role")
        ordered += expand(f"roles/{ref['name']}/tasks/{ref.get('tasks_from', 'main')}.yml", ref["name"], ()) if ref else [("provision.yml", task)]
    return ordered


# Rule 8
def check_docker_pin(root: pathlib.Path) -> list[str]:
    problems = []
    ordered = provision_tasks(root)
    pins = [i for i, (_, t) in enumerate(ordered) if str((module_args(t, "template") or {}).get("dest", "")) == DOCKER_PIN]
    for i in pins:
        rel, task = ordered[i]
        args = module_args(task, "template") or {}
        if args.get("src") != "docker-apt-pin.j2" or not rel.startswith("roles/docker/"):
            problems.append(f"rule 8: {rel}: {DOCKER_PIN} must be written from roles/docker/templates/docker-apt-pin.j2")
    text = render((root / "roles/docker/templates/docker-apt-pin.j2").read_text(), {"docker_engine_major": 29})
    packages = set(re.findall(r"^Package:\s*(.*)$", text, re.M)[0].split()) if re.search(r"^Package:", text, re.M) else set()
    if not DOCKER_PINNED <= packages or not re.search(r"^Pin: version 5:29\.\*$", text, re.M) or not re.search(r"^Pin-Priority: (\d+)$", text, re.M):
        problems.append(f"rule 8: roles/docker/templates/docker-apt-pin.j2: must pin {sorted(DOCKER_PINNED)} to version 5:{{{{ docker_engine_major }}}}.* with a Pin-Priority")
    first_pin = pins[0] if pins else len(ordered)
    for i, (rel, task) in enumerate(ordered[:first_pin]):
        args = module_args(task, "apt")
        if args is None:
            continue
        names = args.get("name") or args.get("pkg") or []
        names = [names] if isinstance(names, str) else list(names)
        upgrades = str(args.get("upgrade", "no")).lower() not in ("no", "false")
        if upgrades or any(str(n).startswith(("docker", "containerd")) for n in names):
            problems.append(f"rule 8: {rel}: apt task {task.get('name')!r} runs before {DOCKER_PIN} is written and could move the Docker Engine major")
    if not pins:
        problems.append(f"rule 8: provision.yml: nothing it runs writes {DOCKER_PIN}")
    return problems


def run_checks(root: pathlib.Path) -> list[str]:
    problems: list[str] = []
    try:
        workflow = load_yaml(root / WORKFLOW)
    except (OSError, yaml.YAMLError) as e:
        return [f"{WORKFLOW}: could not be read: {type(e).__name__}: {e}"]
    checks = [lambda: check_verbs(root, workflow), lambda: check_sudo(root), lambda: check_deploy_user(root), lambda: check_sshd(root),
              lambda: check_firewall(root), lambda: check_provision(root, workflow), lambda: check_workflow(workflow),
              lambda: check_docker_pin(root)]
    for number, check in enumerate(checks, 1):
        try:
            problems += check()
        except (KeyError, TypeError, AttributeError, IndexError, ValueError, OSError, yaml.YAMLError, jinja2.TemplateError) as e:
            problems.append(f"rule {number}: could not read its inputs: {type(e).__name__}: {e}")
    return problems


def self_test() -> None:
    def edit(rel: str, old: str, new: str):
        def mutate(tmp: pathlib.Path) -> None:
            path = tmp / rel
            text = path.read_text()
            if old not in text:
                raise SystemExit(f"self-test setup failed: {old!r} not in {rel}")
            path.write_text(text.replace(old, new, 1))
        return mutate

    def append(rel: str, extra: str):
        def mutate(tmp: pathlib.Path) -> None:
            path = tmp / rel
            path.write_text(path.read_text() + extra)
        return mutate

    gate = "roles/common/files/infra-deploy-gate"
    cases = [
        ("1", "the gate allows a shell", edit(gate, "release|status)", "release|status|bash)"), "allows ['bash', 'release', 'status']"),
        ("1", "the gate drops a verb", edit(gate, "release|status)", "release)"), "expected exactly ['release', 'status']"),
        ("1", "the gate evaluates the command", edit(gate, 'exec sudo -n /usr/local/sbin/infra-apply "$SSH_ORIGINAL_COMMAND"', 'eval "$SSH_ORIGINAL_COMMAND"'), "must never evaluate"),
        ("1", "the gate's refusal exits zero", edit(gate, "exit 64", "exit 0"), "the * arm must exit non-zero"),
        ("1", "infra-apply grows a verb", edit("roles/common/files/infra-apply", "  status) do_status ;;\n", "  status) do_status ;;\n  shell) do_status ;;\n"), "infra-apply: dispatches"),
        ("1", "the workflow grows an action", edit(WORKFLOW, "          - status\n", "          - status\n          - shell\n"), "the action input must offer exactly"),
        ("1", "the workflow sends rollback over ssh", edit(WORKFLOW, '"${DEPLOY_USER}@${SERVER_SSH_HOST}" release <', '"${DEPLOY_USER}@${SERVER_SSH_HOST}" rollback <'), "sends 'rollback'"),
        ("1", "the workflow sends release for status", edit(WORKFLOW, "      - name: Release on the server\n        if: inputs.action != 'status' && ", "      - name: Release on the server\n        if: inputs.action == 'release' && "),
         "exactly one ssh call must send release"),
        ("1", "the workflow connects as root", edit(WORKFLOW, '"${DEPLOY_USER}@${SERVER_SSH_HOST}" status', '"root@${SERVER_SSH_HOST}" status'), "runs ssh other than as"),
        ("2", "deploy sudo widened to ALL", edit("roles/common/tasks/deploy_user.yml", "ALL={{ deploy_sudo_rule }}", "ALL=(ALL:ALL) NOPASSWD: ALL"), "the deploy user's sudoers rule must be exactly"),
        ("2", "deploy sudo allows any argument", edit("roles/common/defaults/main.yml", "/usr/local/sbin/infra-apply release, /usr/local/sbin/infra-apply status", "/usr/local/sbin/infra-apply"),
         "deploy_sudo_rule must be exactly"),
        ("2", "admin sudo without a password", edit("roles/common/tasks/admin_user.yml", "ALL=(ALL:ALL) ALL", "ALL=(ALL:ALL) NOPASSWD: ALL"), "the admin user's sudoers rule must be exactly"),
        ("2", "a sudoers file written without visudo", edit("roles/common/tasks/admin_user.yml", "    validate: /usr/sbin/visudo -cf %s\n", ""), "must be written with validate"),
        ("3", "the deploy key without the forced command", edit("roles/common/tasks/deploy_user.yml", 'restrict,command=\\"/usr/local/sbin/infra-deploy-gate\\" {{ ci_key_line }}', "{{ ci_key_line }}"),
         "exactly one line starting with"),
        ("3", "deploy authorized_keys owned by the deploy user", edit("roles/common/tasks/deploy_user.yml", "    content: \"restrict,command=\\\"/usr/local/sbin/infra-deploy-gate\\\" {{ ci_key_line }}\\n\"\n    owner: root",
                                                                       "    content: \"restrict,command=\\\"/usr/local/sbin/infra-deploy-gate\\\" {{ ci_key_line }}\\n\"\n    owner: \"{{ deploy_user }}\""),
         "authorized_keys must be owned by root"),
        ("3", "the deploy user in the docker group", edit("roles/common/tasks/deploy_user.yml", 'groups: ""', "groups: docker"), "in no docker or sudo group"),
        ("3", "the deploy user with a password", edit("roles/common/tasks/deploy_user.yml", 'password: "!"', 'password: "{{ deploy_password }}"'), "password must stay locked"),
        ("4", "password logins back on", edit("roles/common/templates/10-hardening.conf.j2", "PasswordAuthentication no", "PasswordAuthentication yes"), "must render 'PasswordAuthentication no'"),
        ("4", "root login allowed by default", edit("roles/common/defaults/main.yml", 'ssh_permit_root_login: "no"', 'ssh_permit_root_login: "prohibit-password"'), "must default to \"no\""),
        ("4", "cloud-init's drop-in kept", edit("roles/common/tasks/ssh_access.yml", "    path: /etc/ssh/sshd_config.d/50-cloud-init.conf\n    state: absent", "    path: /etc/ssh/sshd_config.d/50-cloud-init.conf\n    state: file"),
         "must remove /etc/ssh/sshd_config.d/50-cloud-init.conf"),
        ("4", "the effective policy no longer asserted", edit("roles/common/tasks/ssh_access.yml", "      - \"'passwordauthentication no' in sshd_effective.stdout_lines\"\n", ""),
         "must read /usr/sbin/sshd -T and assert"),
        ("5", "public SSH in ufw_allowed", edit("roles/common/defaults/main.yml", "  - in on tailscale0 proto tcp to any port 22\n", "  - in on tailscale0 proto tcp to any port 22\n  - 22/tcp\n"), "ufw_allowed must be exactly"),
        ("5", "the web ports opened again", edit("roles/common/defaults/main.yml", "  - in on tailscale0 proto tcp to any port 22\n", "  - in on tailscale0 proto tcp to any port 22\n  - 80/tcp\n  - 443/tcp\n"), "ufw_allowed must be exactly"),
        ("5", "a tailnet port opened on every interface", edit("roles/common/defaults/main.yml", "  - in on tailscale0 proto tcp to any port 8080\n", "  - 8080/tcp\n"), "ufw_allowed must be exactly"),
        ("5", "a tailnet port the guard does not know", edit("roles/host/defaults/main.yml", "  - { container: open-webui, port: 8080 }\n", "  - { container: open-webui, port: 8080 }\n  - { container: ollama, port: 11434 }\n"),
         "roles/common/files/infra-compose-guard TAILNET_PORTS lists"),
        ("5", "infra-apply checking another port", edit("roles/common/files/infra-apply", '"open-webui 8080" "jellyfin 8096"', '"open-webui 8081" "jellyfin 8096"'),
         "roles/common/files/infra-apply tailnet_ports lists [('audiobookshelf', 13378), ('jellyfin', 8096), ('kavita', 5000), ('open-webui', 8081)]"),
        ("5", "a published port admitted on the LAN", edit("production.yml", "public_ports: []", "public_ports: [443]"), "public_ports must be []"),
        ("5", "LAN 22 deleted on a run outside the tailnet", edit("roles/common/tasks/firewall.yml", "  when: not ssh_outside_tailnet\n", ""), "'ufw delete allow 22/tcp' must run exactly once"),
        ("5", "a second definition of the SSH route", append("roles/common/tasks/firewall.yml", "\n- name: Guess the route\n  ansible.builtin.set_fact:\n    ssh_outside_tailnet: false\n"),
         "ssh_outside_tailnet must be set only by tasks/ssh-route.yml"),
        ("5", "the SSH route no longer imported", edit("tasks/provision-checks.yml", "ansible.builtin.import_tasks: ssh-route.yml", "ansible.builtin.import_tasks: placeholder-guards.yml"),
         "ssh_outside_tailnet must be set only by tasks/ssh-route.yml"),
        ("6", "provision without its pre-checks", edit("provision.yml", "      ansible.builtin.import_tasks: tasks/provision-checks.yml\n", "      ansible.builtin.import_tasks: tasks/placeholder-guards.yml\n"),
         "pre_tasks must import tasks/provision-checks.yml"),
        ("6", "ssh_access no longer last", edit("provision.yml", "        tasks_from: ssh_access\n", "        tasks_from: main\n"), "post_tasks must import_role common"),
        ("6", "a role reads a Deploy secret", append("roles/edge/defaults/main.yml", "edge_ghcr_token: \"{{ ghcr_token }}\"\n"), "references the Deploy secret 'ghcr_token'"),
        ("7", "any branch may deploy", edit(WORKFLOW, '"$GITHUB_REF" != refs/heads/master', '"$GITHUB_REF" = refs/heads/nothing'), "must refuse every ref but refs/heads/master"),
        ("7", "no production Environment", edit(WORKFLOW, "    environment: production\n", ""), "must run in environment: production"),
        ("7", "the runner joins with another tag", edit(WORKFLOW, "tags: tag:infra-ci", "tags: tag:infra-server"), "join with tags: tag:infra-ci"),
        ("7", "SERVER_USER may be root", edit(WORKFLOW, '            root | admin | "$admin_user")', '            admin | "$admin_user")'), "refuse root, admin and the admin_user"),
        ("8", "the pin written only by the docker role, after the upgrade", edit("roles/common/tasks/essentials.yml", "    name: docker\n    tasks_from: pin\n", "    name: docker\n    tasks_from: verify\n"),
         "apt task 'Update apt cache and upgrade base packages' runs before"),
        ("8", "the upgrade moved above the pin", edit("roles/common/tasks/main.yml", "- name: Install essentials\n", "- name: Upgrade first\n  ansible.builtin.apt:\n    upgrade: safe\n\n- name: Install essentials\n"),
         "apt task 'Upgrade first' runs before"),
        ("8", "Docker installed from a pre-task", edit("tasks/provision-checks.yml", "---\n", "---\n- name: Early Docker\n  ansible.builtin.apt:\n    name: [docker-ce]\n"), "apt task 'Early Docker' runs before"),
        ("8", "the pin drops docker-ce-cli", edit("roles/docker/templates/docker-apt-pin.j2", "docker-ce docker-ce-cli", "docker-ce"), "must pin ['docker-ce', 'docker-ce-cli'"),
        ("8", "the pin removed", edit("roles/docker/tasks/pin.yml", "    dest: /etc/apt/preferences.d/docker\n", "    dest: /etc/apt/preferences.d/other\n"), "nothing it runs writes"),
    ]
    caught_rules = set()
    for rule, name, mutate, expected in cases:
        with tempfile.TemporaryDirectory() as d:
            tmp = pathlib.Path(d) / "root"
            shutil.copytree(ROOT, tmp, ignore=shutil.ignore_patterns(".git", ".claude", "plans", "audit", "__pycache__"))
            mutate(tmp)
            problems = run_checks(tmp)
            if not any(expected in p and p.startswith(f"rule {rule}:") for p in problems):
                raise SystemExit(f"self-test FAILED: rule {rule}: {name}: expected a problem containing {expected!r}, got {problems}")
            caught_rules.add(rule)
            print(f"ok   rule {rule} caught: {name}")
    missing = {str(n) for n in range(1, 9)} - caught_rules
    if missing:
        raise SystemExit(f"self-test FAILED: no seeded violation for rules {sorted(missing)}")
    print("self-test: every widened access was caught")


def main() -> int:
    if "--self-test" in sys.argv[1:]:
        self_test()
    problems = run_checks(ROOT)
    for p in problems:
        print(f"::error::{p}")
    if problems:
        return 1
    print("deploy access: the gate, infra-apply, the sudo rule and the workflow agree on release and status; sudo validated, admin sudo "
          "asks for a password; the deploy key is root-owned and forced to the gate; key-only sshd; ufw admits SSH and the tailnet-only ports on tailscale0 alone, no LAN port; "
          "provision holds no secret; master only, production Environment, tag:infra-ci, never root; the Docker pin precedes every apt upgrade")
    return 0


if __name__ == "__main__":
    sys.exit(main())
