#!/usr/bin/env python3
"""NeXiS Controller — Build 1.0.0"""

import os, sys, json, sqlite3, threading, signal, re, base64, queue as _queue
import socket as _socket, subprocess, urllib.request, urllib.parse
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
