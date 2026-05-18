#!/usr/bin/env python3
"""NeXiS Controller — Build 1.0.33"""

import os, sys, json, sqlite3, threading, signal, re, base64, queue as _queue
import socket as _socket, subprocess, urllib.request, urllib.parse

_vnc_sessions = {}   # device_id -> {'ws_port': int, 'proc': subprocess.Popen}
_vnc_lock     = threading.Lock()
import shutil, mimetypes, io, wave, tempfile, time, hashlib, secrets, difflib, ssl
import math, struct, uuid, platform
from datetime import datetime
from pathlib import Path
