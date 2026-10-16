#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    echo "请使用 sudo bash $0 <check|start|status|restore> 运行，不要 source。" >&2
    return 1
fi

export PYTHONUNBUFFERED=1 PYTHONUTF8=1
command -v python3 >/dev/null 2>&1 || { echo "需要 Python 3.9+。" >&2; exit 1; }

python3 - "$@" <<'PY'
import argparse
import contextlib
import datetime
import ipaddress
import json
import os
import pathlib
import re
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

STATE_NAME = ".nyanpass-isolation-state.json"
LOCK_NAME = ".nyanpass-isolation.lock"
TEST_CONFIG_NAME = "config.isolation-test.yml"
TEST_COMPOSE_NAME = "docker-compose.isolation-test.json"
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def need(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(args, timeout=60, check=True):
    process = subprocess.run(
        [str(value) for value in args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=timeout,
    )
    if check and process.returncode:
        error = re.sub(
            r"(?i)(token|password|key)=([^\s&\"]+)",
            r"\1=[REDACTED]",
            process.stderr,
        )
        raise RuntimeError(
            "命令失败："
            + " ".join(str(value) for value in args[:4])
            + "\n"
            + error[-1600:]
        )
    return process


def atomic(path, data, mode=0o600):
    path = pathlib.Path(path)
    need(not path.is_symlink(), "拒绝覆盖符号链接：" + str(path))
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".isolation-", dir=str(path.parent))
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data.encode() if isinstance(data, str) else data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def write_json(path, value):
    atomic(path, json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def inspect(name):
    return json.loads(run(["docker", "inspect", name]).stdout)[0]


def compose_command(env, compose_file, *extra):
    return [
        "docker",
        "compose",
        "--project-directory",
        str(env["root"]),
        "-p",
        env["project"],
        "-f",
        str(compose_file),
        *extra,
    ]


def resolved_compose(env, source):
    output = run(compose_command(env, source, "config", "--format", "json")).stdout
    return json.loads(output)


def service_containers(service, project=None):
    command = [
        "docker",
        "ps",
        "-aq",
        "--filter",
        "label=com.docker.compose.service=" + service,
    ]
    if project:
        command += ["--filter", "label=com.docker.compose.project=" + project]
    return run(command).stdout.split()


def find_service(root, service, project=None, allow_missing=False):
    matches = []
    for container_id in service_containers(service, project):
        item = inspect(container_id)
        if any(
            mount.get("Type") == "bind"
            and pathlib.Path(mount["Source"]).resolve() == root
            and mount.get("Destination") == "/opt/backend"
            for mount in item.get("Mounts", [])
        ):
            matches.append(item)
    if not matches and allow_missing:
        return None
    need(
        len(matches) == 1,
        "需要且仅支持一个挂载该目录的 " + service + " 服务。",
    )
    return matches[0]


def discover_root(specified=None):
    if specified:
        root = pathlib.Path(specified).expanduser().resolve(strict=True)
        need(root.is_dir(), "指定路径不是目录：" + str(root))
        return root

    candidates = set()
    for fixed in [
        "/opt/nyanpass",
        "/opt/backend",
        "/home/ubuntu/nyanpass",
        "/srv/nyanpass",
    ]:
        path = pathlib.Path(fixed)
        if path.is_dir():
            candidates.add(path.resolve())

    for container_id in run(["docker", "ps", "-aq"], check=False).stdout.split():
        result = run(["docker", "inspect", container_id], check=False)
        if result.returncode:
            continue
        try:
            item = json.loads(result.stdout)[0]
        except (ValueError, IndexError, TypeError):
            continue
        for mount in item.get("Mounts", []):
            if mount.get("Type") != "bind" or mount.get("Destination") != "/opt/backend":
                continue
            source = pathlib.Path(mount.get("Source", ""))
            if source.is_dir():
                candidates.add(source.resolve())

    required = ["rel_backend", "config.yml", "data.db"]
    valid = [
        candidate
        for candidate in sorted(candidates, key=str)
        if all(
            (candidate / name).is_file() and not (candidate / name).is_symlink()
            for name in required
        )
    ]
    need(valid, "无法自动找到面板目录，请使用 --root 指定。")
    need(
        len(valid) == 1,
        "找到多个面板目录，请使用 --root 指定：\n"
        + "\n".join("  - " + str(path) for path in valid),
    )
    return valid[0]


def caddy_config_paths(root, caddy):
    command = caddy.get("Config", {}).get("Cmd") or []
    container_path = None
    for index, value in enumerate(command):
        if value == "--config" and index + 1 < len(command):
            container_path = command[index + 1]
            break
    if not container_path:
        container_path = "/etc/caddy/Caddyfile"

    candidates = []
    for mount in caddy.get("Mounts", []):
        source = pathlib.Path(mount.get("Source", ""))
        destination = (mount.get("Destination") or "").rstrip("/")
        if not source:
            continue
        if destination == container_path and source.is_file():
            candidates.append(source.resolve())
        elif source.is_dir() and container_path.startswith(destination + "/"):
            relative = container_path[len(destination) + 1 :]
            candidate = source / relative
            if candidate.is_file():
                candidates.append(candidate.resolve())

    for candidate in [
        root / "caddy/Caddyfile",
        root / "caddy/Caddyfile.example",
        root / "Caddyfile",
        root / "Caddyfile.example",
    ]:
        if candidate.is_file():
            candidates.append(candidate.resolve())

    unique = []
    for candidate in candidates:
        if candidate not in unique:
            unique.append(candidate)
    need(unique, "无法定位宿主机 Caddy 配置文件。")
    need(
        len(unique) == 1,
        "找到多个 Caddy 配置文件：\n"
        + "\n".join("  - " + str(path) for path in unique),
    )
    return unique[0], container_path


def site_domain(caddy_text, caddy):
    labels = re.findall(r"(?m)^\s*([^#\s][^\s{]*)\s*\{\s*$", caddy_text)
    need(len(labels) == 1, "仅支持单站点 Caddy 配置。")
    label = labels[0].strip()
    variable = re.fullmatch(r"\{\$([A-Za-z_][A-Za-z0-9_]*)(?::([^}]+))?\}", label)
    if variable:
        environment = {}
        for item in caddy.get("Config", {}).get("Env", []):
            if "=" in item:
                name, value = item.split("=", 1)
                environment[name] = value
        label = environment.get(variable.group(1), variable.group(2))
        need(label, "Caddy 环境变量未设置：" + variable.group(1))
    label = re.sub(r"^https?://", "", label.strip(), flags=re.IGNORECASE).rstrip("/")
    need(
        bool(re.fullmatch(r"[A-Za-z0-9.-]+(?::[0-9]{1,5})?", label)),
        "无法识别站点域名：" + label,
    )
    return label.lower()


def environment(args, allow_backend_missing=False):
    need(sys.platform.startswith("linux") and os.geteuid() == 0, "请使用 sudo bash 执行。")
    need(sys.version_info >= (3, 9), "需要 Python 3.9+。")
    run(["docker", "compose", "version"])

    root = discover_root(args.root)
    for name in ["rel_backend", "config.yml", "data.db"]:
        path = root / name
        need(path.is_file() and not path.is_symlink(), "文件缺失或为符号链接：" + str(path))

    caddy = find_service(root, "caddy")
    project = caddy.get("Config", {}).get("Labels", {}).get("com.docker.compose.project")
    need(project, "Caddy 容器缺少 Compose 项目标记。")
    backend = find_service(root, "nya", project, allow_missing=allow_backend_missing)
    need(caddy.get("State", {}).get("Running"), "Caddy 容器未运行。")

    caddyfile, caddy_container_config = caddy_config_paths(root, caddy)
    caddy_text = caddyfile.read_text(encoding="utf-8")
    domain = site_domain(caddy_text, caddy)

    return {
        "root": root,
        "project": project,
        "caddy": caddy["Name"].lstrip("/"),
        "caddyfile": caddyfile,
        "caddy_container_config": caddy_container_config,
        "domain": domain,
        "backend": backend["Name"].lstrip("/") if backend else project + "-nya-1",
        "backend_info": backend,
    }


@contextlib.contextmanager
def exclusive(root):
    import fcntl

    descriptor = os.open(str(root / LOCK_NAME), os.O_CREAT | os.O_RDWR, 0o600)
    with os.fdopen(descriptor, "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError("另一个隔离或恢复操作正在运行。") from error
        yield


def choose_subnet():
    used = []
    network_ids = run(["docker", "network", "ls", "-q"]).stdout.split()
    if network_ids:
        for network in json.loads(run(["docker", "network", "inspect", *network_ids]).stdout):
            for config in network.get("IPAM", {}).get("Config") or []:
                if config.get("Subnet"):
                    used.append(ipaddress.ip_network(config["Subnet"], strict=False))
    routes = run(["ip", "-j", "-4", "route"], check=False)
    if routes.returncode == 0:
        for route in json.loads(routes.stdout):
            if route.get("dst") and route["dst"] != "default":
                used.append(ipaddress.ip_network(route["dst"], strict=False))
    for value in range(240, 255):
        subnet = ipaddress.ip_network(f"172.30.{value}.0/24")
        if all(not subnet.overlaps(other) for other in used if other.version == subnet.version):
            return str(subnet), str(subnet.network_address + 2)
    raise RuntimeError("没有可用的预设隔离子网。")


def http(url, domain=None):
    headers = {"User-Agent": "nyanpass-isolation-test/1.0"}
    if domain:
        headers["Host"] = domain
    request = urllib.request.Request(url, headers=headers)
    try:
        with OPENER.open(request, timeout=5) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


def wait_backend(url, domain, require_business=False):
    deadline = time.monotonic() + 45
    last_error = None
    while time.monotonic() < deadline:
        try:
            status, body = http(url + "/api/v1/guest/kv/site_info", domain)
            if not require_business:
                return status
            if status == 200 and json.loads(body).get("code") == 0:
                return status
        except (OSError, ValueError) as error:
            last_error = error
        time.sleep(0.5)
    suffix = "" if last_error is None else "：" + str(last_error)
    raise RuntimeError("后台在 45 秒内未就绪" + suffix)


def caddy_validate(env, candidate):
    candidate = pathlib.Path(candidate).resolve()
    relative = candidate.relative_to(env["root"])
    run([
        "docker",
        "exec",
        env["caddy"],
        "caddy",
        "validate",
        "--config",
        "/opt/backend/" + relative.as_posix(),
        "--adapter",
        "caddyfile",
    ])


def caddy_reload(env):
    run([
        "docker",
        "exec",
        env["caddy"],
        "caddy",
        "reload",
        "--config",
        env["caddy_container_config"],
        "--adapter",
        "caddyfile",
    ])


def state_path(root):
    return root / STATE_NAME


def load_state(root, required=True):
    path = state_path(root)
    if not path.is_file():
        if required:
            raise RuntimeError("没有隔离测试状态，无法恢复。")
        return None
    value = json.loads(path.read_text(encoding="utf-8"))
    backup = pathlib.Path(value.get("backup", "")).resolve(strict=True)
    need(backup.is_relative_to(root), "状态中的备份目录不合法。")
    for name in ["config.yml", "Caddyfile", "compose.normal.json"]:
        need((backup / name).is_file(), "备份缺少：" + name)
    return value


def save_state(root, value, phase):
    value["phase"] = phase
    write_json(state_path(root), value)
    write_json(pathlib.Path(value["backup"]) / "state.json", value)


def database_snapshot(source, target):
    source_db = sqlite3.connect("file:" + str(source) + "?mode=ro", uri=True)
    target_db = sqlite3.connect(str(target))
    try:
        source_db.backup(target_db)
    finally:
        target_db.close()
        source_db.close()
    os.chmod(target, 0o600)


def restore(env, state, quiet=False):
    root = env["root"]
    backup = pathlib.Path(state["backup"])
    normal_compose = backup / "compose.normal.json"
    save_state(root, state, "restoring")

    atomic(root / "config.yml", (backup / "config.yml").read_bytes())
    atomic(env["caddyfile"], (backup / "Caddyfile").read_bytes(), 0o644)

    start_error = None
    try:
        run(
            compose_command(
                env,
                normal_compose,
                "up",
                "-d",
                "--no-deps",
                "--force-recreate",
                "nya",
            ),
            timeout=120,
        )
    except Exception as error:
        start_error = error

    try:
        caddy_reload(env)
    except Exception as error:
        if start_error is None:
            start_error = error

    if start_error:
        save_state(root, state, "recovery_required")
        raise start_error

    wait_backend("http://127.0.0.1:18888", env["domain"])
    restored = find_service(root, "nya", env["project"])
    need(restored["State"]["Running"], "恢复后的后台没有运行。")
    need(restored["HostConfig"]["NetworkMode"] == "host", "后台没有恢复到 host 网络。")

    network_name = state.get("network")
    if network_name:
        result = run(["docker", "network", "inspect", network_name], check=False)
        if result.returncode == 0:
            network = json.loads(result.stdout)[0]
            if network.get("Internal") and not network.get("Containers"):
                run(["docker", "network", "rm", network_name])

    for generated in [root / TEST_CONFIG_NAME, root / TEST_COMPOSE_NAME]:
        if generated.exists() and not generated.is_symlink():
            generated.unlink()

    save_state(root, state, "restored")
    if not quiet:
        print("恢复完成：后台已回到 host 网络，Caddy 和 config.yml 已恢复。")
        print("数据库没有回滚；测试前快照位于：" + str(backup / "data-before.db"))


def verify_active(env, state):
    backend = find_service(env["root"], "nya", env["project"])
    need(backend["State"]["Running"], "隔离后台未运行。")
    networks = backend.get("NetworkSettings", {}).get("Networks", {})
    need(len(networks) == 1, "隔离后台必须仅连接一个网络。")
    network_name = next(iter(networks))
    need(network_name == state["network"], "后台连接的网络与状态记录不一致。")
    network = json.loads(run(["docker", "network", "inspect", network_name]).stdout)[0]
    need(network.get("Internal"), "测试网络不是 internal 网络。")
    need(not backend.get("HostConfig", {}).get("PortBindings"), "后台不应发布宿主机端口。")

    backend_ip = networks[network_name]["IPAddress"]
    need(backend_ip, "无法获得后台隔离 IP。")
    need(
        backend_ip + ":18888" in env["caddyfile"].read_text(encoding="utf-8"),
        "Caddy 没有指向隔离后台。",
    )
    wait_backend("http://" + backend_ip + ":18888", env["domain"], require_business=True)

    probe = run(
        [
            "docker",
            "exec",
            backend["Name"].lstrip("/"),
            "sh",
            "-c",
            "timeout 5 wget -q -O /dev/null http://1.1.1.1",
        ],
        check=False,
        timeout=10,
    )
    need(probe.returncode != 0, "外网探测成功，隔离无效。")

    public_status, public_body = http(
        "https://" + env["domain"] + "/api/v1/guest/kv/site_info"
    )
    need(public_status == 200, "公网访客接口异常：HTTP " + str(public_status))
    need(json.loads(public_body).get("code") == 0, "公网访客接口业务返回异常。")

    result = {
        "domain": env["domain"],
        "backend": backend["Name"].lstrip("/"),
        "backend_ip": backend_ip,
        "network": network_name,
        "network_internal": True,
        "outbound_blocked": True,
        "public_guest_api": 200,
        "checked_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }
    write_json(pathlib.Path(state["backup"]) / "results.json", result)
    return result


def start(env):
    root = env["root"]
    existing_state = load_state(root, required=False)
    if existing_state and existing_state.get("phase") not in {"restored"}:
        raise RuntimeError("发现未恢复的隔离状态，请先执行 restore。")

    backend = env["backend_info"]
    need(backend and backend["State"]["Running"], "后台容器未运行。")
    need(backend["HostConfig"]["NetworkMode"] == "host", "后台当前不是 host 网络。")

    labels = backend.get("Config", {}).get("Labels", {})
    sources = [value for value in labels.get("com.docker.compose.project.config_files", "").split(",") if value]
    need(len(sources) == 1 and pathlib.Path(sources[0]).is_file(), "需要一个可读取的原 Compose 文件。")

    normal = resolved_compose(env, sources[0])
    service = normal.get("services", {}).get("nya")
    need(service, "Compose 中缺少 nya 服务。")
    need(service.get("network_mode") == "host", "原 nya 服务不是 host 网络。")
    need(not service.get("ports"), "原 nya 服务存在端口发布，拒绝自动改写。")

    config_text = (root / "config.yml").read_text(encoding="utf-8")
    test_config, count = re.subn(
        r"(?m)^listen:\s*127\.0\.0\.1:18888\s*$",
        "listen: 0.0.0.0:18888",
        config_text,
    )
    need(count == 1, "config.yml 必须包含 listen: 127.0.0.1:18888。")

    caddy_text = env["caddyfile"].read_text(encoding="utf-8")
    need(caddy_text.count("127.0.0.1:18888") == 1, "Caddy 上游必须恰好包含一个 127.0.0.1:18888。")

    subnet, backend_ip = choose_subnet()
    network_name = env["project"] + "_outbound_isolation_test"
    need(
        run(["docker", "network", "inspect", network_name], check=False).returncode != 0,
        "测试网络已存在，请先执行 restore 或手动检查。",
    )

    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup = root / "isolation-backups" / stamp
    backup.mkdir(parents=True, mode=0o700)
    os.chmod(backup.parent, 0o700)
    os.chmod(backup, 0o700)

    atomic(backup / "config.yml", (root / "config.yml").read_bytes())
    atomic(backup / "Caddyfile", env["caddyfile"].read_bytes(), 0o600)
    write_json(backup / "compose.normal.json", normal)
    database_snapshot(root / "data.db", backup / "data-before.db")

    test = json.loads(json.dumps(normal))
    test_service = test["services"]["nya"]
    test_service.pop("network_mode", None)
    test_service.pop("ports", None)
    test_service["networks"] = {"outbound_isolation": {"ipv4_address": backend_ip}}
    test_service["command"] = ["./rel_backend", "-c", TEST_CONFIG_NAME]
    test_service["restart"] = "unless-stopped"
    test.setdefault("networks", {})["outbound_isolation"] = {
        "internal": True,
        "name": network_name,
        "ipam": {"config": [{"subnet": subnet}]},
    }

    test_compose = root / TEST_COMPOSE_NAME
    test_config_path = root / TEST_CONFIG_NAME
    candidate_caddy = backup / "Caddyfile.test"
    atomic(test_config_path, test_config)
    write_json(test_compose, test)
    atomic(candidate_caddy, caddy_text.replace("127.0.0.1:18888", backend_ip + ":18888"), 0o600)

    run(compose_command(env, test_compose, "config", "-q"))
    caddy_validate(env, candidate_caddy)

    state = {
        "version": 1,
        "root": str(root),
        "project": env["project"],
        "domain": env["domain"],
        "backup": str(backup),
        "network": network_name,
        "backend_ip": backend_ip,
        "caddyfile": str(env["caddyfile"]),
        "caddy_container_config": env["caddy_container_config"],
        "created_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }
    save_state(root, state, "prepared")

    print("备份完成：" + str(backup), flush=True)
    print("正在切换到无外网隔离网络……", flush=True)
    try:
        run(
            compose_command(
                env,
                test_compose,
                "up",
                "-d",
                "--no-deps",
                "--force-recreate",
                "nya",
            ),
            timeout=120,
        )
        wait_backend("http://" + backend_ip + ":18888", env["domain"], require_business=True)
        atomic(env["caddyfile"], candidate_caddy.read_bytes(), 0o644)
        caddy_reload(env)
        result = verify_active(env, state)
        save_state(root, state, "active")
    except Exception as error:
        print("隔离测试失败，正在自动恢复：" + str(error), file=sys.stderr, flush=True)
        try:
            restore(env, state, quiet=True)
            print("自动恢复完成。", file=sys.stderr, flush=True)
        except Exception as restore_error:
            save_state(root, state, "recovery_required")
            print("自动恢复失败，请立即执行 restore：" + str(restore_error), file=sys.stderr)
        raise

    print("隔离测试已启用。")
    print("网站：https://" + env["domain"])
    print("后台外网出站：已阻断")
    print("报告：" + str(pathlib.Path(state["backup"]) / "results.json"))
    print("恢复命令：sudo bash 此脚本 restore --root " + str(root))
    return result


def arguments():
    parser = argparse.ArgumentParser(description="Nyanpass 容器外网隔离测试；不修改 rel_backend。")
    parser.add_argument("action", choices=["check", "start", "status", "restore"])
    parser.add_argument("--root", help="面板目录；默认从 Docker 挂载自动识别")
    return parser.parse_args()


def main():
    args = arguments()
    allow_missing = args.action == "restore"
    env = environment(args, allow_backend_missing=allow_missing)
    print("面板目录：" + str(env["root"]))
    print("Caddy 配置：" + str(env["caddyfile"]))
    print("站点域名：" + env["domain"])

    with exclusive(env["root"]):
        if args.action == "check":
            state = load_state(env["root"], required=False)
            if state and state.get("phase") not in {"restored"}:
                print("检查通过，但存在隔离状态：" + state.get("phase", "unknown"))
            else:
                backend = env["backend_info"]
                need(backend and backend["State"]["Running"], "后台容器未运行。")
                print("检查通过；未修改服务器。")
        elif args.action == "start":
            start(env)
        elif args.action == "status":
            state = load_state(env["root"])
            print("当前阶段：" + state.get("phase", "unknown"))
            if state.get("phase") == "active":
                result = verify_active(env, state)
                print(json.dumps(result, ensure_ascii=False, indent=2))
        elif args.action == "restore":
            state = load_state(env["root"])
            restore(env, state)


if __name__ == "__main__":
    try:
        main()
    except (Exception, KeyboardInterrupt) as error:
        print("操作未完成：" + str(error), file=sys.stderr)
        sys.exit(1)
PY
