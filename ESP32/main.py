import socket
import network
import gc
import time

import music_player

try:
    import ujson as json
except:
    import json

UPLOAD_DIR = "uploads"
CLIENT_TIMEOUT_SECONDS = 8
CLIENT_PRUNE_INTERVAL_SECONDS = 2
ALLOWED_CLIENT_TYPES = ("mobile", "computer")
CLIENT_SLOTS = {
    "mobile": {"id": None, "last_seen": 0},
    "computer": {"id": None, "last_seen": 0},
}
_CLIENT_PRUNER_STARTED = False

def log(message):
    try:
        now = time.localtime()
        stamp = "{:02d}:{:02d}:{:02d}".format(now[3], now[4], now[5])
    except:
        stamp = "--:--:--"
    print("[{}] {}".format(stamp, message))

def get_ip():
    wlan = network.WLAN(network.STA_IF)
    return wlan.ifconfig()[0] if wlan.isconnected() else "0.0.0.0"

def get_confirm_text():
    return "stem-ietsmetmuziek"

def get_status_text():
    return "esp32-ready"

def should_log_request(path):
    # /list and /confirm are polled frequently; skip noisy per-request logs.
    return path != "/list" and path != "/confirm"


def _release_expired_slots():
    now = time.time()
    for slot_type in ALLOWED_CLIENT_TYPES:
        slot = CLIENT_SLOTS[slot_type]
        if slot["id"] is None:
            continue
        if now - slot["last_seen"] > CLIENT_TIMEOUT_SECONDS:
            log("Client slot vrijgegeven (timeout): {} {}".format(slot_type, slot["id"]))
            slot["id"] = None
            slot["last_seen"] = 0


def _slot_pruner_loop():
    while True:
        try:
            _release_expired_slots()
        except Exception as exc:
            log("Slot pruner fout: {}".format(exc))
        time.sleep(CLIENT_PRUNE_INTERVAL_SECONDS)


def _start_slot_pruner():
    global _CLIENT_PRUNER_STARTED
    if _CLIENT_PRUNER_STARTED:
        return

    try:
        import _thread
        _thread.start_new_thread(_slot_pruner_loop, ())
        _CLIENT_PRUNER_STARTED = True
        log("Client slot pruner gestart")
    except Exception as exc:
        log("Client slot pruner niet gestart: {}".format(exc))


def _register_client(headers, client_addr):
    _release_expired_slots()

    client_type = (headers.get("x-client-type", "") or "").strip().lower()
    client_id = (headers.get("x-client-id", "") or "").strip()
    if not client_id:
        client_id = client_addr[0]

    if client_type not in ALLOWED_CLIENT_TYPES:
        return True, ""

    slot = CLIENT_SLOTS[client_type]
    now = time.time()

    if slot["id"] is None:
        slot["id"] = client_id
        slot["last_seen"] = now
        log("Client slot geclaimd: {} {}".format(client_type, client_id))
        return True, ""

    if slot["id"] == client_id:
        slot["last_seen"] = now
        return True, ""

    return (
        False,
        "{} slot al in gebruik door {}".format(client_type, slot["id"]),
    )

def send_response(conn, body, content_type="text/plain; charset=utf-8", status_code=200, status_text="OK"):
    if isinstance(body, str):
        body_bytes = body.encode()
    else:
        body_bytes = body

    header = (
        f"HTTP/1.1 {status_code} {status_text}\r\n"
        f"Content-Type: {content_type}\r\n"
        f"Content-Length: {len(body_bytes)}\r\n"
        "Connection: close\r\n\r\n"
    )
    conn.sendall(header.encode() + body_bytes)

def send_error(conn, status_code, status_text, message):
    send_response(conn, message, status_code=status_code, status_text=status_text)

def get_request_path(request_text):
    first_line_end = request_text.find("\r\n")
    if first_line_end == -1:
        first_line = request_text
    else:
        first_line = request_text[:first_line_end]

    parts = first_line.split(" ")
    if len(parts) < 2:
        return "/"
    return parts[1]

def start_server(port=80):
    _start_slot_pruner()

    try:
        import os
        os.mkdir(UPLOAD_DIR)
    except:
        pass

    addr = socket.getaddrinfo("0.0.0.0", port)[0][-1]
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(addr)
    s.listen(3)
    log("Server op http://{}:{}".format(get_ip(), port))

    while True:
        conn = None
        try:
            conn, client_addr = s.accept()
            request_head = b""

            while b"\r\n\r\n" not in request_head and len(request_head) < 4096:
                chunk = conn.recv(512)
                if not chunk:
                    break
                request_head += chunk

            if not request_head:
                continue

            header_end = request_head.find(b"\r\n\r\n")
            if header_end == -1:
                send_error(conn, 400, "Bad Request", "Invalid request")
                continue

            head_text = request_head[:header_end].decode("utf-8", "ignore")
            body = request_head[header_end + 4:]

            lines = head_text.split("\r\n")
            if not lines:
                send_error(conn, 400, "Bad Request", "Missing request line")
                continue

            request_line_parts = lines[0].split(" ")
            if len(request_line_parts) < 2:
                send_error(conn, 400, "Bad Request", "Invalid request line")
                continue

            method = request_line_parts[0]
            path_with_query = request_line_parts[1]
            if path_with_query.startswith("/upload&"):
                path_with_query = "/upload?" + path_with_query[len("/upload&"):]
            if path_with_query.startswith("/download&"):
                path_with_query = "/download?" + path_with_query[len("/download&"):]
            if path_with_query.startswith("/delete&"):
                path_with_query = "/delete?" + path_with_query[len("/delete&"):]
            if "?" in path_with_query:
                path, query = path_with_query.split("?", 1)
            else:
                path, query = path_with_query, ""

            if should_log_request(path):
                log("Client verbonden: {}".format(client_addr))
                log("Request: {} {}".format(method, path))

            headers = {}
            for line in lines[1:]:
                sep = line.find(":")
                if sep != -1:
                    key = line[:sep].strip().lower()
                    value = line[sep + 1:].strip()
                    headers[key] = value

            allowed, reason = _register_client(headers, client_addr)
            if not allowed:
                send_error(conn, 409, "Conflict", "Client geweigerd: {}".format(reason))
                continue

            if path == "/confirm" and method == "GET":
                send_response(conn, get_confirm_text())
                continue

            params = {}
            if query:
                for pair in query.split("&"):
                    if not pair:
                        continue
                    if "=" in pair:
                        k, v = pair.split("=", 1)
                    else:
                        k, v = pair, ""
                    params[k] = v.replace("%20", " ")

            if path == "/playback_ready" and method == "GET":
                state = music_player.playback_state()
                payload = json.dumps(
                    {
                        "ready": state.get("pending", False),
                        "playing": state.get("playing", False),
                        "current": state.get("current"),
                    }
                )
                send_response(conn, payload, content_type="application/json; charset=utf-8")
                continue

            if path == "/play_sync" and method == "GET":
                delay_value = params.get("delay_ms", "0")
                try:
                    delay_ms = int(delay_value)
                except ValueError:
                    send_error(conn, 400, "Bad Request", "delay_ms moet een geheel getal zijn")
                    continue

                if delay_ms < 0:
                    delay_ms = 0
                if delay_ms > 10000:
                    delay_ms = 10000

                try:
                    music_player.start_playback_async(delay_ms=delay_ms)
                    send_response(
                        conn,
                        json.dumps({"scheduled": True, "delay_ms": delay_ms}),
                        content_type="application/json; charset=utf-8",
                    )
                except Exception as exc:
                    send_error(conn, 409, "Conflict", "Kon playback niet starten: {}".format(exc))
                continue
            if path == "/stop_playback" and method == "GET":
                music_player.interupt_playback()
                try:
                    send_response(
                        conn,
                        json.dumps({"stopped": True}),
                        content_type="application/json; charset=utf-8",
                    )
                except Exception as exc:
                    log("Fout bij stoppen response: {}".format(exc))
                continue

            name = params.get("name", "")
            file_id = params.get("id", "")

            safe_name = ""
            for ch in name:
                code = ord(ch)
                is_alpha_num = (
                    (48 <= code <= 57) or
                    (65 <= code <= 90) or
                    (97 <= code <= 122)
                )
                if is_alpha_num or ch in "._-":
                    safe_name += ch
                else:
                    safe_name += "_"

            safe_id = ""
            for ch in file_id:
                code = ord(ch)
                if 48 <= code <= 57:
                    safe_id += ch

            if path == "/download":
                if method != "GET":
                    send_error(conn, 405, "Method Not Allowed", "Use GET for /download")
                    continue

                if not safe_name or not safe_id:
                    send_error(conn, 400, "Bad Request", "Missing query params: name and id")
                    continue

                filepath = "{}/{}_{}".format(UPLOAD_DIR, safe_id, safe_name)
                try:
                    with open(filepath, "rb") as f:
                        log("Download gestart: {}".format(filepath))
                        send_response(conn, f.read(), content_type="application/octet-stream")
                    log("Download voltooid: {}".format(filepath))
                except:
                    log("Download mislukt, niet gevonden: {}".format(filepath))
                    send_error(conn, 404, "Not Found", "File not found")
                continue

            if path == "/delete":
                if method != "GET":
                    send_error(conn, 405, "Method Not Allowed", "Use GET for /delete")
                    continue

                if not safe_name or not safe_id:
                    send_error(conn, 400, "Bad Request", "Missing query params: name and id")
                    continue

                filepath = "{}/{}_{}".format(UPLOAD_DIR, safe_id, safe_name)
                try:
                    import os
                    os.remove(filepath)
                    log("Bestand verwijderd: {}".format(filepath))
                    send_response(conn, "Deleted: {}".format(filepath))
                except:
                    log("Delete mislukt, niet gevonden: {}".format(filepath))
                    send_error(conn, 404, "Not Found", "File not found")
                continue

            if path == "/list":
                if method != "GET":
                    send_error(conn, 405, "Method Not Allowed", "Use GET for /list")
                    continue

                try:
                    import os
                    files = []
                    for entry in os.listdir(UPLOAD_DIR):
                        if "_" not in entry:
                            continue
                        file_id, file_name = entry.split("_", 1)
                        files.append({
                            "id": file_id,
                            "name": file_name,
                            "stored": entry,
                        })
                    send_response(conn, json.dumps({"files": files}), content_type="application/json; charset=utf-8")
                except Exception as e:
                    log("List fout: {}".format(e))
                    send_error(conn, 500, "Internal Server Error", "List failed: {}".format(e))
                continue

            if path != "/upload":
                log("Status endpoint geraakt")
                send_response(conn, get_status_text())
                continue

            if method != "POST":
                send_error(conn, 405, "Method Not Allowed", "Use POST for /upload")
                continue

            if not name or not file_id:
                send_error(conn, 400, "Bad Request", "Missing query params: name and id")
                continue

            if not safe_name or not safe_id:
                send_error(conn, 400, "Bad Request", "Invalid name or id")
                continue

            content_length = int(headers.get("content-length", "0") or "0")
            if content_length <= 0:
                send_error(conn, 400, "Bad Request", "Missing file body")
                continue

            filepath = "{}/{}_{}".format(UPLOAD_DIR, safe_id, safe_name)
            log("Upload gestart: {} ({} bytes)".format(filepath, content_length))
            bytes_written = 0
            try:
                with open(filepath, "wb") as f:
                    if body:
                        f.write(body)
                        bytes_written = len(body)

                    while bytes_written < content_length:
                        chunk = conn.recv(min(1024, content_length - bytes_written))
                        if not chunk:
                            break
                        f.write(chunk)
                        bytes_written += len(chunk)
            except Exception as e:
                log("Upload write fout: {}".format(e))
                send_error(conn, 500, "Internal Server Error", "Write failed: {}".format(e))
                continue

            if bytes_written != content_length:
                try:
                    import os
                    os.remove(filepath)
                except:
                    pass
                log("Upload incompleet: {} van {} bytes".format(bytes_written, content_length))
                send_error(conn, 400, "Bad Request", "Incomplete upload body")
                continue

            log("Upload voltooid: {} ({} bytes)".format(filepath, bytes_written))
            send_response(conn, "Upload saved: {}".format(filepath))

            if safe_name.lower().endswith(".txt"):
                log("TXT upload ontvangen en klaar voor sync playback: {}".format(filepath))
        except OSError as e:
            log("Socket fout: {}".format(e))
        finally:
            if conn is not None:
                try:
                    conn.close()
                except:
                    pass
            gc.collect()

start_server()
