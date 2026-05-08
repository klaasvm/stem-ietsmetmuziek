import re
import time
import math
import _thread

from machine import PWM, Pin

UPLOAD_DIR = "uploads"
NUM_SPEAKERS = 5
SPEAKER_PINS = (13, 27, 26, 25, 33)
STEP_PIN = 13
DIR_PIN = 12
STEP_PULSE_US = 100
STEP_MIN_PERIOD_US = 200
INITIAL_US_PER_BEAT = 500000
TICKS_PER_BEAT = 480
STEPPER_ENABLED = True
SIMULATION_TIME_SCALE = 1.0
SIMULATION_LOG_WAITS = False

_current_txt_path = None
_is_playing = False
stop_playback = False

_ROW_PATTERN = re.compile(r"\{\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\}")
_LEN_PATTERN = re.compile(r"int\s+musicLen\s*=\s*(\d+)")
_NOTE_NAMES = ("C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B")


def log(message):
    try:
        now = time.localtime()
        stamp = "{:02d}:{:02d}:{:02d}".format(now[3], now[4], now[5])
    except Exception:
        stamp = "--:--:--"
    print("[{}] {}".format(stamp, message))


def _pwm_on(pwm):
    if hasattr(pwm, "duty_u16"):
        pwm.duty_u16(32768)
    else:
        pwm.duty(512)


def _pwm_off(pwm):
    if hasattr(pwm, "duty_u16"):
        pwm.duty_u16(0)
    else:
        pwm.duty(0)


def _create_pwm_outputs():
    if STEPPER_ENABLED:
        return None

    outputs = []
    for pin in SPEAKER_PINS:
        pwm = PWM(Pin(pin), freq=100, duty=0)
        outputs.append(pwm)
    return outputs


class StepperDriver:
    def __init__(self, step_pin, dir_pin):
        self.step_pin = Pin(step_pin, Pin.OUT)
        self.dir_pin = Pin(dir_pin, Pin.OUT)
        self.step_pin.value(0)
        self.dir_pin.value(1)

    def set_direction(self, forward=True):
        self.dir_pin.value(1 if forward else 0)

    def step_pulse(self, pulse_us, gap_us):
        self.step_pin.value(1)
        time.sleep_us(pulse_us)
        self.step_pin.value(0)
        if gap_us > 0:
            time.sleep_us(gap_us)

    def deinit(self):
        self.step_pin.value(0)
        self.dir_pin.value(0)
        try:
            self.step_pin.deinit()
            self.dir_pin.deinit()
        except Exception:
            pass


def _freq_to_note_name(freq):
    if freq <= 0:
        return "REST"

    # Approximate nearest MIDI note from frequency for readable simulation logs.
    note_number = int(round(69 + 12 * math.log2(freq / 440.0)))
    octave = (note_number // 12) - 1
    name = _NOTE_NAMES[note_number % 12]
    return "{}{}".format(name, octave)


def _set_channel_off(outputs, channel):
    if not STEPPER_ENABLED and outputs is not None:
        _pwm_off(outputs[channel])


def _set_channel_freq(outputs, channel, freq):
    if not STEPPER_ENABLED and outputs is not None:
        outputs[channel].freq(freq)
        _pwm_on(outputs[channel])


def _delay_us(delay_us, stepper=None, current_freq=0):
    if delay_us <= 0:
        return

    if STEPPER_ENABLED and stepper is not None and current_freq > 0:
        period = max(STEP_MIN_PERIOD_US, int(1000000 // current_freq))
        pulse_us = min(STEP_PULSE_US, period // 2)
        gap_us = period - pulse_us
        start = time.ticks_us()
        while time.ticks_diff(time.ticks_us(), start) < delay_us:
            if stop_playback:
                break
            stepper.step_pulse(pulse_us, gap_us)
        return

    scaled = int(delay_us * SIMULATION_TIME_SCALE)
    time.sleep_us(max(1, scaled))


def _read_text(path):
    with open(path, "r") as f:
        return f.read()


def _delete_file(path):
    import os

    try:
        os.remove(path)
        log("TXT verwijderd: {}".format(path))
    except OSError as exc:
        log("TXT verwijderen mislukt: {} ({})".format(path, exc))


def _find_latest_txt():
    import os

    latest_name = None
    latest_id = -1

    for name in os.listdir(UPLOAD_DIR):
        if not name.lower().endswith(".txt"):
            continue

        file_id = -1
        if "_" in name:
            prefix = name.split("_", 1)[0]
            if prefix.isdigit():
                file_id = int(prefix)

        if file_id > latest_id:
            latest_id = file_id
            latest_name = name
        elif latest_name is None:
            latest_name = name

    if latest_name is None:
        return None
    return "{}/{}".format(UPLOAD_DIR, latest_name)


def has_pending_txt():
    return _find_latest_txt() is not None


def playback_state():
    return {
        "playing": _is_playing,
        "pending": has_pending_txt(),
        "current": _current_txt_path,
    }


def stop_all(outputs=None):
    if STEPPER_ENABLED:
        return

    own_outputs = outputs is None
    if own_outputs:
        outputs = _create_pwm_outputs()

    try:
        for pwm in outputs:
            if pwm is not None:
                _pwm_off(pwm)
    finally:
        if own_outputs:
            for pwm in outputs:
                if pwm is not None:
                    pwm.deinit()


def play_file(path, delete_after=False):
    global _is_playing, _current_txt_path, stop_playback

    log("Muziek laden: {}".format(path))
    log("Mode: {}".format("STEPPER" if STEPPER_ENABLED else "SIMULATIE"))
    _current_txt_path = path
    _is_playing = True
    outputs = _create_pwm_outputs()
    stepper = StepperDriver(STEP_PIN, DIR_PIN) if STEPPER_ENABLED else None
    if stepper is not None:
        stepper.set_direction(True)

    us_per_beat = INITIAL_US_PER_BEAT
    us_per_tick = us_per_beat // TICKS_PER_BEAT
    previous_row = None
    row_count = 0
    music_len = None
    active_freqs = {}
    current_freq = 0

    try:
        with open(path, "r") as f:
            for line in f:
                if stop_playback:
                    stop_playback = False
                    if delete_after:
                        _delete_file(path)
                    log('playback onderbroken')
                    return
                if music_len is None and "int musicLen" in line:
                    match = _LEN_PATTERN.search(line)
                    if match:
                        music_len = int(match.group(1))

                match = _ROW_PATTERN.search(line)
                if not match:
                    continue

                current_row = (
                    int(match.group(1)),
                    int(match.group(2)),
                    int(match.group(3)),
                )

                if previous_row is not None:
                    prev_channel, prev_value, _ = previous_row

                    if prev_channel == NUM_SPEAKERS + 1:
                        us_per_beat = prev_value
                        us_per_tick = max(1, us_per_beat // TICKS_PER_BEAT)
                        bpm = 60000000 // us_per_beat if us_per_beat > 0 else 0
                        log("TEMPO -> usPerBeat={} usPerTick={} BPM~{}".format(us_per_beat, us_per_tick, bpm))
                    elif 0 <= prev_channel < NUM_SPEAKERS:
                        if STEPPER_ENABLED:
                            if prev_value <= 0:
                                active_freqs.pop(prev_channel, None)
                            else:
                                active_freqs[prev_channel] = prev_value
                            current_freq = max(active_freqs.values()) if active_freqs else 0
                        else:
                            if prev_value <= 0:
                                _set_channel_off(outputs, prev_channel)
                                log("CH{} OFF".format(prev_channel))
                            else:
                                _set_channel_freq(outputs, prev_channel, prev_value)
                                note_name = _freq_to_note_name(prev_value)
                                period_us = 1000000 // prev_value if prev_value > 0 else 0
                                log(
                                    "CH{} NOTE={} FREQ={}Hz STEP_PERIOD={}us".format(
                                        prev_channel,
                                        note_name,
                                        prev_value,
                                        period_us,
                                    )
                                )

                    delay_ticks = current_row[2]
                    if delay_ticks > 0:
                        delay_us = delay_ticks * us_per_tick
                        if not STEPPER_ENABLED and SIMULATION_LOG_WAITS:
                            log("WAIT ticks={} -> {}us (scaled x{})".format(delay_ticks, delay_us, SIMULATION_TIME_SCALE))
                        _delay_us(delay_us, stepper=stepper, current_freq=current_freq)

                previous_row = current_row
                row_count += 1

        if previous_row is None:
            raise ValueError("Geen musicTable rows gevonden in txt")

        if music_len is None:
            music_len = max(0, row_count - (NUM_SPEAKERS + 1))
        log("Rows={} musicLen={}".format(row_count, music_len))

        if not STEPPER_ENABLED and outputs is not None:
            for pwm in outputs:
                if pwm is not None:
                    _pwm_off(pwm)

        log("Playback klaar")
    finally:
        _is_playing = False
        _current_txt_path = None
        if stepper is not None:
            stepper.deinit()
        elif outputs is not None:
            for pwm in outputs:
                if pwm is not None:
                    pwm.deinit()

    if delete_after:
        _delete_file(path)


def play_latest():
    latest = _find_latest_txt()
    if latest is None:
        raise ValueError("Geen .txt bestanden gevonden in uploads")

    play_file(latest, delete_after=True)
    return latest


def auto_play_incoming_txt(path):
    if not path.lower().endswith(".txt"):
        return False

    play_file(path, delete_after=True)
    return True


def start_playback_when_requested(delay_ms=0):
    if _is_playing:
        raise ValueError("Playback al bezig")

    latest = _find_latest_txt()
    if latest is None:
        raise ValueError("Geen .txt bestanden gevonden in uploads")

    if delay_ms > 0:
        log("Playback gepland over {} ms".format(delay_ms))
        time.sleep_ms(delay_ms)

    play_file(latest, delete_after=True)
    return latest


def start_playback_async(delay_ms=0):
    def _runner():
        try:
            start_playback_when_requested(delay_ms=delay_ms)
        except Exception as exc:
            log("Async playback fout: {}".format(exc))

    _thread.start_new_thread(_runner, ())

def interupt_playback():
    global stop_playback
    stop_playback = True