import socket
import network
import gc

def get_ip():
    wlan = network.WLAN(network.STA_IF)
    return wlan.ifconfig()[0] if wlan.isconnected() else "0.0.0.0"

def get_confirm_text():
    return "stem-ietsmetmuziek"

def get_status_text():
    return "esp32-ready"

def send_response(conn, body, content_type="text/plain; charset=utf-8"):
    header = (
        "HTTP/1.1 200 OK\r\n"
        f"Content-Type: {content_type}\r\n"
        f"Content-Length: {len(body)}\r\n"
        "Connection: close\r\n\r\n"
    )
    conn.sendall(header.encode() + body.encode())

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
            request_bytes = conn.recv(1024)
            request_text = request_bytes.decode("utf-8", "ignore") if request_bytes else ""
            path = get_request_path(request_text)

            if path == "/confirm":
                send_response(conn, get_confirm_text())
            else:
                send_response(conn, get_status_text())
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
