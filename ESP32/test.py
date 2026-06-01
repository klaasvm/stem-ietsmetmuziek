from machine import Pin
import time

# --- Instellingen (pas aan naar jouw bedrading) ---
# Motor 1
STEP_PIN_1 = 13       # STEP signaal motor 1
DIR_PIN_1  = 12       # DIR signaal motor 1

# Motor 2
STEP_PIN_2 = 14       # STEP signaal motor 2
DIR_PIN_2  = 27       # DIR signaal motor 2

DELAY_US_1 = 1500     # Tijd tussen stappen motor 1 (microseconden)
DELAY_US_2 = 1500     # Tijd tussen stappen motor 2 (microseconden)

DIRECTION_1 = 1       # 1 = vooruit, 0 = achteruit (motor 1)
DIRECTION_2 = 1       # 1 = vooruit, 0 = achteruit (motor 2)

# --- Setup pins ---
step1 = Pin(STEP_PIN_1, Pin.OUT)
dir1 = Pin(DIR_PIN_1, Pin.OUT)
step2 = Pin(STEP_PIN_2, Pin.OUT)
dir2 = Pin(DIR_PIN_2, Pin.OUT)

dir1.value(DIRECTION_1)
dir2.value(DIRECTION_2)

print("Stepper motor test gestart (2 motoren)")
print("  Motor1 STEP: {}  DIR: {}  Delay: {} us".format(STEP_PIN_1, DIR_PIN_1, DELAY_US_1))
print("  Motor2 STEP: {}  DIR: {}  Delay: {} us".format(STEP_PIN_2, DIR_PIN_2, DELAY_US_2))
print("Druk Ctrl+C om te stoppen.")

# --- Tijdsbeheer voor onafhankelijke snelheden ---
# Gebruik time.ticks_us zodat beide motoren onafhankelijk kunnen lopen
state1 = 0
state2 = 0
now = time.ticks_us()
next_toggle_1 = time.ticks_add(now, DELAY_US_1 // 2)
next_toggle_2 = time.ticks_add(now, DELAY_US_2 // 2)

try:
    while True:
        now = time.ticks_us()

        # Motor 1 toggle
        if time.ticks_diff(now, next_toggle_1) >= 0:
            state1 ^= 1
            step1.value(state1)
            next_toggle_1 = time.ticks_add(next_toggle_1, DELAY_US_1 // 2)

        # Motor 2 toggle
        if time.ticks_diff(now, next_toggle_2) >= 0:
            state2 ^= 1
            step2.value(state2)
            next_toggle_2 = time.ticks_add(next_toggle_2, DELAY_US_2 // 2)

except KeyboardInterrupt:
    step1.value(0)
    step2.value(0)
    print("Gestopt.")
