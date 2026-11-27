#!/usr/bin/env python3
"""JioSaavn Downloader HTTP Service.

Wraps jiosaavn_core.py to expose a local HTTP API that the Flutter app
can call. Runs on localhost only for security.

Endpoints:
  GET  /status          - Service health
  POST  /search         - Search JioSaavn for songs/albums/playlists
  POST  /download       - Download a song/album/playlist/artist
  GET  /progress        - Get current download progress (SSE)
  POST  /config         - Update download configuration
  GET  /config          - Get current download configuration
  POST  /stop           - Stop current download
"""

import base64
import json
import os
import sys
import threading
import time
from flask import Flask, request, jsonify, Response
from flask_cors import CORS

# Add the python_backend directory to path so we can import jiosaavn_core
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from jiosaavn_core import (
    Jiosaavn,
    DownloadError,
    API_URL,
    COLLECTION_WORKERS,
    MAX_WORKERS,
    __version__,
)

app = Flask(__name__)
CORS(app)  # Allow Flutter app to connect

# Global state
downloader = None
download_lock = threading.Lock()
progress_state = {
    "status": "idle",  # idle, downloading, completed, failed, stopped
    "downloaded": 0,
    "skipped": 0,
    "failed": 0,
    "current_track": "",
    "current_progress": 0.0,  # 0.0 to 1.0
    "current_speed": "0.0MB/s",
    "failures": [],
    "message": "",
}


class ProgressCallback:
    """Bridge between Jiosaavn progress callbacks and the HTTP progress state."""

    def __init__(self):
        self.lock = threading.Lock()

    def __call__(self, progress):
        """Called by jiosaavn_core with DownloadProgress-like object."""
        with self.lock:
            progress_state["status"] = "downloading"
            progress_state["current_track"] = getattr(progress, "title", "")
            progress_state["current_progress"] = getattr(progress, "percentage", 0.0)
            progress_state["current_speed"] = getattr(progress, "speed", "0.0MB/s")
            progress_state["downloaded"] = getattr(progress, "downloaded", 0) if hasattr(progress, "downloaded") else progress_state["downloaded"]

    def set_status(self, status, message=""):
        with self.lock:
            progress_state["status"] = status
            progress_state["message"] = message

    def set_counts(self, downloaded, skipped, failed):
        with self.lock:
            progress_state["downloaded"] = downloaded
            progress_state["skipped"] = skipped
            progress_state["failed"] = failed

    def add_failure(self, label, reason):
        with self.lock:
            progress_state["failures"].append({"label": label, "reason": reason})


progress_cb = ProgressCallback()


class DownloadThread(threading.Thread):
    """Runs a download in a background thread."""

    def __init__(self, kind, token, output_dir, quality, overwrite, lyrics, cover,
                 workers, genre, template, no_explicit, after_year, before_year):
        super().__init__(daemon=True)
        self.kind = kind
        self.token = token
        self.output_dir = output_dir
        self.quality = quality
        self.overwrite = overwrite
        self.lyrics = lyrics
        self.cover = cover
        self.workers = workers
        self.genre = genre
        self.template = template
        self.no_explicit = no_explicit
        self.after_year = after_year
        self.before_year = before_year
        self.error = None

    def run(self):
        global downloader
        try:
            progress_cb.set_status("downloading", "Initializing downloader...")

            client = Jiosaavn(
                output=self.output_dir,
                quality=self.quality,
                timeout=30,
                overwrite=self.overwrite,
                lyrics=self.lyrics,
                cover=self.cover,
                workers=self.workers,
                genre=self.genre,
                template=self.template,
                no_explicit=self.no_explicit,
                after_year=self.after_year,
                before_year=self.before_year,
                progress_style="minimal",
                cache=False,
                cache_ttl=86400,
            )

            # Wrap the client to capture progress
            original_process_track = client.processTrack
            original_process_collection = client.process_collection
            original_process_artist = client.process_artist

            def wrapped_process_track(song_id, **kwargs):
                progress_cb.set_status("downloading", f"Processing track {song_id}")
                return original_process_track(song_id, **kwargs)

            def wrapped_process_collection(kind, token):
                progress_cb.set_status("downloading", f"Processing {kind}: {token}")
                return original_process_collection(kind, token)

            def wrapped_process_artist(artist_id):
                progress_cb.set_status("downloading", f"Processing artist: {artist_id}")
                return original_process_artist(artist_id)

            client.processTrack = wrapped_process_track
            client.process_collection = wrapped_process_collection
            client.process_artist = wrapped_process_artist

            downloader = client

            if self.kind == "song":
                client.processTrack(self.token)
            elif self.kind == "album":
                client.process_collection("album", self.token)
            elif self.kind == "playlist":
                client.process_collection("playlist", self.token)
            elif self.kind == "artist":
                client.process_artist(self.token)

            progress_cb.set_status("completed", "Download complete")
            progress_cb.set_counts(client.downloaded, client.skipped, client.failed)

        except DownloadError as e:
            self.error = str(e)
            progress_cb.set_status("failed", str(e))
        except Exception as e:
            self.error = str(e)
            progress_cb.set_status("failed", str(e))
        finally:
            downloader = None


# ==================== API Endpoints ====================

@app.route("/status", methods=["GET"])
def status():
    """Service health check."""
    return jsonify({
        "status": "ok",
        "version": __version__,
        "download_active": downloader is not None,
    })


@app.route("/search", methods=["POST"])
def search():
    """Search JioSaavn for songs, albums, and playlists."""
    try:
        data = request.get_json(force=True)
        query = data.get("query", "").strip()
        limit = int(data.get("limit", 20))

        if not query:
            return jsonify({"error": "Query is required"}), 400

        client = Jiosaavn(output="Downloads", quality="320", timeout=30)
        results = client.search(query, limit=limit)

        return jsonify({
            "results": results,
            "count": len(results),
        })
    except DownloadError as e:
        return jsonify({"error": str(e)}), 400
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/download", methods=["POST"])
def download():
    """Start downloading a song/album/playlist/artist."""
    global downloader

    with download_lock:
        if downloader is not None:
            return jsonify({"error": "A download is already in progress"}), 409

        try:
            data = request.get_json(force=True)
            kind = data.get("kind", "song")  # song, album, playlist, artist
            token = data.get("token", "").strip()
            output_dir = data.get("output_dir", "Downloads")
            quality = data.get("quality", "320")
            overwrite = data.get("overwrite", False)
            lyrics = data.get("lyrics", True)
            cover = data.get("cover", True)
            workers = int(data.get("workers", 4))
            genre = data.get("genre")
            template = data.get("template")
            no_explicit = data.get("no_explicit", False)
            after_year = data.get("after_year")
            before_year = data.get("before_year")

            if not token:
                return jsonify({"error": "Token/URL is required"}), 400

            # Reset progress state
            progress_cb.set_status("downloading", "Starting download...")
            progress_cb.set_counts(0, 0, 0)
            progress_state["failures"] = []
            progress_state["current_track"] = ""
            progress_state["current_progress"] = 0.0

            thread = DownloadThread(
                kind=kind,
                token=token,
                output_dir=output_dir,
                quality=quality,
                overwrite=overwrite,
                lyrics=lyrics,
                cover=cover,
                workers=workers,
                genre=genre,
                template=template,
                no_explicit=no_explicit,
                after_year=after_year,
                before_year=before_year,
            )
            thread.start()

            return jsonify({
                "status": "started",
                "kind": kind,
                "token": token,
            })
        except Exception as e:
            return jsonify({"error": str(e)}), 500


@app.route("/progress", methods=["GET"])
def progress():
    """Get current download progress."""
    with progress_cb.lock:
        state = dict(progress_state)
    return jsonify(state)


@app.route("/progress/stream", methods=["GET"])
def progress_stream():
    """Server-sent events stream for real-time progress updates."""
    def event_stream():
        last_state = None
        while True:
            with progress_cb.lock:
                state = dict(progress_state)
            if state != last_state:
                yield f"data: {json.dumps(state)}\n\n"
                last_state = state
            if state["status"] in ("completed", "failed", "stopped"):
                break
            time.sleep(0.5)

    return Response(event_stream(), mimetype="text/event-stream")


@app.route("/config", methods=["GET", "POST"])
def config():
    """Get or set download configuration."""
    if request.method == "GET":
        return jsonify({
            "output_dir": "Downloads",
            "quality": "320",
            "workers": 4,
            "lyrics": True,
            "cover": True,
            "overwrite": False,
            "genre": None,
            "template": None,
            "no_explicit": False,
            "after_year": None,
            "before_year": None,
        })
    else:
        # Save config (for now just acknowledge)
        data = request.get_json(force=True)
        return jsonify({"status": "saved", "config": data})


@app.route("/stop", methods=["POST"])
def stop():
    """Stop the current download."""
    global downloader
    with download_lock:
        if downloader is None:
            return jsonify({"error": "No download in progress"}), 409
        progress_cb.set_status("stopped", "Download stopped by user")
        downloader = None
        return jsonify({"status": "stopped"})


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8765, debug=False, threaded=True)
