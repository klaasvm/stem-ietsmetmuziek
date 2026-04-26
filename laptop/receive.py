import argparse
import json
import os
import re
import socket
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from urllib import error, parse, request

DISCOVERY_TIMEOUT = 0.8
TIME_PATTERN = re.compile(r"^\d{2}:\d{2}:\d{2}$")
MIDI_EXTENSIONS = (".mid", ".midi")
CLIENT_TYPE = "computer"
CLIENT_ID = "pc-{}".format(socket.gethostname())


def log(message):
    stamp = time.strftime("%H:%M:%S")
    print("[{}] {}".format(stamp, message))


def sanitize_file_name(value):
    safe = re.sub(r"[^A-Za-z0-9._-]", "_", value or "")
    return safe or "upload.mid"


def sanitize_file_id(value):
    return "".join(ch for ch in (value or "") if ch.isdigit())


def create_upload_file_id():
    # Digits-only ID required by ESP32 side sanitization.
    return str(int(time.time() * 1000))


def is_private_ipv4(ip):
    parts = ip.split(".")
    if len(parts) != 4:
        return False

    try:
        a = int(parts[0])
        b = int(parts[1])
    except ValueError:
        return False

    if a == 10:
        return True
    if a == 172 and 16 <= b <= 31:
        return True
    if a == 192 and b == 168:
        return True
    return False


def get_url_text(url, timeout=DISCOVERY_TIMEOUT):
    req = request.Request(url)
    req.add_header("X-Client-Type", CLIENT_TYPE)
    req.add_header("X-Client-Id", CLIENT_ID)
    with request.urlopen(req, timeout=timeout) as response:
        body = response.read().decode("utf-8", "ignore")
        return response.status, body


def has_expected_confirm_token(ip):
    try:
        status, body = get_url_text("http://{}/confirm".format(ip), timeout=1.1)
        if status != 200:
            return False
        return "ietsmetmuziek" in body.lower()
    except Exception:
        return False


def fetch_raw_from_esp32_endpoints(ip):
    for endpoint in ("/raw", "/"):
        try:
            status, body = get_url_text("http://{}{}".format(ip, endpoint), timeout=DISCOVERY_TIMEOUT)
            if status == 200 and body.strip():
                return body
        except Exception:
            pass
    return None


def raw_body_looks_like_esp32(raw):
    trimmed = raw.strip()
    if not trimmed:
        return False
    if TIME_PATTERN.match(trimmed):
        return True
    lowered = trimmed.lower()
    return "esp32" in lowered or "<html" in lowered


def looks_like_esp32(ip):
    raw = fetch_raw_from_esp32_endpoints(ip)
    if raw is None:
        return False
    if not has_expected_confirm_token(ip):
        return False
    return raw_body_looks_like_esp32(raw)


def discover_esp32_via_hostnames():
    for host in ("esp32.local", "esp32"):
        try:
            for family, _, _, _, sockaddr in socket.getaddrinfo(host, None):
                if family != socket.AF_INET:
                    continue
                ip = sockaddr[0]
                if not is_private_ipv4(ip):
                    continue
                if looks_like_esp32(ip):
                    return ip
        except Exception:
            pass
    return None


def collect_local_ipv4_addresses():
    addresses = set()

    try:
        hostname = socket.gethostname()
        for ip in socket.gethostbyname_ex(hostname)[2]:
            if is_private_ipv4(ip):
                addresses.add(ip)
    except Exception:
        pass

    # UDP connect bepaalt lokaal source-IP zonder echt netwerkverkeer te vereisen.
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            probe.connect(("8.8.8.8", 80))
            ip = probe.getsockname()[0]
            if is_private_ipv4(ip):
                addresses.add(ip)
    except Exception:
        pass

    return sorted(addresses)


def collect_subnet_prefixes():
    prefixes = {}

    for ip in collect_local_ipv4_addresses():
        parts = ip.split(".")
        if len(parts) != 4:
            continue
        try:
            own_host = int(parts[3])
        except ValueError:
            continue
        prefix = "{}.{}.{}".format(parts[0], parts[1], parts[2])
        prefixes[prefix] = own_host

    for prefix in ("192.168.0", "192.168.1", "192.168.2", "192.168.178"):
        prefixes.setdefault(prefix, -1)

    return prefixes


def discover_esp32_ip():
    host_ip = discover_esp32_via_hostnames()
    if host_ip:
        return host_ip

    candidates = []
    for prefix, own_host in collect_subnet_prefixes().items():
        for host in range(2, 255):
            if host == own_host:
                continue
            candidates.append("{}.{}".format(prefix, host))

    with ThreadPoolExecutor(max_workers=24) as pool:
        batch_size = 24
        for start in range(0, len(candidates), batch_size):
            batch = candidates[start : start + batch_size]
            futures = {pool.submit(looks_like_esp32, ip): ip for ip in batch}
            for future in as_completed(futures):
                try:
                    if future.result():
                        return futures[future]
                except Exception:
                    pass

    return None


def list_uploaded_files(ip):
    req = request.Request("http://{}/list".format(ip))
    req.add_header("X-Client-Type", CLIENT_TYPE)
    req.add_header("X-Client-Id", CLIENT_ID)
    with request.urlopen(req, timeout=8) as response:
        body = response.read().decode("utf-8", "ignore")
        if response.status != 200:
            raise RuntimeError("List failed: {} {}".format(response.status, body))
        payload = json.loads(body)
        files = payload.get("files", [])
        if isinstance(files, list):
            return files
        return []


def download_uploaded_file_bytes(ip, file_name, file_id):
    query = parse.urlencode({"name": file_name, "id": file_id})
    url = "http://{}/download?{}".format(ip, query)

    req = request.Request(url)
    req.add_header("X-Client-Type", CLIENT_TYPE)
    req.add_header("X-Client-Id", CLIENT_ID)
    with request.urlopen(req, timeout=15) as response:
        if response.status != 200:
            raise RuntimeError("Download failed with status {}".format(response.status))
        return response.read()


def delete_uploaded_file(ip, file_name, file_id):
    query = parse.urlencode({"name": file_name, "id": file_id})
    url = "http://{}/delete?{}".format(ip, query)

    req = request.Request(url)
    req.add_header("X-Client-Type", CLIENT_TYPE)
    req.add_header("X-Client-Id", CLIENT_ID)
    with request.urlopen(req, timeout=8) as response:
        body = response.read().decode("utf-8", "ignore")
        if response.status != 200:
            raise RuntimeError("Delete failed with status {}: {}".format(response.status, body))
        return body.strip()


def upload_file_bytes(ip, file_name, file_id, data):
    query = parse.urlencode({"name": file_name, "id": file_id})
    url = "http://{}/upload?{}".format(ip, query)

    req = request.Request(url, data=data, method="POST")
    req.add_header("Content-Type", "application/octet-stream")
    req.add_header("Content-Length", str(len(data)))
    req.add_header("X-Client-Type", CLIENT_TYPE)
    req.add_header("X-Client-Id", CLIENT_ID)

    with request.urlopen(req, timeout=15) as response:
        body = response.read().decode("utf-8", "ignore")
        if response.status != 200:
            raise RuntimeError("Upload failed with status {}: {}".format(response.status, body))
        return body.strip()


def upload_file_to_esp32(ip, local_path):
    path_str = os.fspath(local_path)
    file_name = sanitize_file_name(os.path.basename(path_str))
    file_id = create_upload_file_id()

    with open(path_str, "rb") as f:
        data = f.read()

    return upload_file_bytes(ip, file_name, file_id, data)


def ensure_output_dir(path):
    if not os.path.isdir(path):
        os.makedirs(path)


def unique_path(path):
    if not os.path.exists(path):
        return path

    root, ext = os.path.splitext(path)
    counter = 1
    while True:
        candidate = "{}_{}{}".format(root, counter, ext)
        if not os.path.exists(candidate):
            return candidate
        counter += 1


def connect_esp32(preferred_ip=None, retry_delay=2.0):
    while True:
        if preferred_ip:
            log("Controleer opgegeven ESP32 IP: {}".format(preferred_ip))
            if has_expected_confirm_token(preferred_ip):
                log("Verbonden met ESP32 op {} (confirm ok)".format(preferred_ip))
                return preferred_ip
            log("Confirm faalde op {}".format(preferred_ip))

        log("Zoek ESP32 op 192.168.x.x ...")
        found = discover_esp32_ip()
        if found and has_expected_confirm_token(found):
            log("Verbonden met ESP32 op {} (confirm ok)".format(found))
            return found

        log("Geen ESP32 gevonden, opnieuw over {:.1f}s".format(retry_delay))
        time.sleep(retry_delay)


def process_remote_files(ip, output_dir):
    files = list_uploaded_files(ip)
    if not files:
        return 0

    downloaded_count = 0
    for item in files:
        raw_name = item.get("name", "")
        raw_id = item.get("id", "")

        file_name = sanitize_file_name(raw_name)
        file_id = sanitize_file_id(raw_id)
        if not file_name or not file_id:
            continue

        if not file_name.lower().endswith(MIDI_EXTENSIONS):
            continue

        log("Nieuwe upload gevonden: id={} name={}".format(file_id, file_name))
        data = download_uploaded_file_bytes(ip, file_name, file_id)

        local_name = "{}_{}".format(file_id, file_name)
        local_path = unique_path(os.path.join(output_dir, local_name))
        with open(local_path, "wb") as f:
            f.write(data)

        log("Gedownload: {} ({} bytes)".format(local_path, len(data)))
        delete_msg = delete_uploaded_file(ip, file_name, file_id)
        log("Verwijderd op ESP32: {}".format(delete_msg or "ok"))
        downloaded_count += 1

    return downloaded_count


def parse_args():
    parser = argparse.ArgumentParser(
        description="ESP32 upload-watcher: bevestigt /confirm, downloadt uploads automatisch en verwijdert ze op ESP32.",
    )
    parser.add_argument("--ip", help="Optioneel vast ESP32 IP")
    parser.add_argument(
        "--out",
        default="downloads",
        help="Map voor automatisch gedownloade bestanden (default: downloads)",
    )
    parser.add_argument(
        "--poll-seconds",
        type=float,
        default=1.2,
        help="Polling interval in seconden (default: 1.2)",
    )
    parser.add_argument(
        "--reconnect-seconds",
        type=float,
        default=2.0,
        help="Reconnect interval in seconden (default: 2.0)",
    )
    return parser.parse_args()


def resolve_output_dir(output_arg):
    script_dir = os.path.dirname(os.path.abspath(__file__))
    if os.path.isabs(output_arg):
        return output_arg
    return os.path.join(script_dir, output_arg)


def main():
    args = parse_args()
    output_dir = resolve_output_dir(args.out)
    ensure_output_dir(output_dir)
    log("Download map: {}".format(output_dir))

    ip = connect_esp32(preferred_ip=args.ip, retry_delay=args.reconnect_seconds)

    while True:
        try:
            processed = process_remote_files(ip, output_dir)
            if processed == 0:
                time.sleep(args.poll_seconds)
        except KeyboardInterrupt:
            log("Gestopt door gebruiker.")
            return 0
        except Exception as exc:
            log("Fout tijdens sync: {}".format(exc))
            log("Herstel connectie...")
            ip = connect_esp32(preferred_ip=ip, retry_delay=args.reconnect_seconds)


if __name__ == "__main__":
    sys.exit(main())