#!/usr/bin/env python3
"""Stdlib-only helper for the Supabase -> Openship repo.

Subcommands:
  render       Turn `docker compose config --no-interpolate --format json` output
               into a single, Openship-friendly openship-compose.yml.
  resolve-env  Build a complete, flat env file (.env.openship) for Openship's
               "Import .env" from your secret .env plus the defaults recorded
               at render time.
  binds        Print every host bind-mount source referenced by a compose
               file rendered by this tool (used by bootstrap.sh host).
"""
import argparse
import json
import os
import re
import sys

# Keys Openship ignores or that only work with real `docker compose up`.
DROP_SERVICE_KEYS = {
    "container_name", "networks", "security_opt", "logging", "labels",
    "env_file", "profiles", "pull_policy",
}
# Keys the Openship teammate confirmed are tracked/applied. Others are kept but warned.
KNOWN_OK = {
    "image", "build", "dockerfile", "ports", "depends_on", "environment",
    "volumes", "command", "restart", "healthcheck", "entrypoint",
    "extra_hosts", "shm_size", "deploy", "mem_limit", "cpus",
}

# upstream ./volumes/<rel> -> host path (relative to SUPABASE_ROOT)
DATA_MAP = [
    ("db/data", "data/db"),
    ("storage", "data/storage"),
    ("snippets", "data/snippets"),
    ("functions", "functions"),
]

warnings = []


def warn(msg):
    warnings.append(msg)


# ---------------------------------------------------------------- ${VAR} parsing
def parse_expr(s, i):
    """s[i:] starts with '${'. Return (name, op, default_raw, end_index)."""
    j = i + 2
    m = re.match(r"[A-Za-z_][A-Za-z0-9_]*", s[j:])
    if not m:
        raise ValueError("bad expression at %r" % s[i:i + 30])
    name = m.group(0)
    j += len(name)
    op = None
    default = None
    if s[j] != "}":
        for cand in (":-", ":?", ":+", "-", "?", "+"):
            if s.startswith(cand, j):
                op = cand
                j += len(cand)
                break
        else:
            raise ValueError("bad operator at %r" % s[i:i + 40])
        depth = 1
        start = j
        while j < len(s):
            if s.startswith("${", j):
                depth += 1
                j += 2
                continue
            if s[j] == "{":  # literal braces in defaults, e.g. {"keys":[]}
                depth += 1
            elif s[j] == "}":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        default = s[start:j]
    return name, op, default, j + 1


def flatten(s, vars_seen):
    """Replace ${A:-...} etc. with ${A}; record defaults/fallbacks in vars_seen."""
    out = []
    i = 0
    while i < len(s):
        if s.startswith("$$", i):
            out.append("$$")
            i += 2
            continue
        if s.startswith("${", i):
            name, op, default, end = parse_expr(s, i)
            rec = vars_seen.setdefault(name, {"default": None, "fallback": None, "required": False})
            if op in (":-", "-"):
                if default.startswith("${") and default.endswith("}"):
                    inner = flatten(default, vars_seen)
                    if rec["fallback"] not in (None, inner[2:-1]) or rec["default"] is not None:
                        warn("%s has different defaults at different call sites; "
                             "set it explicitly in .env" % name)
                        rec["conflict"] = True
                    rec["fallback"] = inner[2:-1]
                else:
                    if "${" in default:
                        warn("complex default for %s kept literal: %s" % (name, default))
                    if (rec["default"] not in (None, default)) or rec["fallback"] is not None:
                        warn("%s has different defaults at different call sites; "
                             "set it explicitly in .env" % name)
                        rec["conflict"] = True
                    rec["default"] = default
            elif op in (":?", "?"):
                rec["required"] = True
            elif op is not None:
                warn("operator %s for %s not supported; treated as plain ${%s}" % (op, name, name))
            out.append("${%s}" % name)
            i = end
            continue
        out.append(s[i])
        i += 1
    return "".join(out)


def walk(obj, fn):
    if isinstance(obj, str):
        return fn(obj)
    if isinstance(obj, list):
        return [walk(x, fn) for x in obj]
    if isinstance(obj, dict):
        return {k: walk(v, fn) for k, v in obj.items()}
    return obj


def resolve_simple(s, env):
    """Resolve ${A}/${A:-x} (non-nested) using env dict; used for ports only."""
    def rep(m):
        name, dflt = m.group(1), m.group(3)
        v = env.get(name, "")
        return v if v != "" else (dflt or "")
    prev = None
    while prev != s:
        prev = s
        s = re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(:-([^${}]*))?\}", rep, s)
    return s


# ---------------------------------------------------------------- tiny YAML emitter
def yq(s):
    return json.dumps(s, ensure_ascii=False)


def emit(obj, indent=0):
    pad = "  " * indent
    lines = []
    if isinstance(obj, dict):
        if not obj:
            return [pad + "{}"]
        for k, v in obj.items():
            key = k if re.match(r"^[A-Za-z0-9_.-]+$", k) else yq(k)
            if isinstance(v, (dict, list)) and v:
                lines.append("%s%s:" % (pad, key))
                lines.extend(emit(v, indent + 1))
            else:
                lines.append("%s%s: %s" % (pad, key, scalar(v)))
    elif isinstance(obj, list):
        for v in obj:
            if isinstance(v, (dict, list)) and v:
                sub = emit(v, indent + 1)
                lines.append("%s- %s" % (pad, sub[0].lstrip()))
                lines.extend(sub[1:])
            else:
                lines.append("%s- %s" % (pad, scalar(v)))
    else:
        lines.append(pad + scalar(obj))
    return lines


def scalar(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if v is None:
        return "null"
    if isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, dict):
        return "{}"
    if isinstance(v, list):
        return "[]"
    return yq(str(v))


# ---------------------------------------------------------------- render
def map_bind(src, project_dir, root):
    pd = project_dir.rstrip("/") + "/"
    if not src.startswith(pd):
        return src  # absolute host path (e.g. docker.sock) - left as is
    rel = src[len(pd):]
    if rel.startswith("volumes/"):
        r = rel[len("volumes/"):]
        for up, host in DATA_MAP:
            if r == up or r.startswith(up + "/"):
                return os.path.join(root, host + r[len(up):])
        return os.path.join(root, "config", r)
    warn("bind source outside volumes/: %s -> %s/%s (create it on the host)" % (rel, root, rel))
    return os.path.join(root, rel)


def cmd_render(a):
    data = json.load(open(a.input))
    port_env = {}
    for path in a.port_env:
        port_env.update(read_env(path))
    port_env.update(dict(kv.split("=", 1) for kv in a.set))

    services_out = {}
    vars_seen = {}
    for name, svc in data.get("services", {}).items():
        svc = dict(svc)
        for k in list(svc):
            if k in DROP_SERVICE_KEYS:
                del svc[k]
        for k in svc:
            if k not in KNOWN_OK:
                warn("service %s: key '%s' kept but not confirmed as applied by Openship" % (name, k))
        # environment -> mapping (compose emits a list after some merges)
        if isinstance(svc.get("environment"), list):
            env = {}
            for item in svc["environment"]:
                k, sep, v = item.partition("=")
                env[k] = v if sep else "${%s}" % k
            svc["environment"] = dict(sorted(env.items()))
        # depends_on -> plain list (Openship only uses ordering)
        if isinstance(svc.get("depends_on"), dict):
            svc["depends_on"] = list(svc["depends_on"].keys())
        # ports -> BIND_ADDR:published:target
        if "ports" in svc:
            new = []
            for p in svc["ports"]:
                if isinstance(p, dict):
                    p = "%s:%s/%s" % (p.get("published", ""), p["target"], p.get("protocol", "tcp"))
                p = resolve_simple(p, port_env)
                parts = p.split(":")
                if len(parts) == 2:
                    p = "%s:%s" % (a.bind_addr, p)
                new.append(p)
            svc["ports"] = new
        # volumes -> short syntax with absolute host paths
        if "volumes" in svc:
            new = []
            for v in svc["volumes"]:
                if isinstance(v, str):
                    new.append(v)
                    continue
                t = v.get("type")
                if t == "bind":
                    src = map_bind(v["source"], a.project_dir, a.root)
                elif t == "volume":
                    src = v["source"]
                else:
                    warn("service %s: volume type %s left as long syntax" % (name, t))
                    new.append(v)
                    continue
                s = "%s:%s" % (src, v["target"])
                if v.get("read_only"):
                    s += ":ro"
                new.append(s)
            svc["volumes"] = new
        # Supavisor: avoid "$$(cat file)" (needs compose's $$ escaping + shell).
        if "command" in svc and isinstance(svc["command"], list):
            svc["command"] = [
                c.replace('/app/bin/supavisor eval "$$(cat /etc/pooler/pooler.exs)"',
                          "/app/bin/supavisor eval 'Code.eval_file(\"/etc/pooler/pooler.exs\")'")
                for c in svc["command"]
            ]
        svc = walk(svc, lambda s: flatten(s, vars_seen))
        blob = json.dumps(svc)
        if "$$" in blob:
            warn("service %s still contains '$$' (compose escape) - check Openship handles it" % name)
        services_out[name] = svc

    top_vols = {k: {} for k in (data.get("volumes") or {})}
    out = {"services": services_out}
    if top_vols:
        out["volumes"] = top_vols

    header = [
        "# GENERATED by scripts/render.sh from upstream/ (%s). DO NOT EDIT BY HAND." % a.ref,
        "# Edit render.conf / overrides/*.yml and re-run scripts/render.sh instead.",
        "# Secrets stay as ${VAR} placeholders; set them in Openship (Import .env).",
        "",
    ]
    with open(a.output, "w") as f:
        f.write("\n".join(header + emit(out)) + "\n")
    with open(a.vars_out, "w") as f:
        json.dump(dict(sorted(vars_seen.items())), f, indent=2)
        f.write("\n")
    for w in warnings:
        print("WARN: " + w, file=sys.stderr)
    print("rendered %d services, %d variables -> %s" % (len(services_out), len(vars_seen), a.output))


# ---------------------------------------------------------------- env resolution
def read_env(path):
    env = {}
    if not os.path.exists(path):
        return env
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\r\n")
        if not line or line.lstrip().startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        k = k.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            v = v[1:-1]
        env[k] = v
    return env


def cmd_resolve_env(a):
    vars_seen = json.load(open(a.vars))
    env = {}
    for path in a.env:
        env.update(read_env(path))

    def value(name, depth=0):
        if depth > 10:
            raise SystemExit("fallback loop at %s" % name)
        v = env.get(name, "")
        if v != "":
            return v
        rec = vars_seen.get(name, {})
        if rec.get("conflict"):
            return None  # ambiguous default: must be set explicitly
        if rec.get("fallback"):
            return value(rec["fallback"], depth + 1)
        if rec.get("default") is not None:
            return rec["default"]
        return None

    missing = []
    lines = ["# GENERATED by scripts/bootstrap.sh / resolve-env. CONTAINS SECRETS. Never commit.",
             "# Import into Openship: project > Environment > Import .env"]
    for name in sorted(vars_seen):
        v = value(name)
        if v is None:
            missing.append(name)
            v = ""
        if "\n" in v:
            raise SystemExit("multi-line value for %s not supported" % name)
        lines.append("%s=%s" % (name, v))
    old = os.umask(0o077)
    try:
        with open(a.output, "w") as f:
            f.write("\n".join(lines) + "\n")
    finally:
        os.umask(old)
    hard = [m for m in missing if vars_seen[m].get("conflict") or vars_seen[m].get("required")]
    for m in missing:
        print("WARN: %s has no value and no default (left empty)" % m, file=sys.stderr)
    if hard:
        raise SystemExit("ERROR: must be set explicitly in .env: " + ", ".join(hard))
    print("wrote %d variables -> %s" % (len(vars_seen), a.output))


def cmd_binds(a):
    for line in open(a.compose):
        m = re.match(r'^\s+- "(/[^":]+):[^"]*"$', line)
        if m:
            print(m.group(1))


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("render")
    r.add_argument("--input", required=True)
    r.add_argument("--output", required=True)
    r.add_argument("--vars-out", required=True)
    r.add_argument("--project-dir", required=True)
    r.add_argument("--root", required=True)
    r.add_argument("--bind-addr", required=True)
    r.add_argument("--ref", default="unknown")
    r.add_argument("--port-env", action="append", default=[])
    r.add_argument("--set", action="append", default=[])
    e = sub.add_parser("resolve-env")
    e.add_argument("--vars", required=True)
    e.add_argument("--env", action="append", required=True)
    e.add_argument("--output", required=True)
    b = sub.add_parser("binds")
    b.add_argument("--compose", required=True)
    a = p.parse_args()
    {"render": cmd_render, "resolve-env": cmd_resolve_env, "binds": cmd_binds}[a.cmd](a)


if __name__ == "__main__":
    main()
