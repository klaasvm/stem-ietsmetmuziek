import argparse
import struct
import sys
import time
from pathlib import Path
from types import SimpleNamespace
import serial
import logging
from flask import Flask, request, jsonify
from werkzeug.utils import secure_filename
import threading

NUM_SPEAKERS = 5
INPUT_EXTENSIONS = (".mid", ".midi")

# Logger setup
logging.basicConfig(
	level=logging.INFO,
	format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Flask app
app = Flask(__name__)
UPLOAD_FOLDER = Path(__file__).resolve().parent / "downloads"
UPLOAD_FOLDER.mkdir(parents=True, exist_ok=True)
app.config['UPLOAD_FOLDER'] = str(UPLOAD_FOLDER)
app.config['MAX_CONTENT_LENGTH'] = 16 * 1024 * 1024  # 16MB max

# Serial connection
serial_conn = None
serial_lock = threading.Lock()


def log(message):
	logger.info(message)
	print(message)


def connect_serial(port, baudrate=9600):
	global serial_conn
	try:
		serial_conn = serial.Serial(port, baudrate, timeout=1)
		time.sleep(2)  # Arduino reset delay
		log(f"Verbonden met Arduino op {port} ({baudrate} baud)")
		return serial_conn
	except Exception as e:
		log(f"Kon niet verbinden met Arduino: {e}")
		raise


def _send_data_thread(data):
    global serial_conn
    if serial_conn is None:
        log("Geen seriële verbinding beschikbaar voor afspelen.")
        return

    with serial_lock:
        try:
            # Maak de buffer schoon voor we beginnen
            serial_conn.reset_input_buffer()
            
            lines = data.strip().split('\n')
            log(f"Start afspelen van {len(lines)} regels...")
            
            for line in lines:
                if not line.strip():
                    continue
                    
                # Stuur de data door (bijv: "0,440,240\n")
                serial_conn.write((line + '\n').encode('utf-8'))
                
                # Wacht op de 'OK' handshake van de Arduino
                while True:
                    if serial_conn.in_waiting > 0:
                        response = serial_conn.readline().decode('utf-8').strip()
                        if response == "OK":
                            break
                    time.sleep(0.001)
                    
            log("Afspelen voltooid!")
        except Exception as e:
            log(f"Fout tijdens sturen naar Arduino: {e}")

def send_to_arduino(data):
    # Start het afspelen in een achtergrond-proces, anders loopt je Flask server vast
    thread = threading.Thread(target=_send_data_thread, args=(data,))
    thread.start()


# MIDI parsing functions
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
    lines = []
    for row in table:
        lines.append(f"{row[0]},{row[1]},{row[2]}")
    # Zet er een lege regel achteraan ter afsluiting
    return "\n".join(lines) + "\n"


def convert_midi_file(input_path):
	try:
		messages = parse_midi_file(input_path)
		table = messages_to_table(messages)
		output_path = input_path.with_suffix(".txt")
		output_path.write_text(table_to_text(table), encoding="utf-8")
		log(f"Gekalkuleerd: {input_path.name} -> {output_path.name}")
		return output_path
	except Exception as e:
		log(f"Kon {input_path.name} niet converteren: {e}")
		raise


# Flask routes
@app.route('/upload', methods=['POST'])
def upload_file():
	if 'file' not in request.files:
		return jsonify({'error': 'Geen bestand geupload'}), 400
	
	file = request.files['file']
	if file.filename == '':
		return jsonify({'error': 'Geen bestand geselecteerd'}), 400
	
	if not file.filename.lower().endswith(INPUT_EXTENSIONS):
		return jsonify({'error': 'Alleen .mid of .midi bestanden toegestaan'}), 400
	
	try:
		filename = secure_filename(file.filename)
		filepath = Path(app.config['UPLOAD_FOLDER']) / filename
		file.save(str(filepath))
		log(f"Bestand ontvangen: {filename}")
		
		# Convert MIDI to TXT
		txt_path = convert_midi_file(filepath)
		
		# Send to Arduino
		txt_content = txt_path.read_text(encoding='utf-8')
		send_to_arduino(txt_content)
		
		# Clean up
		filepath.unlink()
		txt_path.unlink()
		
		return jsonify({'success': True, 'message': f'Bestand verwerkt en naar Arduino gestuurd: {filename}'}), 200
	
	except Exception as e:
		log(f"Fout bij uploaden: {e}")
		return jsonify({'error': str(e)}), 500


@app.route('/health', methods=['GET'])
def health():
	return jsonify({'status': 'ok', 'serial': serial_conn is not None}), 200


@app.route('/status', methods=['GET'])
def status():
	return jsonify({
		'status': 'running',
		'serial_connected': serial_conn is not None,
		'upload_folder': str(UPLOAD_FOLDER)
	}), 200


def parse_args():
	parser = argparse.ArgumentParser(
		description="MIDI naar Arduino server: ontvang files via HTTP, converteer naar txt en stuur via serial naar Arduino",
	)
	parser.add_argument("--port", default="COM10", help="Arduino COM poort (default: COM3)")
	parser.add_argument("--baudrate", type=int, default=115200, help="Baud rate (default: 9600)")
	parser.add_argument("--host", default="0.0.0.0", help="Server host (default: 0.0.0.0)")
	parser.add_argument("--http-port", type=int, default=5000, help="HTTP poort (default: 5000)")
	return parser.parse_args()


def main():
	args = parse_args()
	
	try:
		connect_serial(args.port, args.baudrate)
	except Exception as e:
		log(f"⚠️  Waarschuwing: Arduino niet verbonden, server start toch: {e}")
	
	log(f"🚀 Server start op http://{args.host}:{args.http_port}")
	log(f"📤 Upload endpoint: http://{args.host}:{args.http_port}/upload")
	log(f"❤️  Health check: http://{args.host}:{args.http_port}/health")
	
	try:
		app.run(host=args.host, port=args.http_port, debug=False, use_reloader=False)
	except KeyboardInterrupt:
		log("Server gestopt door gebruiker.")
		if serial_conn:
			serial_conn.close()
		return 0


if __name__ == "__main__":
	sys.exit(main())
