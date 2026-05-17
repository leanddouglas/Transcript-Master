#!/usr/bin/env python3
"""
Universal transcript service for hermes-hub.

Endpoints:
  GET  /                  → index.html (UI)
  GET  /manifest.webmanifest, /sw.js, /icon-*.png
  GET  /recent            → JSON list of recent vault transcripts
  GET  /vault/<filename>  → raw transcript text from inbox
  POST /fetch             → YouTube URL → fetch.sh (subs) → vault .txt
                             auto-falls-back to Whisper on no-captions
  POST /transcribe        → universal:
                              JSON  {"url": "..."}            → web/PDF/YouTube
                              multipart file=<...>            → audio/video/pdf/
                                                                doc/html/txt/srt
Stdlib only. External tools (whisper-cli, ffmpeg, pdftotext, pandoc) shelled
out via subprocess.run(shell=False). Tailscale-bound only.
"""
from __future__ import annotations

import html.parser
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import urllib.request
import uuid
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

# -------------------------- config --------------------------

HOST = "100.121.62.15"          # Tailscale interface only
PORT = 8765
APP_DIR = Path(__file__).resolve().parent
INBOX_DIR = Path.home() / "Obsidian/MrD-Brain/Inbox/youtube"
LOG_PATH = Path.home() / "Library/Logs/yt-transcript.log"
FETCH_SH = Path.home() / ".claude/skills/youtube-transcript/fetch.sh"
WHISPER_CONF = Path.home() / "Library/Application Support/yt-transcript/whisper.conf"
JOBS_DIR = Path.home() / "Library/Application Support/yt-transcript/jobs"
JOBS_TMP_DIR = JOBS_DIR / "_tmp"

MAX_UPLOAD_BYTES = 5 * 1024 * 1024 * 1024  # 5 GB (5h FLAC headroom)
MAX_URL_FETCH_BYTES = 15 * 1024 * 1024     # 15 MB for non-YouTube URLs
WHISPER_TIMEOUT_S = 4 * 60 * 60            # 4 h hard cap per transcript
FFMPEG_TIMEOUT_S = 30 * 60                 # 30 min for conversion (long videos)
JOB_PRUNE_DAYS = 30
UPLOAD_STREAM_BLOCK = 64 * 1024            # 64 KB per recv() during streaming

# Tools — populated from whisper.conf if present
WHISPER_BIN: str | None = None
WHISPER_MODEL_FILE: str | None = None
FFMPEG_BIN: str | None = None
PDFTOTEXT_BIN: str | None = None
PANDOC_BIN: str | None = None


def load_tools_conf() -> None:
    global WHISPER_BIN, WHISPER_MODEL_FILE, FFMPEG_BIN, PDFTOTEXT_BIN, PANDOC_BIN
    if not WHISPER_CONF.is_file():
        return
    for line in WHISPER_CONF.read_text(errors="replace").splitlines():
        if "=" not in line or line.startswith("#"):
            continue
        k, v = line.split("=", 1)
        v = v.strip()
        if k == "WHISPER_BIN":         WHISPER_BIN = v
        elif k == "WHISPER_MODEL_FILE": WHISPER_MODEL_FILE = v
        elif k == "FFMPEG_BIN":         FFMPEG_BIN = v
        elif k == "PDFTOTEXT_BIN":      PDFTOTEXT_BIN = v
        elif k == "PANDOC_BIN":         PANDOC_BIN = v


load_tools_conf()


# -------------------------- format groups --------------------------

AUDIO_EXTS = {".mp3", ".m4a", ".wav", ".webm", ".ogg", ".flac", ".aac", ".opus", ".aiff", ".aif", ".oga"}
VIDEO_EXTS = {".mp4", ".mov", ".mkv", ".avi", ".flv", ".wmv", ".m4v", ".3gp", ".mpg", ".mpeg"}
PDF_EXTS   = {".pdf"}
DOC_EXTS   = {".docx", ".doc", ".rtf", ".odt", ".epub"}
HTML_EXTS  = {".html", ".htm"}
TEXT_EXTS  = {".txt", ".md", ".markdown", ".log"}
SUB_EXTS   = {".srt", ".vtt"}
ALL_EXTS = AUDIO_EXTS | VIDEO_EXTS | PDF_EXTS | DOC_EXTS | HTML_EXTS | TEXT_EXTS | SUB_EXTS

YOUTUBE_RE = re.compile(r"^https?://(www\.|m\.)?(youtube\.com/|youtu\.be/)", re.IGNORECASE)
URL_RE = re.compile(r"^https?://", re.IGNORECASE)


STATIC_FILES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/index.html": ("index.html", "text/html; charset=utf-8"),
    "/manifest.webmanifest": ("manifest.webmanifest", "application/manifest+json"),
    "/sw.js": ("sw.js", "application/javascript"),
    "/icon-192.png": ("icon-192.png", "image/png"),
    "/icon-512.png": ("icon-512.png", "image/png"),
}


# -------------------------- logging --------------------------

def log(msg: str) -> None:
    # launchd already redirects our stdout/stderr to LOG_PATH, so just write
    # to stdout — that avoids the double-write that earlier appended every
    # line twice.
    line = f"{datetime.now().isoformat(timespec='seconds')}  {msg}\n"
    sys.stdout.write(line)
    sys.stdout.flush()


# -------------------------- helpers --------------------------

def _safe_filename(name: str, fallback: str = "transcript") -> str:
    stem = Path(name).stem if name else fallback
    stem = re.sub(r"[/\\\x00-\x1f]", "_", stem)
    stem = stem.strip().strip(".") or fallback
    return stem[:120]


def _save_transcript(text: str, original_name: str, source: str, kind: str,
                     language: str = "auto") -> dict:
    """Write a transcript with header to vault inbox. Avoid clobber via timestamp."""
    INBOX_DIR.mkdir(parents=True, exist_ok=True)
    safe = _safe_filename(original_name)
    fname = f"{safe} [{kind}].txt"
    out_path = INBOX_DIR / fname
    if out_path.exists():
        ts = datetime.now().strftime("%Y%m%d-%H%M%S")
        fname = f"{safe} [{kind}-{ts}].txt"
        out_path = INBOX_DIR / fname

    header = (
        f"# {Path(original_name).stem if original_name else safe}\n"
        f"# source: {source}\n"
        f"# kind: {kind}\n"
        f"# language: {language}\n"
        f"# transcribed: {datetime.now().isoformat(timespec='seconds')}\n"
        f"\n"
    )
    full = header + text.strip() + "\n"
    out_path.write_text(full, encoding="utf-8")
    return {
        "filename": fname,
        "saved_to": str(out_path),
        "also_saved": [],
        "text": full,
    }


def _url_to_name(url: str) -> str:
    p = urllib.parse.urlparse(url)
    name = (p.netloc.replace("www.", "") + p.path.replace("/", "_")).strip("_")
    name = re.sub(r"[^\w\-. ]", "_", name)[:80] or "page"
    return f"{name} {datetime.now().strftime('%Y%m%d-%H%M%S')}"


# -------------------------- handlers --------------------------

def transcribe_audio_or_video(src: Path, original_name: str) -> dict:
    """Convert to 16 kHz mono WAV via ffmpeg, run Whisper, save text."""
    if not WHISPER_BIN or not WHISPER_MODEL_FILE:
        raise RuntimeError("Whisper not installed — run install-whisper.command")
    if not FFMPEG_BIN:
        raise RuntimeError("ffmpeg not installed")
    if not Path(WHISPER_MODEL_FILE).is_file():
        raise RuntimeError(f"whisper model file missing: {WHISPER_MODEL_FILE}")

    with tempfile.TemporaryDirectory() as tmp:
        wav = Path(tmp) / "audio.wav"
        log(f"FFMPEG  {src.name} → 16kHz mono wav")
        ff = subprocess.run(
            [FFMPEG_BIN, "-y", "-loglevel", "error",
             "-i", str(src),
             "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le",
             str(wav)],
            capture_output=True, timeout=FFMPEG_TIMEOUT_S, shell=False,
        )
        if ff.returncode != 0:
            raise RuntimeError(f"ffmpeg failed: {ff.stderr.decode(errors='replace')[-500:]}")

        out_base = Path(tmp) / "transcript"
        log(f"WHISPER {wav.name}  model={Path(WHISPER_MODEL_FILE).name}")
        wh = subprocess.run(
            [WHISPER_BIN,
             "-m", WHISPER_MODEL_FILE,
             "-f", str(wav),
             "-otxt",
             "-of", str(out_base),
             "-l", "auto",
             "--no-prints"],
            capture_output=True, timeout=WHISPER_TIMEOUT_S, shell=False,
        )
        if wh.returncode != 0:
            raise RuntimeError(f"whisper failed: {wh.stderr.decode(errors='replace')[-500:]}")

        # whisper-cli writes <out_base>.txt
        txt = Path(str(out_base) + ".txt")
        if not txt.is_file():
            txt = out_base.with_suffix(".txt")
        if not txt.is_file():
            raise RuntimeError("whisper produced no .txt output")
        text = txt.read_text(encoding="utf-8", errors="replace")

    kind = "video" if src.suffix.lower() in VIDEO_EXTS else "audio"
    return _save_transcript(text, original_name, source=f"{kind}: {original_name}",
                            kind=kind, language="auto")


def transcribe_pdf(src: Path, original_name: str) -> dict:
    if not PDFTOTEXT_BIN:
        raise RuntimeError("pdftotext not installed (brew install poppler)")
    out = subprocess.run(
        [PDFTOTEXT_BIN, "-layout", str(src), "-"],
        capture_output=True, timeout=120, shell=False,
    )
    if out.returncode != 0:
        raise RuntimeError(f"pdftotext failed: {out.stderr.decode(errors='replace')[-400:]}")
    text = out.stdout.decode("utf-8", errors="replace")
    return _save_transcript(text, original_name, source=f"pdf: {original_name}", kind="pdf")


def transcribe_pandoc(src: Path, original_name: str) -> dict:
    if not PANDOC_BIN:
        raise RuntimeError("pandoc not installed (brew install pandoc)")
    out = subprocess.run(
        [PANDOC_BIN, str(src), "-t", "plain", "--wrap=none"],
        capture_output=True, timeout=120, shell=False,
    )
    if out.returncode != 0:
        raise RuntimeError(f"pandoc failed: {out.stderr.decode(errors='replace')[-400:]}")
    text = out.stdout.decode("utf-8", errors="replace")
    kind_map = {".docx": "docx", ".doc": "doc", ".rtf": "rtf", ".odt": "odt", ".epub": "epub"}
    kind = kind_map.get(src.suffix.lower(), "doc")
    return _save_transcript(text, original_name, source=f"{kind}: {original_name}", kind=kind)


def transcribe_html_bytes(content: bytes, original_name: str, source: str,
                          kind: str = "html") -> dict:
    text = _html_to_text(content.decode("utf-8", errors="replace"))
    return _save_transcript(text, original_name, source=source, kind=kind)


def transcribe_text_bytes(content: bytes, original_name: str) -> dict:
    text = content.decode("utf-8", errors="replace")
    return _save_transcript(text, original_name, source=f"file: {original_name}", kind="text")


def transcribe_subs_bytes(content: bytes, original_name: str) -> dict:
    text = _strip_subs(content.decode("utf-8", errors="replace"))
    return _save_transcript(text, original_name, source=f"subs: {original_name}", kind="subs")


def transcribe_url(url: str) -> dict:
    """Generic URL — auto-detects PDF vs HTML by Content-Type."""
    req = urllib.request.Request(url, headers={
        "User-Agent": "Mozilla/5.0 (compatible; yt-transcript/1.0; +tailscale)",
        "Accept": "text/html,application/xhtml+xml,application/pdf,*/*;q=0.8",
    })
    log(f"WEB-FETCH {url}")
    with urllib.request.urlopen(req, timeout=30) as resp:
        content = resp.read(MAX_URL_FETCH_BYTES + 1)
        if len(content) > MAX_URL_FETCH_BYTES:
            raise RuntimeError(f"page exceeds {MAX_URL_FETCH_BYTES} bytes")
        ctype = resp.headers.get("Content-Type", "").split(";")[0].strip().lower()
        final_url = resp.geturl()

    if ctype == "application/pdf" or final_url.lower().endswith(".pdf"):
        with tempfile.NamedTemporaryFile(suffix=".pdf", delete=False) as f:
            f.write(content); tmp = Path(f.name)
        try:
            return transcribe_pdf(tmp, _url_to_name(final_url) + ".pdf")
        finally:
            tmp.unlink(missing_ok=True)

    # default: HTML
    text = _html_to_text(content.decode("utf-8", errors="replace"))
    return _save_transcript(text, _url_to_name(final_url),
                            source=f"url: {final_url}", kind="web")


def whisper_youtube_fallback(url: str) -> dict:
    """Last-resort transcription when YouTube has no subs:
    yt-dlp downloads audio → ffmpeg WAV → whisper."""
    if not WHISPER_BIN or not WHISPER_MODEL_FILE or not FFMPEG_BIN:
        raise RuntimeError("Whisper not installed — run install-whisper.command")

    log(f"FALLBACK yt-dlp + whisper for {url}")
    with tempfile.TemporaryDirectory() as tmp:
        out_template = str(Path(tmp) / "audio.%(ext)s")
        yt = subprocess.run(
            ["yt-dlp", "-x", "--audio-format", "m4a", "--audio-quality", "0",
             "--no-warnings", "--no-playlist",
             "-o", out_template, url],
            capture_output=True, timeout=600, shell=False,
        )
        if yt.returncode != 0:
            raise RuntimeError(f"yt-dlp audio dl failed: {yt.stderr.decode(errors='replace')[-500:]}")
        # find produced audio file
        cands = sorted(Path(tmp).glob("audio.*"), key=lambda p: p.stat().st_size, reverse=True)
        if not cands:
            raise RuntimeError("yt-dlp produced no audio file")
        audio_path = cands[0]
        # Use the YT video ID as the name if we can extract it
        m = re.search(r"(?:v=|youtu\.be/)([A-Za-z0-9_-]{6,})", url)
        name = f"yt_{m.group(1)}" if m else "yt_video"
        return transcribe_audio_or_video(audio_path, name + audio_path.suffix)


# -------------------------- HTML stripper --------------------------

class _HTMLTextExtractor(html.parser.HTMLParser):
    SKIP = {"script", "style", "noscript", "iframe", "svg", "nav", "footer",
            "aside", "header", "form", "button"}
    BLOCK = {"p", "div", "br", "li", "h1", "h2", "h3", "h4", "h5", "h6",
             "tr", "pre", "blockquote", "section", "article"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        self.skip_depth = 0

    def handle_starttag(self, tag, attrs):
        if tag in self.SKIP: self.skip_depth += 1
        elif tag == "br": self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in self.SKIP and self.skip_depth > 0: self.skip_depth -= 1
        elif tag in self.BLOCK: self.parts.append("\n")

    def handle_data(self, data):
        if self.skip_depth == 0: self.parts.append(data)


def _html_to_text(html_str: str) -> str:
    p = _HTMLTextExtractor()
    try:
        p.feed(html_str)
    except Exception:
        pass
    raw = "".join(p.parts)
    # collapse whitespace, drop blank lines
    out_lines, prev_blank = [], False
    for line in raw.split("\n"):
        s = re.sub(r"\s+", " ", line).strip()
        if not s:
            if not prev_blank and out_lines:
                out_lines.append("")
            prev_blank = True
        else:
            out_lines.append(s); prev_blank = False
    return "\n".join(out_lines).strip()


def _strip_subs(content: str) -> str:
    """SRT/VTT cues → clean lines, dedup consecutive duplicates."""
    cleaned, prev = [], None
    for line in content.splitlines():
        s = line.strip()
        if not s: continue
        if s in {"WEBVTT"} or s.startswith(("Kind:", "Language:", "NOTE")): continue
        if re.fullmatch(r"\d+", s): continue
        if "-->" in s: continue
        s = re.sub(r"<[^>]+>", "", s).strip()
        if not s or s == prev: continue
        cleaned.append(s); prev = s
    return "\n".join(cleaned)


# -------------------------- multipart parser --------------------------

def stream_multipart_to_disk(rfile, length: int, content_type: str,
                             dest_dir: Path, max_bytes: int,
                             socket_obj=None, recv_timeout: float = 60.0) -> dict:
    """Stream a multipart/form-data body to disk WITHOUT buffering it all in
    memory. Returns dict with the first file part's filename, content_type,
    on-disk path, and size. Raises ValueError or ConnectionError on bad input.

    Designed to handle multi-GB uploads (audiobooks, podcasts) cleanly. Boundary
    detection scans across read chunks via a small overlap buffer.

    socket_obj: optional underlying socket. If provided, a per-recv timeout is
    enforced so a wedged client (e.g. Transfer-Encoding: chunked but no chunks
    actually sent) cannot pile up stuck threads.
    """
    m = re.search(r"boundary=([^;]+)", content_type, re.IGNORECASE)
    if not m:
        raise ValueError("no boundary in Content-Type")
    boundary = m.group(1).strip().strip('"').encode()
    if not boundary:
        raise ValueError("empty boundary")

    # In multipart bodies, every boundary AFTER the preamble is preceded by
    # \r\n. The first boundary in a well-formed body usually starts at byte 0.
    first_delim = b"--" + boundary
    body_delim = b"\r\n" + first_delim   # boundary marking end of file body
    delim_len = len(body_delim)

    if length and length > max_bytes:
        raise ValueError(f"upload too large: {length} > {max_bytes}")

    BLOCK = UPLOAD_STREAM_BLOCK
    bytes_read = 0
    remaining = length if length > 0 else max_bytes  # chunked: cap by max_bytes

    # Force a per-recv() socket timeout so a wedged client (e.g. a curl
    # request claiming Transfer-Encoding: chunked but not actually sending
    # chunks) cannot pile up indefinitely-blocked threads.
    sock = socket_obj
    prev_timeout = None
    if sock is None:
        # Best-effort fallback if caller didn't pass the socket explicitly.
        try:
            raw = getattr(rfile, "raw", None)
            sock = getattr(raw, "_sock", None) if raw else None
            if sock is None:
                sock = getattr(rfile, "_sock", None)
        except Exception:
            sock = None
    if sock is not None and hasattr(sock, "gettimeout"):
        try:
            prev_timeout = sock.gettimeout()
            sock.settimeout(recv_timeout)
        except Exception:
            sock = None

    def read_some() -> bytes:
        nonlocal bytes_read, remaining
        if remaining <= 0:
            return b""
        n = min(BLOCK, remaining)
        try:
            chunk = rfile.read(n)
        except (TimeoutError, OSError) as e:
            # socket.timeout subclasses OSError on 3.10+, TimeoutError on 3.11+
            raise ValueError(f"upload stalled (socket timeout): {e}") from e
        if not chunk:
            return b""
        bytes_read += len(chunk)
        if length > 0:
            remaining -= len(chunk)
        return chunk

    # ------ phase 1: skip preamble + read part headers ------
    preamble = bytearray()
    while True:
        idx = preamble.find(b"\r\n\r\n")
        if idx >= 0:
            break
        if len(preamble) > 16384:  # sanity cap on header section
            raise ValueError("part headers too large")
        chunk = read_some()
        if not chunk:
            raise ValueError("connection closed before part headers")
        preamble.extend(chunk)

    header_section = bytes(preamble[:idx])
    body_carry = bytes(preamble[idx + 4:])

    filename = None
    part_ctype = ""
    for line in header_section.decode("utf-8", errors="replace").split("\r\n"):
        low = line.lower()
        if low.startswith("content-disposition:"):
            disp = line.split(":", 1)[1].strip()
            fnm = re.search(r'filename="([^"]*)"', disp)
            if fnm and fnm.group(1):
                filename = fnm.group(1)
        elif low.startswith("content-type:"):
            part_ctype = line.split(":", 1)[1].strip()

    if not filename:
        raise ValueError("no filename in part header")

    safe_name = re.sub(r"[/\\\x00-\x1f]", "_", filename)[:200] or "upload.bin"
    ext = Path(safe_name).suffix.lower() or ".bin"
    dest_dir.mkdir(parents=True, exist_ok=True)
    out_path = dest_dir / f"upload-{uuid.uuid4().hex[:12]}{ext}"

    # ------ phase 2: stream body until next boundary ------
    buf = bytearray(body_carry)
    written = 0
    try:
        try:
            with open(out_path, "wb") as f:
                while True:
                    hit = buf.find(body_delim)
                    if hit >= 0:
                        f.write(bytes(buf[:hit]))
                        written += hit
                        break
                    # Keep last (delim_len-1) bytes in buf so a delim spanning
                    # two chunks is still found.
                    if len(buf) > delim_len:
                        f.write(bytes(buf[:-delim_len]))
                        written += len(buf) - delim_len
                        del buf[:-delim_len]
                    if written + len(buf) > max_bytes:
                        raise ValueError(f"upload exceeded max_bytes={max_bytes}")
                    chunk = read_some()
                    if not chunk:
                        # Stream ended without seeing closing boundary; flush remainder.
                        f.write(bytes(buf))
                        written += len(buf)
                        break
                    buf.extend(chunk)
        except Exception:
            # Best-effort cleanup if we crash mid-stream
            try: out_path.unlink(missing_ok=True)
            except Exception: pass
            raise
    finally:
        # Restore the original socket timeout so subsequent requests on the
        # same connection (rare but possible w/ keep-alive) aren't affected.
        if sock is not None:
            try: sock.settimeout(prev_timeout)
            except Exception: pass

    return {
        "filename": filename,
        "content_type": part_ctype,
        "path": out_path,
        "size": out_path.stat().st_size,
    }


def parse_multipart(body: bytes, content_type: str) -> list[dict]:
    """Minimal multipart/form-data parser. Returns list of parts with
    keys: name, filename, content_type, data."""
    m = re.search(r"boundary=([^;]+)", content_type, re.IGNORECASE)
    if not m:
        raise ValueError("multipart: no boundary in Content-Type")
    boundary = m.group(1).strip().strip('"')
    delim = b"--" + boundary.encode()
    parts: list[dict] = []
    chunks = body.split(delim)
    # first chunk is preamble (often empty); last is "--" + epilogue
    for chunk in chunks[1:]:
        chunk = chunk.lstrip(b"\r\n")
        if chunk.startswith(b"--"):
            break  # closing boundary
        chunk = chunk.rstrip(b"\r\n")
        if not chunk:
            continue
        hdr, sep, data = chunk.partition(b"\r\n\r\n")
        if not sep:
            continue
        disp = ""
        ctype = ""
        for hline in hdr.decode("utf-8", errors="replace").split("\r\n"):
            low = hline.lower()
            if low.startswith("content-disposition:"):
                disp = hline.split(":", 1)[1].strip()
            elif low.startswith("content-type:"):
                ctype = hline.split(":", 1)[1].strip()
        name_m = re.search(r'name="([^"]+)"', disp)
        fn_m = re.search(r'filename="([^"]*)"', disp)
        parts.append({
            "name": name_m.group(1) if name_m else None,
            "filename": fn_m.group(1) if fn_m and fn_m.group(1) else None,
            "content_type": ctype,
            "data": data.rstrip(b"\r\n"),
        })
    return parts


# -------------------------- HTTP handler --------------------------

# -------------------------- jobs subsystem --------------------------
#
# Async transcription pattern. POST /transcribe (multipart) returns 202 +
# job_id immediately; a background worker thread runs ffmpeg + whisper-cli
# while the client polls GET /jobs/<id>. Job state is JSON on disk so it
# survives server restarts (running jobs are flipped to 'interrupted' on
# startup since whisper-cli has no resume).
#
# Concurrency: a single global Lock serializes whisper invocations because
# the model load is heavy (~30s for large-v3, ~10s for turbo). Other jobs
# wait their turn. Cancellation kills the active subprocess.
#
# Layout under JOBS_DIR (~/Library/Application Support/yt-transcript/jobs/):
#   <id>.json     — metadata + status + final text
#   <id>.<ext>    — the uploaded file
#   <id>.partial  — whisper-cli stdout stream, parsed for progress

JOB_RUN_LOCK = threading.Lock()
JOB_STATE_LOCK = threading.Lock()
ACTIVE_JOB_ID: str | None = None
ACTIVE_PROC: subprocess.Popen | None = None
CANCELLED_IDS: set[str] = set()
JOB_ID_RE = re.compile(r"^[a-f0-9]{6,32}$")

WHISPER_TIMESTAMP_RE = re.compile(
    r"-->\s*(\d{2}):(\d{2}):(\d{2})[\.,](\d{3})"
)
WHISPER_SEGMENT_RE = re.compile(
    r"\[\s*\d{2}:\d{2}:\d{2}[\.,]\d{3}\s*-->\s*\d{2}:\d{2}:\d{2}[\.,]\d{3}\s*\]\s*(.*)"
)


def _ffprobe_bin() -> str | None:
    if not FFMPEG_BIN:
        return None
    cand = FFMPEG_BIN.replace("ffmpeg", "ffprobe")
    return cand if Path(cand).is_file() else None


def _job_path(job_id: str, ext: str = ".json") -> Path:
    return JOBS_DIR / f"{job_id}{ext}"


def _read_job(job_id: str) -> dict | None:
    p = _job_path(job_id)
    if not p.is_file():
        return None
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def _write_job(job_id: str, data: dict) -> None:
    p = _job_path(job_id)
    tmp = p.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(data, indent=2), encoding="utf-8")
    tmp.replace(p)


def _update_job(job_id: str, **kwargs) -> dict | None:
    with JOB_STATE_LOCK:
        data = _read_job(job_id) or {}
        data.update(kwargs)
        _write_job(job_id, data)
        return data


def _job_summary(data: dict) -> dict:
    """Public-safe summary of a job (no full body for /jobs list view)."""
    return {
        "job_id": data.get("job_id"),
        "filename": data.get("filename"),
        "kind": data.get("kind"),
        "size": data.get("size"),
        "status": data.get("status"),
        "started_at": data.get("started_at"),
        "ended_at": data.get("ended_at"),
        "duration_s": data.get("duration_s"),
        "progress_pct": data.get("progress_pct", 0),
        "current_t_s": data.get("current_t_s"),
        "eta_s": data.get("eta_s"),
        "error": data.get("error"),
        "vault_path": data.get("vault_path"),
        "filename_saved": data.get("filename_saved"),
    }


def _extract_partial_text(partial_path: Path) -> str:
    """Pull spoken segments out of whisper-cli stdout."""
    if not partial_path.is_file():
        return ""
    out_lines: list[str] = []
    try:
        with partial_path.open("r", encoding="utf-8", errors="replace") as f:
            for line in f:
                m = WHISPER_SEGMENT_RE.search(line)
                if m:
                    s = m.group(1).strip()
                    if s:
                        out_lines.append(s)
    except OSError:
        return ""
    return "\n".join(out_lines)


def _was_cancelled(job_id: str) -> bool:
    with JOB_STATE_LOCK:
        return job_id in CANCELLED_IDS


def cancel_job(job_id: str) -> bool:
    """Cancel a queued or running job. Returns True if found and marked."""
    data = _read_job(job_id)
    if not data:
        return False
    with JOB_STATE_LOCK:
        CANCELLED_IDS.add(job_id)
        # If currently running, kill the subprocess
        if ACTIVE_JOB_ID == job_id and ACTIVE_PROC is not None:
            try:
                ACTIVE_PROC.terminate()
            except Exception:
                pass
    _update_job(job_id, status="cancelled", ended_at=int(time.time()))
    # Best-effort cleanup of upload + partial
    ext = data.get("ext") or ""
    try:
        _job_path(job_id, ext).unlink(missing_ok=True)
    except Exception:
        pass
    try:
        _job_path(job_id, ".partial").unlink(missing_ok=True)
    except Exception:
        pass
    return True


def enqueue_transcribe_job(
    src_path: Path,
    original_name: str,
    ext: str,
    kind: str,
    content_type: str = "",
    user_agent: str = "",
) -> str:
    """Save an upload into JOBS_DIR with a fresh ID, write metadata, spawn worker."""
    job_id = uuid.uuid4().hex[:12]
    final_path = _job_path(job_id, ext)
    # Move (or copy) the upload into the jobs dir under <id><ext>
    if src_path.resolve() != final_path.resolve():
        shutil.move(str(src_path), str(final_path))
    size = final_path.stat().st_size

    duration_s: float | None = None
    ffprobe = _ffprobe_bin()
    if ffprobe and kind in ("audio", "video"):
        try:
            ffp = subprocess.run(
                [ffprobe, "-v", "error",
                 "-show_entries", "format=duration",
                 "-of", "default=noprint_wrappers=1:nokey=1",
                 str(final_path)],
                capture_output=True, timeout=30, shell=False,
            )
            if ffp.returncode == 0:
                txt = ffp.stdout.decode().strip()
                if txt:
                    duration_s = float(txt)
        except Exception:
            duration_s = None

    _write_job(job_id, {
        "job_id": job_id,
        "filename": original_name,
        "ext": ext,
        "kind": kind,
        "size": size,
        "duration_s": duration_s,
        "status": "queued",
        "progress_pct": 0,
        "started_at": int(time.time()),
        "content_type": content_type,
        "user_agent": user_agent[:140],
    })

    log(f"JOB-ENQUEUE  {job_id}  kind={kind}  size={size}  duration={duration_s}  name={original_name!r}")

    t = threading.Thread(target=_run_job, args=(job_id,), daemon=True,
                         name=f"job-{job_id}")
    t.start()
    return job_id


def _run_job(job_id: str) -> None:
    """Worker entrypoint. Waits for the global whisper lock, then runs."""
    global ACTIVE_JOB_ID, ACTIVE_PROC
    if _was_cancelled(job_id):
        log(f"JOB-CANCELLED {job_id} before start"); return

    try:
        with JOB_RUN_LOCK:
            if _was_cancelled(job_id):
                log(f"JOB-CANCELLED {job_id} while queued")
                return
            data = _read_job(job_id)
            if not data:
                return
            _update_job(job_id, status="running", run_started=int(time.time()))
            log(f"JOB-RUN     {job_id}")
            try:
                if data.get("kind") in ("audio", "video"):
                    text = _job_run_whisper(job_id, data)
                else:
                    # non-AV kinds aren't routed through jobs in this build,
                    # but support them for completeness.
                    text = _job_run_passthrough(job_id, data)
            except subprocess.TimeoutExpired:
                _update_job(job_id, status="error", error="timeout",
                            ended_at=int(time.time()))
                log(f"JOB-TIMEOUT {job_id}")
                return
            except Exception as e:
                _update_job(job_id, status="error", error=str(e),
                            ended_at=int(time.time()))
                log(f"JOB-ERROR   {job_id}  {e}")
                return

            saved = _save_transcript(
                text, data["filename"],
                source=f"{data.get('kind','file')}: {data['filename']}",
                kind=data.get("kind", "file"),
                language="auto",
            )
            _update_job(
                job_id,
                status="done",
                progress_pct=100,
                ended_at=int(time.time()),
                vault_path=saved["saved_to"],
                filename_saved=saved["filename"],
                text=saved["text"],
            )
            log(f"JOB-DONE    {job_id}  → {saved['filename']}")
    finally:
        # Drop cancel flag once job is finalized (in any terminal state).
        with JOB_STATE_LOCK:
            CANCELLED_IDS.discard(job_id)
            if ACTIVE_JOB_ID == job_id:
                ACTIVE_JOB_ID = None
                ACTIVE_PROC = None


def _job_run_whisper(job_id: str, data: dict) -> str:
    """ffmpeg → whisper-cli with stdout streamed to <id>.partial for progress."""
    global ACTIVE_JOB_ID, ACTIVE_PROC

    if not WHISPER_BIN or not WHISPER_MODEL_FILE or not FFMPEG_BIN:
        raise RuntimeError("Whisper not installed — run install-whisper.command")
    if not Path(WHISPER_MODEL_FILE).is_file():
        raise RuntimeError(f"whisper model file missing: {WHISPER_MODEL_FILE}")

    src = _job_path(job_id, data["ext"])
    if not src.is_file():
        raise RuntimeError(f"upload missing for job {job_id}")
    duration_s = data.get("duration_s")

    partial = _job_path(job_id, ".partial")
    partial.write_text("", encoding="utf-8")  # truncate

    with tempfile.TemporaryDirectory(prefix="ytwh-", dir=str(JOBS_TMP_DIR)) as tmp:
        wav = Path(tmp) / "audio.wav"
        log(f"JOB-FFMPEG  {job_id}  {src.name} → 16kHz mono wav")
        ff = subprocess.run(
            [FFMPEG_BIN, "-y", "-loglevel", "error",
             "-i", str(src),
             "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le",
             str(wav)],
            capture_output=True, timeout=FFMPEG_TIMEOUT_S, shell=False,
        )
        if _was_cancelled(job_id):
            raise RuntimeError("cancelled")
        if ff.returncode != 0:
            raise RuntimeError(f"ffmpeg: {ff.stderr.decode(errors='replace')[-500:]}")

        out_base = Path(tmp) / "transcript"
        log(f"JOB-WHISPER {job_id}  model={Path(WHISPER_MODEL_FILE).name}")
        run_started = time.time()
        proc = subprocess.Popen(
            [WHISPER_BIN,
             "-m", WHISPER_MODEL_FILE,
             "-f", str(wav),
             "-otxt",
             "-of", str(out_base),
             "-l", "auto"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            shell=False, bufsize=1,
        )

        with JOB_STATE_LOCK:
            ACTIVE_JOB_ID = job_id
            ACTIVE_PROC = proc

        try:
            with partial.open("a", encoding="utf-8") as pf:
                # whisper-cli with -otxt prints segments to stdout in form:
                #   [00:00:00.000 --> 00:00:02.500]   transcribed text
                # We tee these to <id>.partial and update progress as we go.
                while True:
                    raw = proc.stdout.readline()
                    if not raw:
                        break
                    line = raw.decode("utf-8", errors="replace")
                    pf.write(line)
                    pf.flush()
                    m = WHISPER_TIMESTAMP_RE.search(line)
                    if m and duration_s and duration_s > 0:
                        h, mm, ss, ms = (int(g) for g in m.groups())
                        cur = h * 3600 + mm * 60 + ss + ms / 1000
                        pct = max(0, min(99, int(cur / duration_s * 100)))
                        elapsed = max(1.0, time.time() - run_started)
                        eta = max(0, int((duration_s - cur) * (elapsed / cur))) if cur > 0 else None
                        _update_job(job_id, progress_pct=pct,
                                    current_t_s=round(cur, 1),
                                    eta_s=eta)
                rc = proc.wait()
        finally:
            with JOB_STATE_LOCK:
                ACTIVE_PROC = None

        if _was_cancelled(job_id):
            raise RuntimeError("cancelled")
        if rc != 0:
            err = proc.stderr.read().decode(errors="replace")[-500:] if proc.stderr else ""
            raise RuntimeError(f"whisper rc={rc}: {err}")

        # whisper-cli writes <out_base>.txt
        txt = Path(str(out_base) + ".txt")
        if not txt.is_file():
            txt = out_base.with_suffix(".txt")
        if not txt.is_file():
            raise RuntimeError("whisper produced no .txt output")
        return txt.read_text(encoding="utf-8", errors="replace")


def _job_run_passthrough(job_id: str, data: dict) -> str:
    """Fallback for non-audio/video kinds enqueued through the job system."""
    src = _job_path(job_id, data["ext"])
    return src.read_text(encoding="utf-8", errors="replace")


def get_job_view(job_id: str) -> dict | None:
    """Composite view including partial_text if running."""
    data = _read_job(job_id)
    if not data:
        return None
    if data.get("status") == "running":
        data["partial_text"] = _extract_partial_text(_job_path(job_id, ".partial"))
    return data


def list_jobs(limit: int = 50) -> list[dict]:
    items: list[dict] = []
    if not JOBS_DIR.is_dir():
        return items
    for p in JOBS_DIR.glob("*.json"):
        try:
            data = json.loads(p.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        items.append(_job_summary(data))
    items.sort(key=lambda j: j.get("started_at") or 0, reverse=True)
    return items[:limit]


def jobs_startup_sweep() -> None:
    """Mark interrupted, prune old. Called once at server start."""
    JOBS_DIR.mkdir(parents=True, exist_ok=True)
    JOBS_TMP_DIR.mkdir(parents=True, exist_ok=True)
    cutoff = time.time() - JOB_PRUNE_DAYS * 86400
    interrupted = 0
    pruned = 0
    for p in list(JOBS_DIR.glob("*.json")):
        try:
            data = json.loads(p.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        started = data.get("started_at") or 0
        if started < cutoff:
            jid = data.get("job_id") or p.stem
            for sib in JOBS_DIR.glob(f"{jid}.*"):
                try: sib.unlink()
                except OSError: pass
            pruned += 1
            continue
        if data.get("status") in ("queued", "running"):
            data["status"] = "interrupted"
            data["ended_at"] = int(time.time())
            try:
                p.write_text(json.dumps(data, indent=2), encoding="utf-8")
                interrupted += 1
            except OSError:
                pass
    if interrupted or pruned:
        log(f"JOBS-SWEEP  interrupted={interrupted}  pruned_old={pruned}")


# -------------------------- HTTP handler --------------------------

class Handler(BaseHTTPRequestHandler):
    server_version = "yt-transcript/3.0"

    def log_message(self, fmt, *args):
        pass  # silence default logger

    # ---- response helpers ----
    def _send(self, status: int, body: bytes, ctype: str,
              extra: dict | None = None):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _send_json(self, status: int, payload):
        self._send(status, json.dumps(payload).encode("utf-8"), "application/json")

    # ---- routing ----
    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/recent":         return self._serve_recent()
        if path.startswith("/vault/"): return self._serve_vault_file(
            urllib.parse.unquote(path[len("/vault/"):]))
        if path == "/health":         return self._send_json(200, {"ok": True,
                                                                   "whisper": bool(WHISPER_BIN),
                                                                   "model": (Path(WHISPER_MODEL_FILE).name
                                                                             if WHISPER_MODEL_FILE else None)})
        if path == "/jobs":           return self._send_json(200, list_jobs())
        if path.startswith("/jobs/"):
            return self._handle_get_job(urllib.parse.unquote(path[len("/jobs/"):]))

        entry = STATIC_FILES.get(path)
        if not entry:
            self._send(404, b"not found", "text/plain; charset=utf-8")
            return
        fname, ctype = entry
        fpath = APP_DIR / fname
        if not fpath.exists():
            self._send(404, f"{fname} missing".encode(), "text/plain; charset=utf-8")
            return
        self._send(200, fpath.read_bytes(), ctype)

    def do_DELETE(self):
        path = urllib.parse.urlparse(self.path).path
        if path.startswith("/jobs/"):
            return self._handle_delete_job(urllib.parse.unquote(path[len("/jobs/"):]))
        self._send_json(404, {"error": "not found"})

    def _handle_get_job(self, job_id: str):
        if not JOB_ID_RE.match(job_id):
            self._send_json(400, {"error": "bad job id"}); return
        view = get_job_view(job_id)
        if not view:
            self._send_json(404, {"error": "not found"}); return
        self._send_json(200, view)

    def _handle_delete_job(self, job_id: str):
        if not JOB_ID_RE.match(job_id):
            self._send_json(400, {"error": "bad job id"}); return
        if cancel_job(job_id):
            log(f"JOB-CANCEL  {job_id}  by client")
            self._send_json(200, {"ok": True, "job_id": job_id, "status": "cancelled"})
        else:
            self._send_json(404, {"error": "not found"})

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/fetch":      return self._handle_fetch()
        if path == "/transcribe": return self._handle_transcribe()
        self._send_json(404, {"error": "not found"})

    # ---- /recent + /vault ----
    def _serve_recent(self):
        items = []
        if INBOX_DIR.is_dir():
            files = [p for p in INBOX_DIR.iterdir() if p.is_file() and p.suffix == ".txt"]
            files.sort(key=lambda p: p.stat().st_mtime, reverse=True)
            for p in files[:25]:
                st = p.stat()
                items.append({"name": p.name, "size": st.st_size, "mtime": int(st.st_mtime)})
        self._send_json(200, items)

    def _serve_vault_file(self, name: str):
        if not name or "/" in name or "\\" in name or name.startswith("."):
            self._send_json(400, {"error": "invalid filename"}); return
        target = (INBOX_DIR / name).resolve()
        try:
            target.relative_to(INBOX_DIR.resolve())
        except ValueError:
            self._send_json(400, {"error": "path escapes inbox"}); return
        if not target.is_file():
            self._send_json(404, {"error": "not found"}); return
        self._send(200, target.read_bytes(), "text/plain; charset=utf-8")

    # ---- /fetch (YouTube) with Whisper fallback ----
    def _handle_fetch(self):
        length = int(self.headers.get("Content-Length", "0") or 0)
        if length <= 0 or length > 4096:
            self._send_json(400, {"error": "missing or oversized body"}); return
        try:
            payload = json.loads(self.rfile.read(length))
            url = (payload.get("url") or "").strip()
        except (json.JSONDecodeError, UnicodeDecodeError):
            self._send_json(400, {"error": "invalid JSON"}); return
        if not url or not YOUTUBE_RE.match(url):
            log(f"REJECT  not a YouTube URL: {url!r}")
            self._send_json(400, {"error": "not a YouTube URL"}); return
        if not FETCH_SH.exists():
            self._send_json(500, {"error": f"fetch.sh missing at {FETCH_SH}"}); return

        log(f"FETCH   {url}")
        try:
            result = subprocess.run(
                [str(FETCH_SH), url],
                shell=False, capture_output=True, text=True, timeout=180,
            )
        except subprocess.TimeoutExpired:
            log(f"TIMEOUT {url}"); self._send_json(504, {"error": "fetch timed out after 180s"}); return

        # Whisper fallback for no-captions.
        if result.returncode == 3:
            if WHISPER_BIN and WHISPER_MODEL_FILE and FFMPEG_BIN and Path(WHISPER_MODEL_FILE).is_file():
                try:
                    wresult = whisper_youtube_fallback(url)
                    log(f"OK      whisper-fallback for {url}")
                    self._send_json(200, wresult); return
                except Exception as e:
                    log(f"FAIL    whisper-fallback: {e}")
            log(f"NO-SUBS {url}")
            self._send_json(422, {"error": "no subtitles available",
                                  "hint": "install Whisper to enable audio fallback (run install-whisper.command)"})
            return

        if result.returncode == 4:
            log(f"RATELMT {url}")
            self._send_json(429, {"error": "YouTube is rate-limiting this Mac",
                                  "hint": "wait 5–15 min, or `brew upgrade yt-dlp`"})
            return

        if result.returncode == 5:
            log(f"PRIVATE {url}")
            self._send_json(403, {"error": "video is private or requires sign-in"}); return

        if result.returncode != 0:
            log(f"FAIL    rc={result.returncode}  {url}\n        stderr={result.stderr.strip()[:400]}")
            self._send_json(500, {"error": "fetch.sh failed", "detail": result.stderr.strip()[-400:]}); return

        paths = [p for p in result.stdout.strip().splitlines() if p.strip()]
        if not paths:
            self._send_json(500, {"error": "fetch.sh produced no output"}); return
        out_path = Path(paths[0])
        if not out_path.exists():
            self._send_json(500, {"error": "transcript file not found"}); return
        body = out_path.read_bytes()
        log(f"OK      {out_path.name}  ({len(body)} bytes)  also: {len(paths)-1} more lang(s)")
        self._send_json(200, {
            "filename": out_path.name,
            "saved_to": str(out_path),
            "also_saved": paths[1:],
            "text": body.decode("utf-8", errors="replace"),
        })

    # ---- /transcribe (universal, async for files) ----
    def _handle_transcribe(self):
        ctype = self.headers.get("Content-Type", "") or ""
        length_str = self.headers.get("Content-Length", "")
        try:
            length = int(length_str) if length_str else 0
        except ValueError:
            length = 0
        te = (self.headers.get("Transfer-Encoding") or "").lower()
        ua = self.headers.get("User-Agent", "")[:140]

        # Always log the entry so failed uploads leave a trace, even when the
        # body never arrives.
        log(f"TRANSCRIBE-IN  ct={ctype.split(';')[0]!r}  len={length}  te={te!r}  ua={ua[:80]!r}")

        if length <= 0 and "chunked" not in te:
            log("TRANSCRIBE-FAIL  empty body (no Content-Length, no chunked)")
            self._send_json(400, {"error": "empty body — Content-Length missing"}); return
        if length > MAX_UPLOAD_BYTES:
            log(f"TRANSCRIBE-FAIL  oversize {length} > {MAX_UPLOAD_BYTES}")
            gb = MAX_UPLOAD_BYTES / (1024 ** 3)
            self._send_json(413, {"error": f"max upload is {gb:.1f} GB"}); return

        # JSON URL: keep synchronous (web/PDF fetches are quick).
        if ctype.startswith("application/json"):
            try:
                if length > 0:
                    body = self.rfile.read(length)
                else:
                    body = self.rfile.read()
            except (ConnectionResetError, BrokenPipeError, TimeoutError) as e:
                log(f"TRANSCRIBE-FAIL  body read error: {e}")
                self._send_json(400, {"error": f"upload interrupted: {e}"}); return
            try:
                payload = json.loads(body)
                url = (payload.get("url") or "").strip()
            except Exception:
                self._send_json(400, {"error": "invalid JSON"}); return
            if not url or not URL_RE.match(url):
                self._send_json(400, {"error": "missing or invalid url"}); return
            log(f"TRANSCRIBE url: {url}")
            try:
                if YOUTUBE_RE.match(url):
                    return self._do_youtube_via_transcribe(url)
                result = transcribe_url(url)
            except Exception as e:
                log(f"FAIL    url: {e}")
                self._send_json(500, {"error": str(e)}); return
            self._send_json(200, result); return

        # Multipart: file upload → async job.
        if ctype.startswith("multipart/form-data"):
            try:
                file_info = stream_multipart_to_disk(
                    rfile=self.rfile,
                    length=length,
                    content_type=ctype,
                    dest_dir=JOBS_TMP_DIR,
                    max_bytes=MAX_UPLOAD_BYTES,
                    socket_obj=getattr(self, "connection", None),
                    recv_timeout=60.0,
                )
            except (ConnectionResetError, BrokenPipeError, TimeoutError) as e:
                log(f"TRANSCRIBE-FAIL  body read error: {e}")
                self._send_json(400, {"error": f"upload interrupted: {e}"}); return
            except ValueError as e:
                log(f"TRANSCRIBE-FAIL  multipart: {e}")
                self._send_json(400, {"error": f"multipart: {e}"}); return

            original_name = file_info["filename"]
            tmp_path = file_info["path"]
            suffix = Path(original_name).suffix.lower()
            # iOS sometimes uploads with no extension; sniff from content type.
            if not suffix and file_info.get("content_type"):
                pct = file_info["content_type"].lower()
                if "mp4" in pct: suffix = ".m4a"
                elif "mpeg" in pct: suffix = ".mp3"
                elif "wav" in pct: suffix = ".wav"
                elif "webm" in pct: suffix = ".webm"
                elif "ogg" in pct: suffix = ".ogg"
                elif "flac" in pct: suffix = ".flac"
                elif "aac" in pct: suffix = ".m4a"
                if suffix:
                    new_path = tmp_path.with_suffix(suffix)
                    tmp_path.rename(new_path)
                    tmp_path = new_path
                    log(f"TRANSCRIBE-IN  inferred ext {suffix} from content-type {pct!r}")

            log(f"TRANSCRIBE file: {original_name} ({tmp_path.stat().st_size} bytes, ext={suffix or '?'})")

            kind: str
            if suffix in AUDIO_EXTS:
                kind = "audio"
            elif suffix in VIDEO_EXTS:
                kind = "video"
            elif suffix in PDF_EXTS:
                kind = "pdf"
            elif suffix in DOC_EXTS:
                kind = "doc"
            elif suffix in HTML_EXTS:
                kind = "html"
            elif suffix in TEXT_EXTS:
                kind = "text"
            elif suffix in SUB_EXTS:
                kind = "subs"
            else:
                tmp_path.unlink(missing_ok=True)
                self._send_json(415, {
                    "error": f"unsupported format: {suffix or '(no extension)'}",
                    "supported_extensions": sorted(ALL_EXTS),
                }); return

            # Audio/video → async job. Other kinds are fast → run synchronously.
            if kind in ("audio", "video"):
                try:
                    job_id = enqueue_transcribe_job(
                        src_path=tmp_path,
                        original_name=original_name,
                        ext=suffix,
                        kind=kind,
                        content_type=file_info.get("content_type", ""),
                        user_agent=ua,
                    )
                except Exception as e:
                    log(f"TRANSCRIBE-FAIL  enqueue: {e}")
                    self._send_json(500, {"error": str(e)}); return
                self._send_json(202, {
                    "job_id": job_id,
                    "status": "queued",
                    "status_url": f"/jobs/{job_id}",
                }); return

            # Synchronous path for fast kinds.
            try:
                if kind == "pdf":
                    result = transcribe_pdf(tmp_path, original_name)
                elif kind == "doc":
                    result = transcribe_pandoc(tmp_path, original_name)
                elif kind == "html":
                    result = transcribe_html_bytes(tmp_path.read_bytes(),
                                                   original_name,
                                                   source=f"file: {original_name}")
                elif kind == "text":
                    result = transcribe_text_bytes(tmp_path.read_bytes(), original_name)
                elif kind == "subs":
                    result = transcribe_subs_bytes(tmp_path.read_bytes(), original_name)
            except Exception as e:
                log(f"FAIL    file: {e}")
                self._send_json(500, {"error": str(e)}); return
            finally:
                tmp_path.unlink(missing_ok=True)
            log(f"OK      {result['filename']}")
            self._send_json(200, result); return

        self._send_json(400, {"error": f"unsupported Content-Type: {ctype}"})

    def _do_youtube_via_transcribe(self, url: str):
        """Bridge /transcribe(JSON URL) → /fetch behavior for YouTube URLs."""
        # Build a synthetic /fetch call internally.
        fake_body = json.dumps({"url": url}).encode("utf-8")

        class FakeRfile:
            def __init__(self, b): self.b = b
            def read(self, n): out = self.b[:n]; self.b = self.b[n:]; return out

        # Route through the same handler logic — easiest: reuse subprocess directly.
        try:
            result = subprocess.run(
                [str(FETCH_SH), url],
                shell=False, capture_output=True, text=True, timeout=180,
            )
        except subprocess.TimeoutExpired:
            self._send_json(504, {"error": "fetch timed out"}); return

        if result.returncode == 3:
            if WHISPER_BIN and WHISPER_MODEL_FILE and FFMPEG_BIN and Path(WHISPER_MODEL_FILE).is_file():
                try:
                    self._send_json(200, whisper_youtube_fallback(url)); return
                except Exception as e:
                    self._send_json(500, {"error": f"whisper fallback failed: {e}"}); return
            self._send_json(422, {"error": "no subtitles available",
                                  "hint": "install Whisper to enable audio fallback"}); return
        if result.returncode != 0:
            self._send_json(500, {"error": "fetch.sh failed",
                                  "detail": result.stderr.strip()[-400:]}); return

        paths = [p for p in result.stdout.strip().splitlines() if p.strip()]
        if not paths:
            self._send_json(500, {"error": "no output"}); return
        out_path = Path(paths[0])
        body = out_path.read_bytes()
        self._send_json(200, {
            "filename": out_path.name,
            "saved_to": str(out_path),
            "also_saved": paths[1:],
            "text": body.decode("utf-8", errors="replace"),
        })


# -------------------------- main --------------------------

def main():
    if not FETCH_SH.exists():
        print(f"warning: fetch.sh not found at {FETCH_SH}", file=sys.stderr)
    if not WHISPER_BIN or not Path(WHISPER_MODEL_FILE or "").is_file():
        print(f"info: Whisper not yet configured (run install-whisper.command)", file=sys.stderr)
    # Reconcile any jobs that were running when we last died, prune old ones,
    # and prepare the on-disk staging area.
    try:
        jobs_startup_sweep()
    except Exception as e:
        log(f"JOBS-SWEEP-ERR  {e}")
    model_name = Path(WHISPER_MODEL_FILE).name if WHISPER_MODEL_FILE else "none"

    # We bind on TWO addresses:
    #   1. HOST (100.121.62.15) -- the Tailscale interface, for direct tailnet
    #      device access (iPhone/iMac/etc).
    #   2. 127.0.0.1 -- loopback, for tailscaled's `tailscale serve` HTTPS
    #      proxy hop. Pointing tailscale serve at the Tailscale IP causes a
    #      self-proxy loop through wireguard; pointing at 127.0.0.1 is the
    #      idiomatic pattern. Both binds together close that loophole.
    # 127.0.0.1 is local-only — not externally reachable.
    log(f"START   binding {HOST}:{PORT} + 127.0.0.1:{PORT}  "
        f"whisper={'yes' if WHISPER_BIN else 'no'}  model={model_name}  "
        f"jobs={len(list(JOBS_DIR.glob('*.json'))) if JOBS_DIR.is_dir() else 0}")
    try:
        srv_ts = ThreadingHTTPServer((HOST, PORT), Handler)
    except OSError as e:
        print(f"failed to bind {HOST}:{PORT} -- {e}", file=sys.stderr)
        sys.exit(1)
    try:
        srv_lo = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    except OSError as e:
        # Loopback bind is best-effort -- if it fails (port held by something
        # else on 127.0.0.1) keep the Tailscale listener running, but log so
        # the operator knows tailscale serve will not work.
        log(f"WARN    127.0.0.1:{PORT} bind failed: {e} -- tailscale-serve HTTPS may not proxy")
        srv_lo = None

    if srv_lo is not None:
        threading.Thread(target=srv_lo.serve_forever,
                         name="http-loopback",
                         daemon=True).start()
    try:
        srv_ts.serve_forever()
    except KeyboardInterrupt:
        log("STOP    keyboard interrupt")


if __name__ == "__main__":
    main()
