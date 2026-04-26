import socket
import network
import gc

try:
    import ujson as json
except:
    import json

UPLOAD_DIR = "uploads"

def get_ip():
    wlan = network.WLAN(network.STA_IF)
    return wlan.ifconfig()[0] if wlan.isconnected() else "0.0.0.0"

def get_confirm_text():
    return "stem-ietsmetmuziek"

def get_status_text():
    return "esp32-ready"

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
    print(f"Server op http://{get_ip()}:{port}")

    while True:
        conn = None
        try:
            conn, _ = s.accept()
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

            headers = {}
            for line in lines[1:]:
                sep = line.find(":")
                if sep != -1:
                    key = line[:sep].strip().lower()
                    value = line[sep + 1:].strip()
                    headers[key] = value

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
                        send_response(conn, f.read(), content_type="application/octet-stream")
                except:
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
                    send_response(conn, "Deleted: {}".format(filepath))
                except:
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
                    send_error(conn, 500, "Internal Server Error", "List failed: {}".format(e))
                continue

            if path != "/upload":
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
                send_error(conn, 500, "Internal Server Error", "Write failed: {}".format(e))
                continue

            if bytes_written != content_length:
                try:
                    import os
                    os.remove(filepath)
                except:
                    pass
                send_error(conn, 400, "Bad Request", "Incomplete upload body")
                continue

            send_response(conn, "Upload saved: {}".format(filepath))
        except OSError as e:
            print("Fout:", e)
        finally:
            if conn is not None:
                try:
                    conn.close()
                except:
                    pass
            gc.collect()

start_server()
