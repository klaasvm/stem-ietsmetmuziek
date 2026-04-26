import argparse
import struct
import sys
import time
from pathlib import Path
from types import SimpleNamespace

import receive

NUM_SPEAKERS = 5
INPUT_EXTENSIONS = (".mid", ".midi")
POLL_INTERVAL = 1.2


def read_uint16(data, offset):
	return struct.unpack_from(">H", data, offset)[0], offset + 2


def read_uint32(data, offset):
	return struct.unpack_from(">I", data, offset)[0], offset + 4


def read_vlq(data, offset):
	value = 0
	while True:
		byte = data[offset]
		offset += 1
		value = (value << 7) | (byte & 0x7F)
		if byte < 0x80:
			return value, offset


def parse_track(track_data, track_index):
	events = []
	offset = 0
	abs_tick = 0
	running_status = None
	event_index = 0

	while offset < len(track_data):
		delta, offset = read_vlq(track_data, offset)
		abs_tick += delta

		status_byte = track_data[offset]
		if status_byte < 0x80:
			if running_status is None:
				raise ValueError("Running status without previous status")
			status = running_status
			first_data = status_byte
			offset += 1
			has_first_data = True
		else:
			status = status_byte
			offset += 1
			has_first_data = False
			if status < 0xF0:
				running_status = status

		if status == 0xFF:
			meta_type = track_data[offset]
			offset += 1
			length, offset = read_vlq(track_data, offset)
			meta_data = track_data[offset : offset + length]
			offset += length

			if meta_type == 0x51 and len(meta_data) == 3:
				tempo = (meta_data[0] << 16) | (meta_data[1] << 8) | meta_data[2]
				events.append((abs_tick, track_index, event_index, SimpleNamespace(type="set_tempo", tempo=tempo, time=0)))
				event_index += 1
			elif meta_type == 0x2F:
				break
			continue

		if status in (0xF0, 0xF7):
			length, offset = read_vlq(track_data, offset)
			offset += length
			continue

		if status in (0xF1, 0xF3):
			if not has_first_data:
				offset += 1
			continue

		if status == 0xF2:
			if not has_first_data:
				offset += 2
			continue

		if status in (0xF6, 0xF8, 0xF9, 0xFA, 0xFB, 0xFC, 0xFE):
			continue

		event_type = status & 0xF0
		channel = status & 0x0F

		if has_first_data:
			data1 = first_data
		else:
			data1 = track_data[offset]
			offset += 1

		if event_type in (0xC0, 0xD0):
			data2 = None
		else:
			data2 = track_data[offset]
			offset += 1

		if event_type == 0x90:
			velocity = data2 if data2 is not None else 0
			events.append(
				(
					abs_tick,
					track_index,
					event_index,
					SimpleNamespace(type="note_on", note=data1, velocity=velocity, channel=channel, time=0),
				)
			)
			event_index += 1
		elif event_type == 0x80:
			events.append(
				(
					abs_tick,
					track_index,
					event_index,
					SimpleNamespace(type="note_off", note=data1, velocity=data2 or 0, channel=channel, time=0),
				)
			)
			event_index += 1

	return events


def parse_midi_file(path):
	raw = path.read_bytes()
	offset = 0

	chunk_type = raw[offset : offset + 4]
	offset += 4
	if chunk_type != b"MThd":
		raise ValueError("Geen geldige MIDI-header")

	header_length, offset = read_uint32(raw, offset)
	if header_length < 6:
		raise ValueError("Onvolledige MIDI-header")

	_, offset = read_uint16(raw, offset)
	track_count, offset = read_uint16(raw, offset)
	division, offset = read_uint16(raw, offset)
	offset += header_length - 6

	if division & 0x8000:
		raise ValueError("SMPTE timing wordt niet ondersteund")

	all_events = []
	for track_index in range(track_count):
		if raw[offset : offset + 4] != b"MTrk":
			raise ValueError("Track chunk ontbreekt")
		offset += 4
		track_length, offset = read_uint32(raw, offset)
		track_data = raw[offset : offset + track_length]
		offset += track_length
		all_events.extend(parse_track(track_data, track_index))

	all_events.sort(key=lambda item: (item[0], item[1], item[2]))

	merged = []
	previous_tick = 0
	for abs_tick, _, _, event in all_events:
		event.time = abs_tick - previous_tick
		previous_tick = abs_tick
		merged.append(event)

	return merged


class SpeakerPool:
	def __init__(self, num_speakers):
		self.num_speakers = num_speakers
		self.free_speakers = list(range(num_speakers))
		self.note_to_speaker = {}
		self.speaker_to_note = {}
		self.speaker_to_freq = {}

	def acquire(self, note, freq):
		if note in self.note_to_speaker:
			speaker = self.note_to_speaker[note]
			self.speaker_to_freq[speaker] = freq
			return speaker

		if self.free_speakers:
			speaker = self.free_speakers.pop(0)
		else:
			speaker = self._steal_speaker()

		self.note_to_speaker[note] = speaker
		self.speaker_to_note[speaker] = note
		self.speaker_to_freq[speaker] = freq
		return speaker

	def release(self, note):
		speaker = self.note_to_speaker.pop(note, None)
		if speaker is None:
			return None

		self.speaker_to_note.pop(speaker, None)
		self.speaker_to_freq.pop(speaker, None)
		if speaker not in self.free_speakers:
			self.free_speakers.append(speaker)
			self.free_speakers.sort()
		return speaker

	def _steal_speaker(self):
		speaker = min(self.speaker_to_freq, key=self.speaker_to_freq.get)
		old_note = self.speaker_to_note.pop(speaker, None)
		if old_note is not None:
			self.note_to_speaker.pop(old_note, None)
		self.speaker_to_freq.pop(speaker, None)
		return speaker


def note_to_freq(note):
	a = 440
	return int(round((a / 32) * (2 ** ((note - 9) / 12))))


def messages_to_table(messages):
	pool = SpeakerPool(NUM_SPEAKERS)
	table = []

	for message in messages:
		if message.type == "set_tempo":
			table.append([NUM_SPEAKERS + 1, message.tempo, message.time])
			continue

		if message.type == "note_on" and message.velocity > 0:
			freq = note_to_freq(message.note)
			speaker = pool.acquire(message.note, freq)
			table.append([speaker, freq, message.time])
			continue

		if message.type in ("note_off", "note_on"):
			speaker = pool.release(message.note)
			if speaker is not None:
				table.append([speaker, 0, message.time])
			continue

	for speaker in range(NUM_SPEAKERS):
		table.append([speaker, 0, 0])

	table.append([0, 0, 0])
	return table


def table_to_text(table):
	lines = ["uint32_t musicTable[][3] = {"]
	for row in table:
		lines.append("  {{{}, {}, {}}},".format(row[0], row[1], row[2]))
	lines.append("};")
	lines.append("int musicLen = {};".format(max(0, len(table) - (NUM_SPEAKERS + 1))))
	return "\n".join(lines) + "\n"


def resolve_output_dir(output_arg):
	script_dir = Path(__file__).resolve().parent
	output_path = Path(output_arg)
	if output_path.is_absolute():
		return output_path
	return script_dir / output_path


def ensure_output_dir(path):
	path.mkdir(parents=True, exist_ok=True)


def unique_path(path):
	if not path.exists():
		return path

	root = path.with_suffix("")
	suffix = path.suffix
	counter = 1
	while True:
		candidate = Path("{}_{}{}".format(root, counter, suffix))
		if not candidate.exists():
			return candidate
		counter += 1


def convert_midi_file(input_path):
	messages = parse_midi_file(input_path)
	table = messages_to_table(messages)
	output_path = unique_path(input_path.with_suffix(".txt"))
	output_path.write_text(table_to_text(table), encoding="utf-8")
	receive.log("Gekalculerd: {} -> {}".format(input_path.name, output_path.name))
	input_path.unlink()
	receive.log("Bronbestand verwijderd: {}".format(input_path.name))
	return output_path


def process_local_downloads(download_dir):
	converted = 0
	for entry in sorted(download_dir.iterdir()):
		if not entry.is_file() or entry.suffix.lower() not in INPUT_EXTENSIONS:
			continue

		try:
			convert_midi_file(entry)
			converted += 1
		except Exception as exc:
			receive.log("Kon {} niet converteren: {}".format(entry.name, exc))

	return converted


def parse_args():
	parser = argparse.ArgumentParser(
		description="Eén entrypoint voor ESP32 uploads: ontvang, converteer naar txt en verwijder de midi.",
	)
	parser.add_argument("--ip", help="Optioneel vast ESP32 IP")
	parser.add_argument(
		"--out",
		default="downloads",
		help="Map voor ontvangen .mid/.midi bestanden en gegenereerde .txt bestanden (default: downloads)",
	)
	parser.add_argument(
		"--poll-seconds",
		type=float,
		default=POLL_INTERVAL,
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
	output_dir = resolve_output_dir(args.out)
	ensure_output_dir(output_dir)
	receive.log("Download map: {}".format(output_dir))

	ip = receive.connect_esp32(preferred_ip=args.ip, retry_delay=args.reconnect_seconds)

	while True:
		try:
			downloaded = receive.process_remote_files(ip, str(output_dir))
			converted = process_local_downloads(output_dir)
			if downloaded == 0 and converted == 0:
				time.sleep(args.poll_seconds)
		except KeyboardInterrupt:
			receive.log("Gestopt door gebruiker.")
			return 0
		except Exception as exc:
			receive.log("Fout tijdens sync: {}".format(exc))
			receive.log("Herstel connectie...")
			ip = receive.connect_esp32(preferred_ip=ip, retry_delay=args.reconnect_seconds)


if __name__ == "__main__":
	sys.exit(main())
