#!/usr/bin/env python3
"""NeXiS Controller — Build 1.0.0"""

import os, sys, json, sqlite3, threading, signal, re, base64, queue as _queue
import socket as _socket, subprocess, urllib.request, urllib.parse, time, secrets
import tempfile, struct, hashlib, hmac, copy, traceback
from datetime import datetime
from urllib.parse import urlparse, parse_qs
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer as TS
from pathlib import Path