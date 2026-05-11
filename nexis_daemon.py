#!/usr/bin/env python3
"""NeXiS Controller — Build 1.0.22"""

import os, sys, json, sqlite3, threading, signal, re, base64, queue as _queue
import socket as _socket, subprocess, urllib.request, urllib.parse

_vnc_sessions = {}   # device_id -> {'ws_port': int, 'proc': subprocess.Popen}
_vnc_lock     = threading.Lock()
import shutil, mimetypes, io, wave, tempfile, time, hashlib, secrets, difflib, ssl
import math, struct, uuid, platform
from datetime import datetime
from pathlib import Path

HOME      = Path.home()
CONF      = HOME / '.config/nexis'
DATA      = HOME / '.local/share/nexis'
DB_PATH   = DATA / 'memory' / 'nexis.db'
SOCK_PATH = Path('/run/nexis/nexis.sock')
LOG_PATH  = DATA / 'logs' / 'daemon.log'
AUTH_FILE          = CONF / 'auth.json'
USERS_FILE         = CONF / 'users.json'
SCHED_FILE         = CONF / 'schedules.json'
DEV_PASSWORDS_FILE = CONF / 'device_passwords.json'
TLS_KEY    = CONF / 'server.key'
TLS_CERT   = CONF / 'server.crt'

(DATA / 'memory').mkdir(parents=True, exist_ok=True)
(DATA / 'logs').mkdir(exist_ok=True)
(DATA / 'state').mkdir(exist_ok=True)
(DATA / 'voice').mkdir(exist_ok=True)
CONF.mkdir(parents=True, exist_ok=True)
_CONTROLLER_DEVICE_ID = str(uuid.UUID(int=uuid.getnode()))

# Ensure PulseAudio/PipeWire is reachable (needed for audio I/O when running under systemd)
if 'XDG_RUNTIME_DIR' not in os.environ:
    _xdg = f'/run/user/{os.getuid()}'
    if Path(_xdg).exists():
        os.environ['XDG_RUNTIME_DIR'] = _xdg
if 'XDG_RUNTIME_DIR' in os.environ:
    if 'PULSE_RUNTIME_PATH' not in os.environ:
        os.environ['PULSE_RUNTIME_PATH'] = os.environ['XDG_RUNTIME_DIR'] + '/pulse'
    if 'PIPEWIRE_RUNTIME_DIR' not in os.environ:
        os.environ['PIPEWIRE_RUNTIME_DIR'] = os.environ['XDG_RUNTIME_DIR']

OLLAMA       = 'http://localhost:11434'
EXTERNAL_DOMAIN = 'nexis.toroag.ch'   # external hostname for TLS cert SAN
MODEL_FAST   = 'qwen2.5:14b'
MODEL_DEEP   = 'hf.co/mradermacher/Omega-Darker_The-Final-Directive-22B-GGUF:Q4_K_M'
MODEL_CODE   = 'qwen3-coder-next'
MODEL_VISION = 'moondream'
