"""Local SenseVoice speech-recognition server for Typ.

Usage: python sensevoice_server.py <model_dir> <port> [default_lang]
POST /asr with a 16 kHz mono 16-bit WAV body (header X-Language: auto|zh|en|ja|ko|yue) -> {"text": "..."}
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

import numpy as np
import sherpa_onnx

MODEL_DIR, PORT = sys.argv[1], int(sys.argv[2])
LANGS = {"auto", "zh", "en", "ja", "ko", "yue"}
DEFAULT_LANG = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] in LANGS else "auto"
MODEL = next(p for p in (os.path.join(MODEL_DIR, n) for n in ("model.int8.onnx", "model.onnx")) if os.path.exists(p))
THREADS = max(2, min(8, (os.cpu_count() or 4) - 2))
recognizers = {}


def recognizer(lang):
    if lang not in recognizers:
        recognizers[lang] = sherpa_onnx.OfflineRecognizer.from_sense_voice(
            model=MODEL, tokens=os.path.join(MODEL_DIR, "tokens.txt"),
            num_threads=THREADS, use_itn=True, language=lang)
    return recognizers[lang]


def pcm_from_wav(body):
    # Find the "data" chunk instead of assuming a 44-byte header.
    i = body.find(b"data")
    start = i + 8 if i >= 0 else 44
    return np.frombuffer(body[start:start + ((len(body) - start) // 2) * 2], dtype=np.int16).astype(np.float32) / 32768


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, payload):
        data = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self._send(200, {"status": "ok", "model": os.path.basename(MODEL), "default_lang": DEFAULT_LANG})

    def do_POST(self):
        try:
            body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            lang = self.headers.get("X-Language", DEFAULT_LANG)
            if lang not in LANGS:
                lang = "auto" if "auto" in recognizers else DEFAULT_LANG
            rec = recognizer(lang)
            stream = rec.create_stream()
            stream.accept_waveform(16000, pcm_from_wav(body))
            rec.decode_stream(stream)
            self._send(200, {"text": stream.result.text, "lang": stream.result.lang})
        except Exception as e:  # report instead of dropping the connection
            self._send(500, {"error": str(e)})

    def log_message(self, *args):
        pass


recognizer(DEFAULT_LANG)  # load the model before reporting ready
print(f"SenseVoice ready on 127.0.0.1:{PORT} ({os.path.basename(MODEL)}, lang={DEFAULT_LANG}, threads={THREADS})", flush=True)
HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
