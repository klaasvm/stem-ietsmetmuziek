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


def log(message):
    stamp = time.strftime("%H:%M:%S")
    print("[{}] {}".format(stamp, message))


def sanitize_file_name(value):
    safe = re.sub(r"[^A-Za-z0-9._-]", "_", value or "")
    return safe or "upload.mid"


def sanitize_file_id(value):
    return "".join(ch for ch in (value or "") if ch.isdigit())


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
    with request.urlopen(url, timeout=timeout) as response:
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


def looks_like_esp32(ip):
    raw = fetch_raw_from_esp32_endpoints(ip)
    if raw is None:
        return False
    return has_expected_confirm_token(ip)


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


def collect_subnet_prefixes():
    prefixes = []
    seen = set()

    def add_prefix(prefix):
        if not prefix.startswith("192.168."):
            return
        if prefix in seen:
            return
        seen.add(prefix)
        prefixes.append(prefix)

    try:
        hostname = socket.gethostname()
        addrs = socket.gethostbyname_ex(hostname)[2]
        for ip in addrs:
            if not is_private_ipv4(ip):
                continue
            parts = ip.split(".")
            add_prefix("{}.{}.{}".format(parts[0], parts[1], parts[2]))
    except Exception:
        pass

    for prefix in ("192.168.0", "192.168.1", "192.168.2", "192.168.178"):
        add_prefix(prefix)

    return prefixes


def discover_esp32_ip():
    host_ip = discover_esp32_via_hostnames()
    if host_ip:
        return host_ip

    candidates = []
    for prefix in collect_subnet_prefixes():
        for host in range(2, 255):
            candidates.append("{}.{}".format(prefix, host))

    with ThreadPoolExecutor(max_workers=24) as pool:
        futures = {pool.submit(looks_like_esp32, ip): ip for ip in candidates}
        for future in as_completed(futures):
            try:
                if future.result():
                    return futures[future]
            except Exception:
                pass

    return None


def list_uploaded_files(ip):
    with request.urlopen("http://{}/list".format(ip), timeout=8) as response:
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

    with request.urlopen(url, timeout=15) as response:
        if response.status != 200:
            raise RuntimeError("Download failed with status {}".format(response.status))
        return response.read()


def delete_uploaded_file(ip, file_name, file_id):
    query = parse.urlencode({"name": file_name, "id": file_id})
    url = "http://{}/delete?{}".format(ip, query)

    with request.urlopen(url, timeout=8) as response:
        body = response.read().decode("utf-8", "ignore")
        if response.status != 200:
            raise RuntimeError("Delete failed with status {}: {}".format(response.status, body))
        return body.strip()


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


def main():
    args = parse_args()
    ensure_output_dir(args.out)

    ip = connect_esp32(preferred_ip=args.ip, retry_delay=args.reconnect_seconds)

    while True:
        try:
            processed = process_remote_files(ip, args.out)
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
