import re
import time
import math
import _thread

from machine import PWM, Pin

UPLOAD_DIR = "uploads"
NUM_SPEAKERS = 5
SPEAKER_PINS = (13, 27, 26, 25, 33)
INITIAL_US_PER_BEAT = 500000
TICKS_PER_BEAT = 480
STEPPER_ENABLED = False
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
    if not STEPPER_ENABLED:
        return [None] * NUM_SPEAKERS

    outputs = []
    for pin in SPEAKER_PINS:
        pwm = PWM(Pin(pin), freq=100, duty=0)
        outputs.append(pwm)
    return outputs


def _freq_to_note_name(freq):
    if freq <= 0:
        return "REST"

    # Approximate nearest MIDI note from frequency for readable simulation logs.
    note_number = int(round(69 + 12 * math.log2(freq / 440.0)))
    octave = (note_number // 12) - 1
    name = _NOTE_NAMES[note_number % 12]
    return "{}{}".format(name, octave)


def _set_channel_off(outputs, channel):
    if STEPPER_ENABLED:
        _pwm_off(outputs[channel])


def _set_channel_freq(outputs, channel, freq):
    if STEPPER_ENABLED:
        outputs[channel].freq(freq)
        _pwm_on(outputs[channel])


def _delay_us(delay_us):
    if delay_us <= 0:
        return

    if STEPPER_ENABLED:
        time.sleep_us(delay_us)
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
    us_per_beat = INITIAL_US_PER_BEAT
    us_per_tick = us_per_beat // TICKS_PER_BEAT
    previous_row = None
    row_count = 0
    music_len = None

    try:
        with open(path, "r") as f:
            for line in f:
                if stop_playback:
                    stop_playback = False
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
                        if not STEPPER_ENABLED:
                            bpm = 60000000 // us_per_beat if us_per_beat > 0 else 0
                            log("TEMPO -> usPerBeat={} usPerTick={} BPM~{}".format(us_per_beat, us_per_tick, bpm))
                    elif 0 <= prev_channel < NUM_SPEAKERS:
                        if prev_value <= 0:
                            _set_channel_off(outputs, prev_channel)
                            if not STEPPER_ENABLED:
                                log("CH{} OFF".format(prev_channel))
                        else:
                            _set_channel_freq(outputs, prev_channel, prev_value)
                            if not STEPPER_ENABLED:
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
                        _delay_us(delay_us)

                previous_row = current_row
                row_count += 1

        if previous_row is None:
            raise ValueError("Geen musicTable rows gevonden in txt")

        if music_len is None:
            music_len = max(0, row_count - (NUM_SPEAKERS + 1))
        log("Rows={} musicLen={}".format(row_count, music_len))

        for pwm in outputs:
            if pwm is not None:
                _pwm_off(pwm)

        log("Playback klaar")
    finally:
        _is_playing = False
        _current_txt_path = None
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