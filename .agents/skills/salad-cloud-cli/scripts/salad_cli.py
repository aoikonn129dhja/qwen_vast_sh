"""Repository-local SaladCloud client; standard library only."""
import argparse
import json
import re
import sys
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[4]


class ApiError(Exception):
    def __init__(self, status):
        self.status = status
        super().__init__(f"Salad API returned HTTP {status}.")


def read_env(path):
    result = {}
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, sep, value = line.partition("=")
        if not sep:
            raise ValueError("Invalid environment file line.")
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        result[key.strip()] = value
    return result


def name(value):
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,61}[a-z0-9]", value):
        raise ValueError("Invalid resource name.")
    return value


class Client:
    def __init__(self, env):
        self.key = env.get("SALAD_API_KEY", "")
        if not self.key or any(ord(c) < 33 or ord(c) > 126 for c in self.key):
            raise ValueError("Set a valid SALAD_API_KEY in the local .env file.")
        org = name(env.get("SALAD_ORGANIZATION", ""))
        project = name(env.get("SALAD_PROJECT", ""))
        self.org_url = f"https://api.salad.com/api/public/organizations/{org}"
        self.groups_url = f"{self.org_url}/projects/{project}/containers"

    def request(self, method, url):
        request = Request(url, method=method, headers={
            "Salad-Api-Key": self.key, "Accept": "application/json",
            "User-Agent": "vast-image-salad-cli/1.0",
            "Content-Type": "application/json",
        })
        try:
            with urlopen(request, timeout=60) as response:
                raw = response.read()
                return json.loads(raw) if raw else None
        except HTTPError as error:
            raise ApiError(error.code) from None
        except (URLError, TimeoutError, OSError):
            raise RuntimeError("API connection failed; outcome may be unknown. Read status before retrying.") from None

    def get(self, group):
        return self.request("GET", f"{self.groups_url}/{name(group)}")


def summary(group):
    container = group.get("container", {})
    network = group.get("networking") or {}
    return {key: value for key, value in {
        "name": group.get("name"), "current_state": group.get("current_state"),
        "pending_change": group.get("pending_change"),
        "autostart_policy": group.get("autostart_policy"),
        "replicas": group.get("replicas"), "priority": group.get("priority"),
        "image": container.get("image"), "resources": container.get("resources"),
        "networking": {k: network[k] for k in (
            "auth", "port", "protocol", "dns", "load_balancer",
            "client_request_timeout", "server_response_timeout", "single_connection_limit"
        ) if k in network},
    }.items()}


def operate(client, action, group, allow_paid=False):
    if action == "start" and not allow_paid:
        raise ValueError("Start requires user authorization and --allow-paid.")
    current = client.get(group)
    status = current.get("current_state", {}).get("status")
    if action == "start" and status != "stopped":
        return summary(current)
    if action == "stop" and status == "stopped":
        return summary(current)
    client.request("POST", f"{client.groups_url}/{name(group)}/{action}")
    return summary(client.get(group))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["status", "list", "gpus", "start", "stop"])
    parser.add_argument("group", nargs="?")
    parser.add_argument("--allow-paid", action="store_true")
    args = parser.parse_args()
    if args.action not in ("list", "gpus") and not args.group:
        parser.error("group is required")
    client = Client(read_env(ROOT / ".env"))
    if args.action == "status":
        output = summary(client.get(args.group))
    elif args.action == "list":
        output = [summary(g) for g in client.request("GET", client.groups_url)["items"]]
    elif args.action == "gpus":
        output = client.request("GET", f"{client.org_url}/gpu-classes")
    else:
        output = operate(client, args.action, args.group, args.allow_paid)
    print(json.dumps(output, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, RuntimeError, ApiError, json.JSONDecodeError) as error:
        # Never include request headers, raw response bodies or environment values.
        if isinstance(error, (ApiError, RuntimeError, ValueError)):
            print(str(error), file=sys.stderr)
        else:
            print("Configuration or response could not be read. Check local files and API schema.", file=sys.stderr)
        sys.exit(1)
