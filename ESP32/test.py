from machine import Pin
import time

# --- Instellingen ---
STEP_PIN1 = 13       # STEP signaal
STEP_PIN2 = 27       # STEP signaal
DIR_PIN  = 12       # DIR signaal

DELAY_US = 1500     # Tijd tussen stappen in microseconden (lager = sneller)
DIRECTION = 1       # 1 = vooruit, 0 = achteruit

# --- Setup ---
step1 = Pin(STEP_PIN1, Pin.OUT)
step2 = Pin(STEP_PIN2, Pin.OUT)
direction = Pin(DIR_PIN, Pin.OUT)

direction.value(DIRECTION)

print("Stepper motor test gestart")
print("  STEP pin : {}".format(STEP_PIN1))
print("  STEP pin : {}".format(STEP_PIN2))
print("  DIR  pin : {}".format(DIR_PIN))
print("  Richting : {}".format("vooruit" if DIRECTION else "achteruit"))
print("  Delay    : {} us per stap".format(DELAY_US))
print("Druk Ctrl+C om te stoppen.")

# --- Hoofdlus ---
try:
    while True:
        step1.value(1)
        step2.value(1)
        time.sleep_us(DELAY_US // 2)   # Halve periode HIGH
        step1.value(0)
        step2.value(0)
        time.sleep_us(DELAY_US // 2)   # Halve periode LOW

except KeyboardInterrupt:
    step1.value(0)
    step2.value(0)
    print("Gestopt.")
