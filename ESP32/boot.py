import network
import time

SSID = ""
PASSWORD = ""

def connect_wifi():
    wlan = network.WLAN(network.STA_IF)
    wlan.active(True)
 
    if wlan.isconnected():
        print("Al verbonden:", wlan.ifconfig())
        return wlan
 
    print(f"Verbinden met '{SSID}' ...")
    wlan.connect(SSID, PASSWORD)
 
    timeout = 15  # seconden
    t = 0
    while not wlan.isconnected():
        time.sleep(1)
        t += 1
        print(f"  wachten... ({t}s)")
        if t >= timeout:
            print("❌ Verbinding mislukt. Controleer SSID / wachtwoord.")
            return None
 
    ip, subnet, gateway, dns = wlan.ifconfig()
    print("✅ Verbonden!")
    print(f"   IP-adres : {ip}")
    print(f"   Subnetmask: {subnet}")
    print(f"   Gateway  : {gateway}")
    return wlan
 
wlan = connect_wifi()
