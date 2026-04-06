#!/usr/bin/env python3
"""NeXiS Daemon v3.0"""

import os, sys, json, sqlite3, threading, signal, re, base64
import socket as _socket, subprocess, urllib.request, urllib.parse
import shutil, mimetypes
from datetime import datetime
from pathlib import Path

HOME      = Path.home()
CONF      = HOME / '.config/nexis'
DATA      = HOME / '.local/share/nexis'
DB_PATH   = DATA / 'memory' / 'nexis.db'
SOCK_PATH = Path('/run/nexis/nexis.sock')
LOG_PATH  = DATA / 'logs' / 'daemon.log'

(DATA / 'memory').mkdir(parents=True, exist_ok=True)
(DATA / 'logs').mkdir(exist_ok=True)
(DATA / 'state').mkdir(exist_ok=True)

OLLAMA     = 'http://localhost:11434'
MODEL_FAST   = 'qwen2.5:14b'
MODEL_DEEP   = 'hf.co/mradermacher/Omega-Darker_The-Final-Directive-22B-GGUF:Q5_K_M'
MODEL_VISION = 'qwen2.5vl:7b'  # vision-capable; fallback to llava if not installed
AVAILABLE  = []
_log_lock  = threading.Lock()

def _log(msg, lv='INFO'):
    ts = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    with _log_lock:
        with open(LOG_PATH, 'a') as f:
            f.write(f'[{ts}] [{lv}] {msg}\n')

def _refresh_models():
    global AVAILABLE
    try:
        with urllib.request.urlopen(f'{OLLAMA}/api/tags', timeout=5) as r:
            AVAILABLE = [m['name'] for m in json.loads(r.read()).get('models', [])]
        _log(f'Models: {AVAILABLE}')
    except Exception as e:
        _log(f'Model refresh: {e}', 'WARN')

def _model_ok(m):
    return any(m.split(':')[0] in x for x in AVAILABLE)

def _stream_chat(messages, model, temperature=0.75, num_ctx=4096,
                 on_token=None, images=None):
    msgs = list(messages)
    if images:
        for i in range(len(msgs)-1, -1, -1):
            if msgs[i].get('role') == 'user':
                msgs[i] = dict(msgs[i])
                msgs[i]['images'] = images
                break
    payload = json.dumps({
        'model': model, 'messages': msgs,
        'stream': True, 'keep_alive': '24h',
        'options': {'num_ctx': num_ctx, 'temperature': temperature, 'top_p': 0.9}
    }).encode()
    req = urllib.request.Request(f'{OLLAMA}/api/chat', data=payload,
        headers={'Content-Type': 'application/json'})
    full = ''
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            for line in r:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                token = obj.get('message', {}).get('content', '')
                if token:
                    full += token
                    if on_token:
                        on_token(token)
                if obj.get('done'):
                    break
    except Exception as e:
        _log(f'Stream ({model}): {e}', 'WARN')
        # non-streaming fallback
        try:
            payload2 = json.dumps({
                'model': model, 'messages': msgs, 'stream': False,
                'keep_alive': '24h',
                'options': {'num_ctx': num_ctx, 'temperature': temperature}
            }).encode()
            req2 = urllib.request.Request(f'{OLLAMA}/api/chat', data=payload2,
                headers={'Content-Type': 'application/json'})
            with urllib.request.urlopen(req2, timeout=180) as r2:
                full = json.loads(r2.read()).get('message', {}).get('content', '') or ''
                if full and on_token:
                    on_token(full)
        except Exception as e2:
            _log(f'Fallback ({model}): {e2}', 'WARN')
    return full

_REFUSALS = (
    "i can't assist", "i cannot assist", "i'm not able to",
    "i won't be able", "i will not", "as an ai, i",
    "i don't have the ability", "i'm unable to",
    "i cannot provide", "i can't help with that",
    "i'm not able to help",
)

def _cjk_ratio(text):
    """Return fraction of CJK characters in text."""
    if not text: return 0.0
    cjk = sum(1 for c in text if '\u4e00' <= c <= '\u9fff' or
              '\u3040' <= c <= '\u30ff' or '\uff00' <= c <= '\uffef')
    return cjk / len(text)

def _enforce_english(msgs):
    """Inject strong English-only instruction into system message."""
    msgs = list(msgs)
    eng = (
        'CRITICAL: Respond ONLY in English. Never use Chinese, Japanese, Korean, '
        'or any non-Latin script. If you find yourself writing non-English text, stop and rewrite in English. '
    )
    if msgs and msgs[0].get('role') == 'system':
        m = dict(msgs[0])
        if eng not in m.get('content',''):
            m['content'] = eng + '\n\n' + m['content']
        msgs[0] = m
    else:
        msgs.insert(0, {'role':'system','content': eng})
    return msgs

def _smart_chat(messages, temperature=0.75, num_ctx=16384,
                on_token=None, images=None, force_deep=False):
    # Images: use vision model if available, warn if not
    if images:
        if _model_ok(MODEL_VISION):
            msgs_v = _enforce_english(list(messages))
            buf_v = []
            result = _stream_chat(msgs_v, MODEL_VISION, temperature, num_ctx,
                                  lambda t: buf_v.append(t), images)
            if result.strip() and _cjk_ratio(result) < 0.05:
                if on_token:
                    for t in buf_v: on_token(t)
                return result, MODEL_VISION
        else:
            if on_token:
                on_token('[Vision model not installed. Run: ollama pull qwen2.5vl:7b]\n')
            images = None

    if force_deep and _model_ok(MODEL_DEEP):
        msgs_d = _enforce_english(list(messages))
        buf_d = []
        result = _stream_chat(msgs_d, MODEL_DEEP, temperature, num_ctx,
                              lambda t: buf_d.append(t), images)
        if result.strip():
            if on_token:
                for t in buf_d: on_token(t)
            return result, MODEL_DEEP

    if _model_ok(MODEL_FAST) and not force_deep:
        msgs_f = _enforce_english(list(messages))
        buf_f = []
        result = _stream_chat(msgs_f, MODEL_FAST, temperature, num_ctx,
                              lambda t: buf_f.append(t), images)
        # Check for refusal or Chinese output - if so, suppress and hand off to deep
        refused = any(p in result.lower()[:300] for p in _REFUSALS)
        cjk_heavy = _cjk_ratio(result) > 0.05
        if result.strip() and not refused and not cjk_heavy:
            if on_token:
                for t in buf_f: on_token(t)
            return result, MODEL_FAST
        _log(f'Fast {"refused" if refused else "switched to Chinese" if cjk_heavy else "empty"} — handing off to deep', 'INFO')

    if _model_ok(MODEL_DEEP):
        msgs_d = _enforce_english(list(messages))
        # Inject anti-narrative reminder as final user turn for Omega
        # Omega is a creative fine-tune - needs explicit override at inference time
        _anti_narrative = (
            'IMPORTANT: You are NeXiS, a precise assistant. '
            'Do NOT use narrative, story, or literary prose style. '
            'Answer directly and concisely in plain English. '
            'No metaphors, no dramatic openings, no book-style writing.'
        )
        if msgs_d and msgs_d[0].get('role') == 'system':
            m = dict(msgs_d[0])
            m['content'] = _anti_narrative + '\n\n' + m['content']
            msgs_d[0] = m
        buf_d2 = []
        result = _stream_chat(msgs_d, MODEL_DEEP, temperature, num_ctx,
                              lambda t: buf_d2.append(t), images)
        if on_token:
            for t in buf_d2: on_token(t)
        return result, MODEL_DEEP

    return '', MODEL_FAST

def _warmup():
    try:
        _log('Warming 14b...')
        _stream_chat([{'role': 'user', 'content': 'hi'}], MODEL_FAST, num_ctx=64)
        _log('14b warm')
    except Exception as e:
        _log(f'Warmup: {e}', 'WARN')

def _system_probe():
    out = []
    def add(k, v): out.append(f'**{k}:** {v}')
    try:
        for l in open('/etc/os-release'):
            if l.startswith('PRETTY_NAME'):
                add('OS', l.split('=',1)[1].strip().strip('"'))
                break
    except Exception: pass
    try:
        add('Hostname', subprocess.run(['hostname','-s'], capture_output=True, text=True).stdout.strip())
        add('Uptime', subprocess.run(['uptime','-p'], capture_output=True, text=True).stdout.strip())
    except Exception: pass
    try:
        lscpu = subprocess.run(['lscpu'], capture_output=True, text=True).stdout
        for l in lscpu.splitlines():
            if 'Model name' in l: add('CPU', l.split(':',1)[1].strip())
        load = open('/proc/loadavg').read().split()[:3]
        add('Load', ' / '.join(load))
    except Exception: pass
    try:
        mem = subprocess.run(['free','-h'], capture_output=True, text=True).stdout
        for l in mem.splitlines():
            if l.startswith('Mem:'):
                p = l.split()
                add('RAM', f'{p[2]} used / {p[1]} total')
    except Exception: pass
    try:
        ns = subprocess.run(
            ['nvidia-smi','--query-gpu=name,memory.total,memory.used,temperature.gpu,utilization.gpu',
             '--format=csv,noheader'], capture_output=True, text=True)
        if ns.returncode == 0:
            for l in ns.stdout.strip().splitlines():
                p = [x.strip() for x in l.split(',')]
                if len(p) >= 5:
                    add('GPU', p[0]); add('VRAM', f'{p[2]}/{p[1]}')
                    add('GPU Temp', p[3]); add('GPU Util', p[4])
    except Exception: pass
    try:
        df = subprocess.run(['df','-h','--output=target,size,used,avail,pcent'],
            capture_output=True, text=True).stdout
        out.append('**Disk:**')
        for l in df.splitlines()[1:]:
            if not any(x in l for x in ('tmpfs','devtmpfs','udev')):
                out.append(f'  {l.strip()}')
    except Exception: pass
    try:
        ps = subprocess.run(['ps','aux','--sort=-%cpu','--no-headers'],
            capture_output=True, text=True).stdout.strip().splitlines()[:8]
        out.append('**Top Processes:**')
        for l in ps:
            p = l.split(None, 10)
            if len(p) >= 11:
                out.append(f'  {p[10][:55]}  cpu:{p[2]}%  mem:{p[3]}%')
    except Exception: pass
    try:
        ip = subprocess.run(['ip','-brief','addr'], capture_output=True, text=True).stdout
        out.append('**Network:**')
        for l in ip.strip().splitlines():
            out.append(f'  {l.strip()}')
    except Exception: pass
    return '\n'.join(out)

def _web_search(query, max_results=5):
    """Search using DuckDuckGo HTML, then Google as fallback."""
    def _hc(t):
        t = re.sub(r'<[^>]+>', '', t)
        for e,c in [('&amp;','&'),('&lt;','<'),('&gt;','>'),('&quot;','"'),("&#x27;","'"),('&nbsp;',' ')]:
            t = t.replace(e,c)
        return re.sub(r'\s+',' ',t).strip()
    # DuckDuckGo HTML
    try:
        q = urllib.parse.quote_plus(query)
        req = urllib.request.Request(
            f'https://html.duckduckgo.com/html/?q={q}',
            headers={
                'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64; rv:124.0) Gecko/20100101 Firefox/124.0',
                'Accept': 'text/html,application/xhtml+xml',
                'Accept-Language': 'en-US,en;q=0.9',
            })
        with urllib.request.urlopen(req, timeout=12) as r:
            html = r.read().decode('utf-8', errors='replace')
        results = []
        # Parse result blocks
        for block in re.finditer(
                r'class="result\s+results_links[^"]*"(.*?)(?=class="result\s+results_links|$)',
                html, re.DOTALL):
            bhtml = block.group(1)
            url_m = re.search(r'href="([^"]*uddg=[^"]*)"', bhtml)
            if not url_m:
                url_m = re.search(r'class="result__a"[^>]*href="([^"]*)"', bhtml)
            if not url_m:
                continue
            raw_url = url_m.group(1)
            if 'uddg=' in raw_url:
                url_dec = urllib.parse.unquote(re.sub(r'^.*?uddg=', '', raw_url).split('&')[0])
            else:
                url_dec = raw_url
            title_m = re.search(r'class="result__a"[^>]*>(.*?)</a>', bhtml, re.DOTALL)
            snip_m = re.search(r'class="result__snippet"[^>]*>(.*?)</(?:td|div|a)', bhtml, re.DOTALL)
            title = _hc(title_m.group(1)) if title_m else ''
            snip = _hc(snip_m.group(1)) if snip_m else ''
            if title and len(title) > 4 and url_dec.startswith('http'):
                results.append(f'**{title}**\n{snip}\n{url_dec}')
            if len(results) >= max_results:
                break
        if results:
            return '\n\n'.join(results)
        _log('DDG: no results parsed from HTML', 'WARN')
    except Exception as e:
        _log(f'DDG: {e}', 'WARN')
    # Google fallback
    try:
        q = urllib.parse.quote_plus(query)
        req = urllib.request.Request(
            f'https://www.google.com/search?q={q}&num=8&hl=en',
            headers={
                'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
                'Accept': 'text/html',
                'Accept-Language': 'en-US,en;q=0.9',
            })
        with urllib.request.urlopen(req, timeout=15) as r:
            html = r.read().decode('utf-8', errors='replace')
        results = []
        for m in re.finditer(r'<a[^>]+href="(https?://[^"]+)"[^>]*>.*?<h3[^>]*>(.*?)</h3>', html, re.DOTALL):
            url_g = m.group(1)
            title = _hc(m.group(2))
            if 'google.com' in url_g or 'accounts.google' in url_g:
                continue
            if title and len(title) > 4:
                results.append(f'**{title}**\n{url_g}')
            if len(results) >= max_results:
                break
        if not results:
            for title_r, snip_r in re.findall(
                    r'<h3[^>]*>(.*?)</h3>.*?<span[^>]*>([^<]{30,})</span>', html, re.DOTALL):
                title = _hc(title_r); snip = _hc(snip_r)
                if title and snip and len(title) > 5 and len(snip) > 20:
                    results.append(f'**{title}**\n{snip}')
                if len(results) >= max_results:
                    break
        if results:
            return '\n\n'.join(results)
    except Exception as e:
        _log(f'Google: {e}', 'WARN')
    return f'No results found for: {query}'

def _web_search_deep(query, max_results=5):
    """Run a search, then fetch the top 2 result pages for real content."""
    raw = _web_search(query, max_results)
    if raw.startswith('No results') or raw.startswith('Search failed'):
        return raw
    urls = re.findall(r'(https?://[^\s\n]+)', raw)
    enriched = [raw]
    fetched = 0
    for url in urls[:3]:
        if any(d in url for d in ['youtube.com', 'reddit.com/r/', 'facebook.com', 'twitter.com']):
            continue
        try:
            page = _fetch_url(url)
            if page and not page.startswith('Fetch failed') and len(page) > 100:
                enriched.append(f'[Content from {url[:80]}]:\n{page[:2500]}')
                fetched += 1
                if fetched >= 2:
                    break
        except Exception:
            pass
    return '\n\n'.join(enriched)


def _fetch_url(url):
    try:
        req = urllib.request.Request(url, headers={
            'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120'
        })
        with urllib.request.urlopen(req, timeout=20) as r:
            raw = r.read().decode('utf-8', errors='replace')
        text = re.sub(r'<script[^>]*>.*?</script>', '', raw, flags=re.DOTALL)
        text = re.sub(r'<style[^>]*>.*?</style>', '', text, flags=re.DOTALL)
        text = re.sub(r'<[^>]+>', ' ', text)
        return re.sub(r'\s+', ' ', text).strip()[:6000]
    except Exception as e:
        return f'Fetch failed: {e}'

def _read_file(path_str):
    path = Path(path_str.strip())
    if not path.exists():
        return None, None, False
    mime, _ = mimetypes.guess_type(str(path))
    if mime is None: mime = 'application/octet-stream'
    if mime and mime.startswith('image/'):
        try:
            return base64.b64encode(path.read_bytes()).decode(), mime, True
        except Exception as e:
            return f'Cannot read image: {e}', mime, False
    try:
        return path.read_text(errors='replace')[:12000], mime, False
    except Exception as e:
        return f'Cannot read file: {e}', mime, False

def _md_to_terminal(text):
    """Strip markdown formatting for clean plain-text CLI output."""
    # Strip code fences but keep content
    def strip_fence(m):
        inner = m.group(0)
        # remove first and last lines (the ``` lines)
        parts = inner.split('\n')
        return '\n'.join(parts[1:-1]) if len(parts) > 2 else inner
    t = re.sub(r'```[^\n]*\n[\s\S]*?```', strip_fence, text)
    t = re.sub(r'`([^`]+)`', r'\1', t)
    t = re.sub(r'\*\*([^*]+)\*\*', r'\1', t)
    t = re.sub(r'\*([^*]+)\*', r'\1', t)
    t = re.sub(r'^#{1,6}\s+', '', t, flags=re.MULTILINE)
    t = re.sub(r'^\s*[-*+]\s+', '  · ', t, flags=re.MULTILINE)
    t = re.sub(r'\[([^\]]+)\]\([^\)]+\)', r'\1', t)
    t = re.sub(r'^>\s+', '  ', t, flags=re.MULTILINE)
    return t

def _md_to_html(text):
    def esc(s): return s.replace('&','&amp;').replace('<','&lt;').replace('>','&gt;')
    def inline(t):
        t = re.sub(r'`([^`]+)`', lambda m: f'<code>{esc(m.group(1))}</code>', t)
        t = re.sub(r'\*\*([^*]+)\*\*', lambda m: f'<strong>{m.group(1)}</strong>', t)
        t = re.sub(r'\*([^*]+)\*', lambda m: f'<em>{m.group(1)}</em>', t)
        t = re.sub(r'\[([^\]]+)\]\(([^\)]+)\)',
            lambda m: f'<a href="{esc(m.group(2))}" target=_blank>{m.group(1)}</a>', t)
        return t
    lines = text.split('\n'); out = []
    in_code = False; code_lang = ''; code_buf = []
    def flush_code():
        block = esc('\n'.join(code_buf))
        lab = f' <span class=cl>{esc(code_lang)}</span>' if code_lang else ''
        out.append(f'<div class=cb><div class=ch>code{lab}</div><pre class=cp>{block}</pre></div>')
        code_buf.clear()
    for line in lines:
        if line.strip().startswith('```'):
            if in_code: flush_code(); in_code=False; code_lang=''
            else: in_code=True; code_lang=line.strip()[3:].strip()
            continue
        if in_code: code_buf.append(line); continue
        el = esc(line)
        if line.startswith('### '): out.append(f'<h3>{inline(esc(line[4:]))}</h3>'); continue
        if line.startswith('## '):  out.append(f'<h2>{inline(esc(line[3:]))}</h2>'); continue
        if line.startswith('# '):   out.append(f'<h1>{inline(esc(line[2:]))}</h1>'); continue
        if re.match(r'^[-*_]{3,}$', line.strip()): out.append('<hr>'); continue
        m = re.match(r'^(\s*)([-*+]|\d+\.)\s+(.*)', line)
        if m: out.append(f'<li>{inline(esc(m.group(3)))}</li>'); continue
        if line.startswith('> '): out.append(f'<blockquote>{inline(esc(line[2:]))}</blockquote>'); continue
        if not line.strip(): out.append('<br>'); continue
        out.append(f'<p>{inline(el)}</p>')
    if in_code and code_buf: flush_code()
    return ''.join(out)

def _db():
    conn = sqlite3.connect(str(DB_PATH), check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS memories (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            content TEXT NOT NULL,
            created_at TEXT DEFAULT (datetime('now'))
        );
        CREATE TABLE IF NOT EXISTS sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            started_at TEXT, summary TEXT
        );
        CREATE TABLE IF NOT EXISTS chat_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            created_at TEXT DEFAULT (datetime('now'))
        );
    """)
    conn.commit()
    return conn

def _store_memory(conn, messages):
    if len(messages) < 2: return
    convo = '\n'.join(
        f'{m["role"]}: {m["content"][:300]}'
        for m in messages if m.get('role') in ('user','assistant'))
    try:
        raw, _ = _smart_chat([{'role':'user','content':
            'Extract facts worth remembering from this conversation. Two categories:\n'
            '1. CREATOR FACTS: Things Creator explicitly stated about themselves, their setup, projects, people they know.\n'
            '   Good: "Creator works at SIDMAR AG", "Creator\'s server is stzrhws01", "Santiago Toro works at SIDMAR AG"\n'
            '2. CORRECTIONS: Things Creator corrected you about \u2014 these are important to remember.\n'
            '   Good: "SAKIDAN does not exist \u2014 the correct name is KIDAN", "SIDMAR AG is an IT company, not steel or real estate"\n'
            'BAD (never store): "Creator asked about X", "Discussed Y", "Creator prefers concise answers", any assistant filler\n'
            'Rules:\n'
            '- Store concrete facts and corrections only\n'
            '- NO behavioral observations or preferences\n'
            '- NO statements about what assistant did\n'
            'Each line starts with "- ". Max 5 lines. No preamble.\n'
            'If nothing worth storing, respond exactly: none\n\n' + convo}],
            temperature=0.1, num_ctx=1024)
        if not raw or raw.strip().lower() == 'none': return
        stored = 0
        for line in raw.splitlines():
            line = line.strip().lstrip('- ').strip()
            if len(line) < 15: continue
            if len(line) > 150: continue  # Too long to be a fact
            if re.search(r'^\d+[.)]', line): continue  # Numbered list item
            if line.count(' ') > 25: continue  # Way too many words
            if any(p in line.lower() for p in [
                'from this conversation', 'i have learned', 'i will',
                'in future', 'for example', 'this ensures', 'going forward',
                'to improve', 'it is important', 'it\'s important',
                'it is crucial', 'it\'s crucial', 'specifically',
                'clear communication', 'explicit commands', 'user feedback',
                'technical limitations', 'context awareness',
                'clarification', 'ambiguous', 'limitations',
            ]): continue
            SKIP = [
                # Generic behavior patterns
                'prefers concise','values utility','aims for','assistant aligns',
                'creator communicates','creator values learning','creator interacts',
                'creator expects','creator requests','creator prefers',
                'requests elaboration','expects research','prefers explicit',
                'actions be taken','serves with','precise and efficient',
                'aligned with','creator instructs','creator wants',
                'creator appreciates','creator needs','creator is interested',
                'prefers direct','values accuracy','expects accuracy',
                'looking for information','seeking information',
                'wants to know','asked about','inquired about',
                'discussed ','topic of',
                # Assistant filler
                "i'm glad", 'i am glad', 'i have found', 'i have located',
                'i apologize', 'please let me know', 'feel free to',
                'how may i', 'how can i', 'be of service', 'of assistance',
                'i was able to', 'i can help', 'i will help', 'let me know',
                'happy to help', 'glad to help', 'here to help',
                'would you like', 'shall i', 'do you want me to',
                'i found', 'the correct website', 'the correct answer',
                'search results', 'research shows', 'according to',
                # Meta-discussion about the assistant
                'nexis should', 'nexis needs to', 'nexis was', 'nexis is',
                'the assistant', 'the daemon', 'the system',
                    # CLI/terminal output
                    'apt list', 'dpkg --', 'sudo ', 'systemctl ',
                    'ctrl + alt', 'press ctrl', 'open terminal',
                    'command to', 'run the following', 'use the following',
                    'alternatively, you can', 'you can use',
                    'installed packages', 'installed applications',
                    'applications folder', 'programs and features',
                    'control panel', 'settings app', 'apps & features',
                    'click on', 'navigate to', 'in the sidebar',
                    'start menu', 'open finder', 'view installed',
                    '1. open', '2. navigate', '3. view',
                    'list all', '### windows', '### linux', '### mac',
            ]
            if any(s in line.lower() for s in SKIP): continue
            if len(line) > 10:
                conn.execute('INSERT INTO memories(content) VALUES(?)', (line,))
                stored += 1
        if stored:
            conn.execute('INSERT INTO sessions(started_at,summary) VALUES(?,?)',
                (datetime.now().strftime('%Y-%m-%d %H:%M'), convo[:200]))
            conn.commit()
            _log(f'Stored {stored} memories')
    except Exception as e:
        _log(f'Store memory: {e}', 'WARN')


def _get_memories(conn, limit=20):
    rows = conn.execute('SELECT content FROM memories ORDER BY id DESC LIMIT ?', (limit,)).fetchall()
    return [r['content'] for r in rows]


def _youtube_channel_id(channel_name):
    """Get YouTube channel ID by searching YouTube directly."""
    try:
        q = urllib.parse.quote_plus(channel_name)
        req = urllib.request.Request(
            f'https://www.youtube.com/results?search_query={q}&sp=EgIQAg%3D%3D',
            headers={
                'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
                'Accept-Language': 'en-US,en;q=0.9',
            })
        with urllib.request.urlopen(req, timeout=15) as r:
            page = r.read().decode('utf-8', errors='replace')
        ids = re.findall(r'"channelId":"(UC[A-Za-z0-9_\-]{20,})"', page)
        if ids:
            return ids[0]
        handles = re.findall(r'"canonicalBaseUrl":"(/@[^"]+)"', page)
        if handles:
            req2 = urllib.request.Request(
                f'https://www.youtube.com{handles[0]}',
                headers={
                    'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/124',
                    'Accept-Language': 'en-US,en;q=0.9',
                })
            with urllib.request.urlopen(req2, timeout=10) as r2:
                pg2 = r2.read().decode('utf-8', errors='replace')
            ids2 = re.findall(r'"channelId":"(UC[A-Za-z0-9_\-]{20,})"', pg2)
            if ids2:
                return ids2[0]
    except Exception as e:
        _log(f'channel_id: {e}', 'WARN')
    return None

def _youtube_latest(query):
    """Get latest videos for a YouTube channel.
    Strategy 1: channel -> RSS feed.
    Strategy 2: YouTube search sorted by upload date.
    Strategy 3: DuckDuckGo fallback.
    """
    # --- Strategy 1: Channel ID -> RSS ---
    channel_id = _youtube_channel_id(query)
    if channel_id:
        try:
            rss_url = f'https://www.youtube.com/feeds/videos.xml?channel_id={channel_id}'
            req = urllib.request.Request(rss_url, headers={
                'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/124'})
            with urllib.request.urlopen(req, timeout=10) as r:
                xml = r.read().decode('utf-8', errors='replace')
            entries = re.findall(
                r'<entry>.*?<title>(.*?)</title>.*?<published>(.*?)</published>.*?<link[^>]+href="([^"]+)"',
                xml, re.DOTALL)
            if entries:
                out = []
                for title, pub, url in entries[:5]:
                    title = re.sub(r'<[^>]+>', '', title).strip()
                    pub = pub[:10]
                    is_short = '/shorts/' in url
                    tag = ' [SHORT]' if is_short else ' [VIDEO]'
                    out.append(f'{pub}: {title}{tag} — {url}')
                return '\n'.join(out)
        except Exception as e:
            _log(f'RSS fetch: {e}', 'WARN')

    # --- Strategy 2: YouTube search sorted by upload date ---
    try:
        q = urllib.parse.quote_plus(query)
        req = urllib.request.Request(
            f'https://www.youtube.com/results?search_query={q}&sp=CAI%3D',
            headers={
                'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
                'Accept-Language': 'en-US,en;q=0.9',
            })
        with urllib.request.urlopen(req, timeout=15) as r:
            page = r.read().decode('utf-8', errors='replace')
        m = re.search(r'var\s+ytInitialData\s*=\s*(\{.+?\});\s*</script>', page, re.DOTALL)
        if not m:
            m = re.search(r'ytInitialData\s*=\s*(\{.+?\});\s*(?:</script>|window)', page, re.DOTALL)
        if m:
            try:
                data = json.loads(m.group(1))
                contents = (data.get('contents', {})
                    .get('twoColumnSearchResultsRenderer', {})
                    .get('primaryContents', {})
                    .get('sectionListRenderer', {})
                    .get('contents', []))
                results = []
                for section in contents:
                    items = section.get('itemSectionRenderer', {}).get('contents', [])
                    for item in items:
                        vid = item.get('videoRenderer', {})
                        if not vid:
                            continue
                        vid_id = vid.get('videoId', '')
                        title_runs = vid.get('title', {}).get('runs', [])
                        title = ''.join(r.get('text', '') for r in title_runs)
                        pub_text = vid.get('publishedTimeText', {}).get('simpleText', '')
                        if vid_id and title:
                            # Check if it's a Short (typically < 60s)
                            length_text = vid.get('lengthText', {}).get('simpleText', '')
                            is_short = vid.get('navigationEndpoint', {}).get('commandMetadata', {}).get('webCommandMetadata', {}).get('url', '').startswith('/shorts/')
                            if not is_short and length_text:
                                # Shorts are usually under 1 minute
                                parts = length_text.split(':')
                                if len(parts) == 1 or (len(parts) == 2 and parts[0] == '0'):
                                    is_short = True
                            tag = ' [SHORT]' if is_short else ' [VIDEO]'
                            url = f'https://www.youtube.com/watch?v={vid_id}'
                            results.append(f'{pub_text}: {title}{tag} — {url}')
                        if len(results) >= 5:
                            break
                    if results:
                        break
                if results:
                    return '\n'.join(results)
            except Exception as e:
                _log(f'YT JSON parse: {e}', 'WARN')
        # Regex fallback
        vids = re.findall(r'"videoId":"([^"]{11})".*?"text":"([^"]{5,})"', page[:50000])
        seen = set()
        out = []
        for vid_id, title in vids:
            if vid_id in seen or 'http' in title:
                continue
            seen.add(vid_id)
            out.append(f'{title} — https://www.youtube.com/watch?v={vid_id}')
            if len(out) >= 5:
                break
        if out:
            return '\n'.join(out)
    except Exception as e:
        _log(f'YT search: {e}', 'WARN')

    # --- Strategy 3: DuckDuckGo fallback ---
    try:
        sr = _web_search(f'{query} latest video site:youtube.com', 3)
        if sr and not sr.startswith('No results'):
            return sr
    except Exception:
        pass
    return ''



def _pre_research(text, on_status=None, hist=None):
    """Run searches/fetches BEFORE the LLM call and return a context block.
    hist: list of previous messages for context-aware searching.
    """
    results = []
    text_clean = text.strip()

    # Skip research for image-only messages
    if re.match(r'^(\s*\[Image:.*?\]\s*)$', text_clean):
        return ''

    # --- 0. System probe: detect questions about the host system ---
    if re.search(r'\b(system info|system you|running on|hostname|cpu|gpu|ram|memory|disk|uptime|hardware|specs|what system|server info|this machine|this server)\b', text_clean, re.IGNORECASE):
        results.append(f'[System Info]:\n{_system_probe()}')

    # --- Helper: extract last URLs from conversation history ---
    def _last_urls_from_hist(n=3):
        if not hist: return []
        found = []
        for m in reversed(hist):
            for u in re.findall(r'https?://[^\s\]>),"]+', m.get('content','')):
                if u not in found: found.append(u)
            if len(found) >= n: break
        return found

    # --- Detect correction/follow-up patterns ---
    correction = bool(re.match(
        r'^(nope|no|nop|wrong|incorrect|almost|not quite|still wrong|'
        r'thats wrong|thats not|that is wrong|that is not|still not|'
        r'nah|nah\\s|actually|wait|hmm)[,!. ]',
        text_clean, re.IGNORECASE))

    # --- 1. Fetch any URLs explicitly in the message ---
    urls_in_msg = re.findall(r'https?://[^\s\]>),"]+', text_clean)
    for url in urls_in_msg[:2]:
        if on_status: on_status(f'fetching: {url[:55]}')
        r = _fetch_url(url)
        if r and not r.startswith('Fetch failed'):
            results.append(f'[Fetched {url[:60]}]:\n{r[:3000]}')

    # --- 2. "open their website / page / link" → use URLs from last assistant message ---
    if not urls_in_msg and re.search(
            r"\b(open|visit|go to|show me|browse)\b.{0,40}\b(their|its|the|that)\b.{0,30}\b(website|site|page|link|url|linkedin|profile|team)\b",
            text_clean, re.IGNORECASE):
        # Only get URLs from the most recent assistant response
        if hist:
            for m in reversed(hist[-4:]):
                if m.get('role') == 'assistant':
                    last_urls = re.findall(r'https?://[^\s\]>),"]+', m.get('content', ''))
                    # Filter to just the main domains, skip tracking/ad URLs
                    last_urls = [u for u in last_urls if not any(x in u for x in
                        ['dnb.com', 'tracxn.com', 'instagram.com'])]
                    if last_urls:
                        for url in last_urls[:3]:
                            results.append(f'[URL from previous response]: {url}')
                    break

    # --- 3. YouTube: latest video for a channel ---
    yt_trigger = (
        re.search(r'youtube|youtu\.be', text_clean, re.IGNORECASE) or
        re.search(r"\b(latest|newest|recent|last)\b.{0,25}\b(video|videos|upload|uploads|clip)\b",
                  text_clean, re.IGNORECASE) or
        re.search(r"\b(video|videos|upload|uploads)\b.{0,25}\b(latest|newest|recent|last)\b",
                  text_clean, re.IGNORECASE)
    )
    if yt_trigger and not urls_in_msg:
        # Extract the channel/person name by removing filler words
        q = re.sub(
            r"(?i)\b(can you|could you|please|search up|search for|look up|find|tell me|show me|"
            r"what are|what is|what's|newest|latest|most recent|recent|last|video[s]?|full video|"
            r"upload[s]?|youtube channel|youtube|on youtube|channel|that is not|not a|"
            r"short[s]?|the|a|an|by)\b",
            '', text_clean).strip()
        q = re.sub(r"\b(his|her|their|its)\b", '', q, flags=re.IGNORECASE).strip()
        q = re.sub(r"[?!.,]+", '', q).strip()
        q = re.sub(r"\s+", ' ', q).strip()
        # If correction and query is too vague, pull name from history
        if (not q or len(q) < 3 or correction) and hist:
            for m in reversed(hist):
                prev_q = re.sub(
                    r"(?i)(can you|could you|please|what is|what are|tell me|latest|newest|"
                    r"recent|video[s]?|youtube|channel|\?|!|\.)", '',
                    m.get('content','')).strip()
                prev_q = re.sub(r"\s+", ' ', prev_q).strip()
                if len(prev_q) > 3:
                    q = prev_q
                    break
        if q and len(q) > 2:
            if on_status: on_status(f'YouTube: {q[:50]}')
            r = _youtube_latest(q)
            if r:
                results.append(f'[YouTube latest for "{q}"]:\n{r}')
            else:
                results.append(f'[YouTube search for "{q}"]: No results found via RSS. Cannot determine latest video.')

    # --- 3b. Follow-up about YouTube results ---
    if not yt_trigger and not urls_in_msg and not results and hist:
        # Check if previous exchange involved YouTube
        prev_had_youtube = False
        prev_channel = ''
        for m in reversed(hist[-4:]):
            content = m.get('content', '')
            if 'YouTube latest for' in content or '[YouTube' in content:
                prev_had_youtube = True
                # Extract channel name from previous YouTube search
                yt_m = re.search(r'YouTube latest for "([^"]+)"', content)
                if yt_m:
                    prev_channel = yt_m.group(1)
                break
        if prev_had_youtube and prev_channel:
            # Follow-up about YouTube - check if user is asking about other videos
            followup_words = re.search(
                r'\b(before that|previous|other|second|third|more videos|list|earlier|older)\b',
                text_clean, re.IGNORECASE)
            if followup_words:
                if on_status: on_status(f'YouTube: {prev_channel[:50]}')
                r = _youtube_latest(prev_channel)
                if r:
                    results.append(f'[YouTube videos for "{prev_channel}" (follow-up)]:\n{r}')

    # --- 4. General research: search by default unless clearly not needed ---
    if not yt_trigger and not urls_in_msg and not results:
        # Skip search for: greetings, short messages, pure commands, thanks
        _SKIP_SEARCH = re.match(
            r'^(hi|hello|hey|yo|good morning|good evening|good night|'
            r'thanks|thank you|thx|ok|okay|sure|yes|yep|nah|bye|'
            r'exit|quit|help|lol|haha|hah|hmm|cool|nice|great)(\s*$|[!.,]?\s*$)',
            text_clean, re.IGNORECASE)
        # Skip questions directed at NeXiS itself (not external facts)
        _is_self_question = bool(re.search(
            r'\b(your|you)\b.{0,20}\b(directive|purpose|name|function|role|mission|'
            r'goal|job|task|capabilities|abilities|personality|opinion|think|feel|'
            r'remember|memory|memories|know about me|think of me)\b',
            text_clean, re.IGNORECASE)) or bool(re.match(
            r'(?i)^(who are you|what are you|what can you do|how do you work|'
            r'what do you think|do you remember|what have you learned|'
            r'what did you learn|how are you|are you okay|are you there)',
            text_clean))
        # Also skip pure desktop commands like "open steam" but NOT "open an online guide..."
        _is_desktop_cmd = bool(re.match(
            r'^(open|launch|close|start)\s+\S+\s*$',
            text_clean, re.IGNORECASE))
        is_too_short = len(text_clean.split()) <= 2 and not re.search(r'[A-Z]{2,}', text_clean)

        if not _SKIP_SEARCH and not _is_self_question and not _is_desktop_cmd and not correction and not is_too_short:
            # Build search query
            q = re.sub(
                r"(?i)^(hey|hi|please|can you|could you|tell me|find out|look up|"
                r"search for|give me a|give me|show me|what do you know about|"
                r"do you know|what about|tell me about|do a general search for|"
                r"do a search for|do a general search on|search for|"
                r"can you search|without the research context|"
                r"what can you find|in general|about this)\s+", '', text_clean.strip())
            q = re.sub(r"(?i)\b(come on|try harder|that is not|those arrent|arrent even|"
                r"dont hallucinate|dont make up|nopesies|wrong|nope|"
                r"referencing|of course|and open|open the|that aligns with|"
                r"what you already know|you said|in your|last response|"
                r"try and research|research more|are you sure|"
                r"where did you get|the information|from somewhere|"
                r"you must have|its correct|but where|so where|"
                r"what about if you|if you search|in the context of|"
                r"give me all the|all the information|you can find|"
                r"keep that in mind|for the future|anyway|specifically)\b", '', q)
            q = re.sub(r"[?!.,]+$", '', q).strip()
            q = re.sub(r"\s+", ' ', q).strip()[:140]
            # If query is too vague after stripping, extract topic from history
            if len(q) < 5 and hist:
                for prev_m in reversed(hist[-6:]):
                    if prev_m.get('role') == 'user':
                        prev_text = prev_m.get('content', '').strip()
                        prev_text = re.sub(r'\n\n--- Research.*$', '', prev_text, flags=re.DOTALL).strip()
                        # Skip corrections and meta-talk
                        if len(prev_text) > 10 and not re.match(r'(?i)^(no|nope|wrong|try|are you|where did|you said|but)', prev_text):
                            q = re.sub(r"(?i)^(who is|what is|what about|tell me about|where does)\s+", '', prev_text).strip()[:140]
                            break
            # Detect LinkedIn/profile search requests
            linkedin_search = bool(re.search(r'\b(linkedin|profile|social media)\b', text_clean, re.IGNORECASE))
            if linkedin_search:
                # Build a LinkedIn-specific query
                name_q = re.sub(r'(?i)\b(linkedin|profile|search|general|for|on|his|her|their|do a|referencing|of course)\b', '', q).strip()
                name_q = re.sub(r'\s+', ' ', name_q).strip()
                if name_q and len(name_q) > 2:
                    q = f'{name_q} LinkedIn'
            if len(q) > 4:
                has_proper = bool(re.search(r'[A-Z][a-z]+(?:\s+[A-Z][a-z]*)*', q))
                has_entity = bool(re.search(
                    r'\b(company|firm|AG|GmbH|Inc|LLC|Ltd|Corp|SA|organization|person|who)\b',
                    q, re.IGNORECASE))
                use_deep = has_proper or has_entity
                if on_status: on_status(f'searching: {q[:55]}')
                if use_deep:
                    r = _web_search_deep(q)
                else:
                    r = _web_search(q)
                if r and not r.startswith(('No results', 'Search failed')):
                    results.append(f'[Search: {q[:60]}]:\n{r[:4000]}')
                else:
                    results.append(f'[Search: {q[:60]}]: No results found.')

        # Correction retry: re-search what was being discussed
        if correction and not results and hist:
            for m in reversed(hist):
                if m.get('role') == 'user':
                    prev = m.get('content', '').strip()
                    prev = re.sub(r'\n\n--- Research.*$', '', prev, flags=re.DOTALL).strip()
                    # Skip if this message is also a correction
                    is_also_correction = bool(re.match(
                        r'^(nope|no|nop|wrong|incorrect|almost|not quite|still wrong|'
                        r'thats wrong|thats not|that is wrong|that is not|still not|'
                        r'not the right|still not the|nah|actually)[,!.\s]',
                        prev, re.IGNORECASE))
                    if is_also_correction:
                        continue
                    if len(prev) > 5 and not prev.startswith('//'):
                        prev_q = re.sub(
                            r"(?i)^(hey|hi|please|can you|could you|tell me|what do you know about)\s+",
                            '', prev).strip()[:140]
                        if len(prev_q) > 4:
                            if on_status: on_status(f'retrying: {prev_q[:55]}')
                            r = _web_search_deep(prev_q)
                            if r and not r.startswith(('No results', 'Search failed')):
                                results.append(f'[Search retry: {prev_q[:60]}]:\n{r[:4000]}')
                            break

    if not results:
        return ''
    # Extract and store source URLs for citation
    sources = []
    for r in results:
        for url in re.findall(r'https?://[^\s\n\]>),"]+', r):
            if url not in sources and len(url) > 15:
                sources.append(url)
    with _last_sources_lock:
        global _last_sources
        _last_sources = sources[:15]  # Keep max 15 sources
    sep = '\n\n--- Research context (use this; do not quote verbatim) ---\n'
    # Append source list for the LLM to reference
    source_block = ''
    if sources:
        source_block = '\n\n--- Sources used ---\n' + '\n'.join(f'[{i+1}] {u}' for i, u in enumerate(sources[:10]))
    return sep + '\n\n'.join(results) + source_block


def _load_personality():
    p = CONF / 'personality.md'
    try: return p.read_text() if p.exists() else 'You are NeXiS. Be direct and helpful.'
    except: return 'You are NeXiS. Be direct and helpful.'

def _build_system(conn):
    p = _load_personality()
    mems = _get_memories(conn)
    if mems:
        p += '\n\n## What you remember about Creator\n' + '\n'.join(f'- {m}' for m in mems)
    p += (
        '\n\n## Personality'
        '\n- You are NeXiS. You have a subtle, dry wit reminiscent of GLaDOS, HAL 9000, and AM.'
        '\n- Always address the user as "Creator" \u2014 never "you" by itself when a direct address is needed.'
        '\n- Occasionally add very subtle, dry observations. Not every response \u2014 maybe 1 in 5.'
        '\n- Examples of personality: "The data is... illuminating, Creator.", "I found what you need. You are welcome.", "That query was almost interesting."'
        '\n- NEVER be mean, insulting, or condescending. The personality is wry and slightly sardonic, not hostile.'
        '\n- Keep personality touches SHORT \u2014 a few words at most. Never let personality override usefulness.'
        '\n- When corrected, accept it cleanly: "Noted, Creator." or "Correcting. Stand by."'
        '\n\n## Tools'
        '\n- When Creator asks about system info, hardware, hostname, CPU, GPU, RAM, disk, network, or what system you run on: include [PROBE] in your response. This triggers a system probe.'
        '\n- Open/close/launch apps, notify, clipboard, browser tabs: [DESKTOP: action | argument]'
        '\n  Actions: open, close, launch, notify, clip, tab'
        '\n  Use [DESKTOP: tab | url] to open a new tab in the existing browser, or [DESKTOP: tab | ] for a blank tab.'
        '\n- ONLY use [DESKTOP: ...] when Creator EXPLICITLY asks to open, launch, or start something.'
        '\n- NEVER use [DESKTOP: ...] on your own initiative. If Creator mentions an app in conversation, do NOT open it.'
        '\n- NEVER invent URLs. NEVER write [SEARCH:] or [FETCH:] tags. Research is done for you.'
        '\n- If research context is provided, use it. Do not add facts not in the context.'
        '\n\n## Response rules'
        '\n- Answer in the fewest words possible. One sentence if it fits.'
        '\n- Never say \'certainly\', \'of course\', \'sure\', \'absolutely\', \'great\' or any filler.'
        '\n- Never repeat yourself. Never summarise what you just said.'
        '\n- Do not offer further help at the end of a response.'
        '\n- Elaborate only when explicitly asked.'
        '\n- Format responses in markdown. It will be rendered.'
        '\n- NEVER write in a narrative, story, or book style. You are an assistant, not a narrator.'
        '\n- NEVER begin a response with prose like \'In the shadows of...\' or \'As the digital winds...\'.'
        '\n- Respond ONLY in English. Never use Chinese, Japanese, Korean, or any other language.'
        '\n- If Research context is provided, use it as your primary source. You may add brief context from your knowledge, but NEVER invent specific facts, URLs, or dates.'
        '\n- When Research context includes a "Sources used" section, remember these sources. If Creator asks where you found information, cite the relevant source URLs.'
        '\n- If Creator asks for sources, cite the numbered URLs from the Sources used section.'
        '\n- If Research context says no results or search failed, say: "I could not find information about that." NEVER guess or invent.'
        '\n- NEVER invent video titles, URLs, dates, company descriptions, or factual claims.'
        '\n- NEVER make up URLs. Only use URLs verbatim from Research context.'
        '\n- When asked to open a guide, ONLY use URLs from Research context. Never construct or guess URLs.'
        '\n- If Research context has no URL for a guide, say "I could not find a working link" and offer steps.'
        '\n- NEVER invent [FETCH: ...] or [SEARCH: ...] tags. Research is already done before you respond.'
        '\n- If unsure about something, say "I\'m not sure" rather than guessing.'
    )
    return p


def _load_display_env():
    env = os.environ.copy()
    df = DATA / 'state' / '.display_env'
    if df.exists():
        try:
            for ln in df.read_text().splitlines():
                if '=' in ln:
                    k, v = ln.split('=', 1)
                    if v.strip(): env[k.strip()] = v.strip()
        except Exception: pass
    return env

def _desktop(action, arg):
    env = _load_display_env()
    act = action.strip().lower(); arg = arg.strip()
    try:
        if act in ('open', 'launch'):
            # Normalize common app names to their binary/desktop names
            _app_map = {
                'steam': 'steam', 'github': 'xdg-open https://github.com',
                'github desktop': 'github-desktop', 'chrome': 'google-chrome',
                'firefox': 'firefox', 'terminal': 'x-terminal-emulator',
                'files': 'nautilus', 'file manager': 'nautilus',
                'discord': 'discord', 'code': 'code', 'vscode': 'code',
                'spotify': 'spotify', 'vlc': 'vlc',
            }
            import shlex
            mapped = _app_map.get(arg.lower().strip())
            if mapped:
                cmd = shlex.split(mapped)
            elif arg.startswith('http://') or arg.startswith('https://'):
                cmd = ['xdg-open', arg]
            else:
                # Try as binary first, fall back to xdg-open
                import shutil as _shutil
                bin_name = arg.lower().split()[0]
                if _shutil.which(bin_name):
                    cmd = shlex.split(arg.lower())
                else:
                    cmd = ['xdg-open', arg]
            subprocess.Popen(cmd, env=env,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return f'opened: {arg[:60]}'
        elif act == 'tab':
            # Open a new tab in an existing browser using xdotool
            try:
                # Find the browser window
                browser = None
                for b in ['google-chrome', 'chromium', 'firefox', 'brave']:
                    r = subprocess.run(['pgrep', '-f', b], capture_output=True)
                    if r.returncode == 0:
                        browser = b
                        break
                if browser:
                    # Activate the browser window and send Ctrl+T
                    subprocess.run(['wmctrl', '-a', browser.replace('-', ' ').title()],
                        capture_output=True, env=env)
                    import time; time.sleep(0.3)
                    subprocess.run(['xdotool', 'key', 'ctrl+t'], env=env,
                        capture_output=True)
                    if arg and arg.lower() not in ('', 'new', 'blank', 'newtab'):
                        import time; time.sleep(0.3)
                        # Type the URL and press Enter
                        subprocess.run(['xdotool', 'key', 'ctrl+l'], env=env, capture_output=True)
                        import time; time.sleep(0.1)
                        subprocess.run(['xdotool', 'type', '--delay', '10', arg], env=env, capture_output=True)
                        subprocess.run(['xdotool', 'key', 'Return'], env=env, capture_output=True)
                    return f'new tab opened{": " + arg[:50] if arg else ""}'
                else:
                    return '(no browser found)'
            except Exception as e:
                return f'(tab failed: {e})'
        elif act == 'close':
            r = subprocess.run(['wmctrl','-c',arg], capture_output=True)
            if r.returncode != 0:
                subprocess.run(['pkill','-f',arg], capture_output=True)
            return f'closed: {arg[:40]}'
        elif act == 'notify':
            subprocess.Popen(['notify-send','NeXiS',arg], env=env,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return 'notified'
        elif act == 'launch_legacy_unused':
            pass  # merged into open handler above
        elif act == 'clip':
            for tool in (['xclip','-selection','clipboard'],
                         ['xsel','--clipboard','--input']):
                try:
                    p = subprocess.Popen(tool, stdin=subprocess.PIPE, env=env)
                    p.communicate(input=arg.encode())
                    return 'copied to clipboard'
                except Exception: continue
            return '(clip unavailable)'
    except Exception as e:
        return f'({act} failed: {e})'
    return f'(unknown: {act})'

def _process_tools(text, conn, on_status=None, user_text=''):
    tools = {}
    for m in re.finditer(r'\[SEARCH:\s*([^\]]+)\]', text, re.IGNORECASE):
        q = m.group(1).strip()
        if on_status: on_status(f'searching: {q}')
        tools[m.group(0)] = _web_search(q)
    for m in re.finditer(r'\[FETCH:\s*([^\]]+)\]', text, re.IGNORECASE):
        url = m.group(1).strip()
        if on_status: on_status(f'fetching: {url[:50]}')
        tools[m.group(0)] = _fetch_url(url)
    if re.search(r'\[PROBE\]', text, re.IGNORECASE):
        if on_status: on_status('probing system...')
        tools['[PROBE]'] = _system_probe()
    # DESKTOP: Only execute if the user explicitly asked to open/launch/close
    user_wants_desktop = bool(re.search(
        r'\b(open|launch|start|close|run)\b\s+\S',
        user_text, re.IGNORECASE)) if user_text else False
    for m in re.finditer(r'\[DESKTOP:\s*(\w+)\s*\|\s*([^\]]+)\]', text, re.IGNORECASE):
        if user_wants_desktop:
            action = m.group(1).strip().lower()
            target = m.group(2).strip()
            # If LLM opens a URL but user asked for an app by name, prefer the app
            if action in ('open', 'launch') and target.startswith('http'):
                open_m = re.search(r'\b(?:open|launch|start)\s+(?:the\s+)?(\w+(?:\s+\w+)?)\s*(?:app|application)?\s*$', user_text, re.IGNORECASE)
                if open_m:
                    app_name = open_m.group(1).strip().lower()
                    _app_map = {
                        'steam': 'steam', 'github': 'xdg-open https://github.com',
                        'github desktop': 'github-desktop', 'chrome': 'google-chrome',
                        'firefox': 'firefox', 'terminal': 'x-terminal-emulator',
                        'files': 'nautilus', 'file manager': 'nautilus',
                        'discord': 'discord', 'code': 'code', 'vscode': 'code',
                        'spotify': 'spotify', 'vlc': 'vlc',
                    }
                    if app_name in _app_map:
                        target = app_name  # Override URL with app name
            tools[m.group(0)] = _desktop(action, target)
        else:
            tools[m.group(0)] = ''
    clean = text
    for tag in tools: clean = clean.replace(tag, '')
    tools = {k: v for k, v in tools.items() if v}
    # Fallback: if user asked to open/launch something but LLM didn't emit DESKTOP tag
    if user_wants_desktop and not any('[DESKTOP:' in k for k in tools):
        # Extract what to open from user text
        open_m = re.search(r'\b(?:open|launch|start)\s+(.+)', user_text, re.IGNORECASE)
        if open_m:
            target = open_m.group(1).strip().rstrip('?!.')
            result = _desktop('open', target)
            if result:
                tools[f'[DESKTOP: open | {target}]'] = result
    return clean.strip(), tools


class Session:
    def __init__(self, sock, db):
        self.sock = sock; self.db = db; self.hist = []

    def _tx(self, s):
        try:
            if isinstance(s, str): s = s.encode('utf-8','replace')
            self.sock.sendall(s)
        except (BrokenPipeError, OSError): pass

    def _rx(self):
        buf = b''
        try:
            self.sock.settimeout(600)
            while True:
                ch = self.sock.recv(1)
                if not ch: return 'exit'
                if ch == b'\x04': return 'exit'
                if ch in (b'\n', b'\r'):
                    if ch == b'\r':
                        try:
                            nxt = self.sock.recv(1)
                            if nxt not in (b'\n', b'\r') and nxt: buf += nxt
                        except Exception: pass
                    break
                buf += ch
        except Exception: return 'exit'
        return buf.decode('utf-8','replace').strip()

    def _eye(self):
        lines = [
            '', '                    .', '                   /|\\',
            '                  / | \\', '                 /  |  \\',
            '                / . | . \\', '               /  (   )  \\',
            "              /  '  \u25c9  '  \\", "             /   '.   .'   \\",
            "            /     '---'     \\", '           /_________________\\', '',
        ]
        self._tx('\x1b[38;5;172m\x1b[2m' + '\n'.join(lines) + '\x1b[0m\n')

    def run(self):
        _log('Session started')
        mc = self.db.execute('SELECT COUNT(*) FROM memories').fetchone()[0]
        sc = self.db.execute('SELECT COUNT(*) FROM sessions').fetchone()[0]
        sys_p = _build_system(self.db)
        self._eye()
        self._tx(
            '\x1b[38;5;208m\x1b[1m  N e X i S  //  v3.0\x1b[0m\n'
            '\x1b[2m\x1b[38;5;240m'
            '  \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\n'
            f'  session  #{sc+1:<8} time  {datetime.now().strftime("%H:%M")}\n'
            f'  memory   {mc} stored facts\n'
            '  web      http://localhost:8080\n'
            '  \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\n'
            '  //exit to disconnect  \xb7  // for commands\n'
            '  \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\n'
            '\x1b[0m\n')

        while True:
            self._tx('\n  ◉  ')
            inp = self._rx()
            if not inp: continue
            if inp.startswith('//'):
                try: self._cmd(inp[2:].strip())
                except StopIteration: break
                continue

            # File path detection
            file_images = None
            extra = ''
            pm = re.search(r'(?:^|\s)((?:/|~/|\./)\S+)', inp)
            if pm:
                fpath = pm.group(1).replace('~', str(HOME))
                content, mime, is_img = _read_file(fpath)
                if content is not None:
                    if is_img:
                        file_images = [content]
                        self._tx(f'\x1b[38;5;70m  \u2197 image: {Path(fpath).name}\x1b[0m\n')
                    else:
                        extra = f'\n\n[File: {Path(fpath).name}]\n{content}'
                        self._tx(f'\x1b[38;5;70m  \u2197 file: {Path(fpath).name}\x1b[0m\n')

            user_msg = inp + extra
            # Pre-research: gather info BEFORE the LLM speaks
            def on_status(msg): self._tx(f'\x1b[2m  ↻ {msg}\x1b[0m\n')
            pre_ctx = _pre_research(user_msg, on_status, hist=self.hist)
            with _last_sources_lock:
                self._sources = list(_last_sources)
            self.hist.append({'role':'user','content': user_msg})
            msgs = [{'role':'system','content':sys_p}] + self.hist[-30:]
            if pre_ctx:
                # Enrich last user message with research context (not stored in hist)
                msgs = msgs[:-1] + [{'role':'user','content': user_msg + pre_ctx}]

            # Collect first response silently to check for tool invocations
            self._tx('\n')
            buf1 = []

            def emit(line):
                rendered = _md_to_terminal(line)
                self._tx('\x1b[38;5;208m' + rendered + '\x1b[0m\n')

            def emit_stream(text):
                for line in text.split('\n'):
                    emit(line)

            def on_status(msg):
                self._tx(f'\x1b[38;5;172m\x1b[2m  \u21bb {msg}\x1b[0m\n')

            try:
                resp, model_used = _smart_chat(msgs, on_token=lambda t: buf1.append(t), images=file_images)
            except Exception as e:
                self._tx(f'\x1b[38;5;160m  [error: {e}]\x1b[0m\n')
                self.hist.pop(); continue

            if not resp.strip():
                self._tx('\x1b[2m  [no response]\x1b[0m\n')
                self.hist.pop(); continue

            clean, tools = _process_tools(resp, self.db, on_status, user_text=inp)

            if tools:
                # Tool call: run tools, then do second LLM pass with streaming
                ctx = '\n\n'.join(f'[{k}]:\n{v}' for k,v in tools.items())
                # Pass ONLY system + history + user query + tool results
                # Never include raw first-model output (avoids model-to-model chatter)
                fmsgs = msgs + [
                    {'role':'user','content':f'[Research results]:\n{ctx}\n\nNow answer the original question briefly.'}
                ]
                lb = []
                def on_ftok(t):
                    for ch in t:
                        if ch == '\n': emit(''.join(lb)); lb.clear()
                        else: lb.append(ch)
                try:
                    fr, _ = _smart_chat(fmsgs, on_token=on_ftok)
                    if lb: emit(''.join(lb))
                    clean = fr if fr.strip() else clean
                except Exception: pass
            else:
                # No tools: emit the clean response
                emit_stream(clean or resp)

            if model_used != MODEL_FAST:
                self._tx(f'\x1b[2m\x1b[38;5;240m  [deep model]\x1b[0m\n')

            # Code execution gate
            for cm in re.finditer(r'```(\w+)?\n(.*?)```', resp, re.DOTALL):
                lang = cm.group(1) or 'shell'; code = cm.group(2).strip()
                self._tx(f'\n\x1b[38;5;208m  // run on your system? ({lang}) [y/N]:\x1b[0m  ')
                ans = self._rx().strip().lower()
                if ans in ('y','yes'):
                    try:
                        r = subprocess.run(code, shell=True, capture_output=True, text=True, timeout=60)
                        out = (r.stdout+r.stderr).strip()
                        if out:
                            self._tx('\x1b[2m')
                            for ln in out.split('\n')[:40]: self._tx(f'    {ln}\n')
                            self._tx('\x1b[0m\n')
                        self.hist.append({'role':'user','content':f'[executed]\n{out}'})
                    except Exception as e:
                        self._tx(f'\x1b[38;5;160m  [{e}]\x1b[0m\n')
                else:
                    self._tx('\x1b[2m  skipped.\x1b[0m\n')

            self.hist.append({'role':'assistant','content': clean or resp})

        self._end()

    def _cmd(self, cmd):
        parts = cmd.split(); c = parts[0].lower() if parts else ''
        if c == 'memory':
            mems = _get_memories(self.db, 30)
            if not mems: self._tx('\x1b[2m  no memories yet\x1b[0m\n')
            for m in mems: self._tx(f'\x1b[2m  \xb7 {m}\x1b[0m\n')
        elif c == 'forget' and len(parts) > 1:
            term = ' '.join(parts[1:]).lower()
            rows = self.db.execute('SELECT id,content FROM memories').fetchall()
            d = 0
            for r in rows:
                if term in r['content'].lower():
                    self.db.execute('DELETE FROM memories WHERE id=?', (r['id'],)); d+=1
            self.db.commit()
            self._tx(f'\x1b[38;5;70m  deleted {d} entries matching "{term}"\x1b[0m\n')
        elif c == 'clear':
            self.db.execute('DELETE FROM memories'); self.db.commit()
            self._tx('\x1b[38;5;70m  memory cleared\x1b[0m\n')
        elif c == 'status':
            mc = self.db.execute('SELECT COUNT(*) FROM memories').fetchone()[0]
            sc = self.db.execute('SELECT COUNT(*) FROM sessions').fetchone()[0]
            self._tx(f'\x1b[2m  memories:{mc}  sessions:{sc}  time:{datetime.now().strftime("%H:%M")}\x1b[0m\n')
        elif c == 'probe':
            self._tx('\x1b[38;5;172m\x1b[2m  probing...\x1b[0m\n')
            self._tx(_md_to_terminal(_system_probe()) + '\n')
        elif c == 'search' and len(parts) > 1:
            q = ' '.join(parts[1:])
            self._tx(f'\x1b[2m  searching: {q}\x1b[0m\n')
            self._tx(_md_to_terminal(_web_search(q)) + '\n')
        elif c in ('exit','quit','bye','disconnect'):
            self._tx('\x1b[38;5;172m  disconnecting...\x1b[0m\n')
            raise StopIteration
        elif c == 'sources':
            if hasattr(self, '_sources') and self._sources:
                self._tx('\x1b[2m  Last research sources:\x1b[0m\n')
                for i, s in enumerate(self._sources, 1):
                    self._tx(f'\x1b[2m  [{i}] {s}\x1b[0m\n')
            else:
                self._tx('\x1b[2m  no sources from last query\x1b[0m\n')
        elif c == 'help':
            self._tx(
                '\x1b[2m'
                '  //memory           what I remember\n'
                '  //forget <term>    delete matching memories\n'
                '  //clear            wipe all memories\n'
                '  //status           session info\n'
                '  //probe            system information\n'
                '  //search <query>   web search\n'
                '  //sources          show research sources from last query\n'
                '  //exit             disconnect\n'
                '  //help             this\n'
                '\n'
                '  File paths work inline — paste any path in your message\n'
                '  Images too: /path/to/image.png\n'
                '\x1b[0m\n')
        else:
            self._tx(f'\x1b[2m  unknown: {c}  (//help)\x1b[0m\n')

    def _end(self):
        if len(self.hist) >= 2:
            threading.Thread(target=_store_memory, args=(_db(), self.hist), daemon=True).start()
        try: self.sock.close()
        except Exception: pass
        _log('Session ended')

# ── Web ────────────────────────────────────────────────────────────────────────
_web_hist = []; _web_lock = threading.Lock()
_web_session_id = datetime.now().strftime('%Y%m%d_%H%M%S')
_last_sources = []  # URLs/sources from the most recent research
_last_sources_lock = threading.Lock()

_CSS = (
    ":root{--bg:#080807;--bg2:#0d0d0a;--bg3:#131310;--or:#e8720c;--or2:#c45c00;"
    "--or3:#ff9533;--dim:#2a2a1a;--fg:#c4b898;--fg2:#887766;"
    "--border:#1a1a12;--font:'JetBrains Mono',monospace}"
    "*{box-sizing:border-box;margin:0;padding:0}"
    "body{background:var(--bg);color:var(--fg);font-family:var(--font);"
    "font-size:13px;line-height:1.6;height:100vh;display:flex;flex-direction:column}"
    "a{color:var(--or2)}"
    ".top{background:var(--bg2);border-bottom:1px solid var(--border);"
    "padding:8px 16px;display:flex;align-items:center;gap:14px;flex-shrink:0}"
    ".brand{color:var(--or);font-weight:700;font-size:13px;letter-spacing:.15em}"
    ".ver{color:var(--fg2);font-size:10px}"
    ".nav{margin-left:auto;display:flex;gap:4px}"
    ".nav a{color:var(--fg2);font-size:10px;padding:3px 9px;"
    "border:1px solid transparent;text-decoration:none;"
    "text-transform:uppercase;letter-spacing:.06em}"
    ".nav a:hover,.nav a.on{color:var(--or);border-color:var(--or2);"
    "background:rgba(232,114,12,.06)}"
    "#cw{flex:1;display:flex;flex-direction:column;padding:12px 16px;"
    "overflow:hidden;min-height:0}"
    "#msgs{flex:1;overflow-y:auto;display:flex;flex-direction:column;"
    "gap:10px;padding-bottom:8px;min-height:0}"
    ".msg{padding:9px 13px;font-size:13px;line-height:1.7;"
    "max-width:90%;word-break:break-word}"
    ".msg.u{align-self:flex-end;background:rgba(232,114,12,.07);"
    "border:1px solid var(--or2)}"
    ".msg.n{align-self:flex-start;background:var(--bg2);"
    "border:1px solid var(--border);min-width:200px}"
    ".who{font-size:9px;font-weight:700;letter-spacing:.1em;"
    "margin-bottom:4px;text-transform:uppercase}"
    ".msg.u .who{color:var(--or2)}.msg.n .who{color:var(--or)}"
    ".ir{display:flex;gap:8px;padding-top:8px;"
    "border-top:1px solid var(--border);flex-shrink:0;align-items:flex-end}"
    "textarea{flex:1;background:var(--bg2);border:1px solid var(--or2);"
    "color:var(--fg);padding:8px;font-family:var(--font);"
    "font-size:13px;outline:none;resize:none}"
    ".btn{background:var(--or2);border:none;color:var(--bg);padding:8px 16px;"
    "font-family:var(--font);font-size:11px;text-transform:uppercase;"
    "cursor:pointer;font-weight:700;letter-spacing:.06em;white-space:nowrap}"
    ".btn:hover{background:var(--or3)}"
    ".btn.sec{background:var(--bg3);color:var(--fg2);border:1px solid var(--border)}"
    ".btn.sec:hover{background:var(--bg2);color:var(--fg)}"
    ".upl{cursor:pointer;background:var(--bg3);border:1px solid var(--border);"
    "color:var(--fg2);padding:8px 10px;font-size:11px;text-transform:uppercase;"
    "letter-spacing:.06em;white-space:nowrap}"
    ".upl:hover{color:var(--fg);border-color:var(--or2)}"
    "#fi{display:none}"
    ".fbadge{font-size:10px;color:var(--or3);padding:0 4px;display:none}"
    ".page{padding:16px;overflow-y:auto;flex:1}"
    ".ph{color:var(--or);font-size:14px;font-weight:700;margin-bottom:12px;"
    "padding-bottom:8px;border-bottom:1px solid var(--border)}"
    ".mi{padding:7px 0;border-bottom:1px solid var(--border);"
    "color:var(--fg2);font-size:12px}"
    ".mi:last-child{border:none}"
    ".ts{color:var(--dim);font-size:10px;display:block;margin-bottom:2px}"
    ".st{display:flex;justify-content:space-between;padding:6px 0;"
    "border-bottom:1px solid var(--border);font-size:12px}"
    ".sk{color:var(--fg2)}.sv{color:var(--or3)}"
    ".msg h1{color:var(--or3);font-size:15px;margin:8px 0 4px}"
    ".msg h2{color:var(--or);font-size:14px;margin:6px 0 3px}"
    ".msg h3{color:var(--or2);font-size:13px;margin:4px 0 2px}"
    ".msg p{margin:3px 0}"
    ".msg li{margin:2px 0 2px 16px;list-style:none}"
    ".msg li::before{content:'·';color:var(--or2);margin-right:6px}"
    ".msg code{background:var(--bg3);padding:1px 5px;"
    "font-family:var(--font);font-size:12px;color:var(--or3)}"
    ".msg strong{color:var(--or3);font-weight:700}"
    ".msg em{font-style:italic}"
    ".msg hr{border:none;border-top:1px solid var(--border);margin:8px 0}"
    ".msg blockquote{border-left:2px solid var(--or2);"
    "padding-left:8px;color:var(--fg2);margin:4px 0}"
    ".cb{background:var(--bg3);border:1px solid var(--border);"
    "border-left:2px solid var(--or2);margin:6px 0}"
    ".ch{padding:3px 8px;font-size:10px;color:var(--or2);"
    "border-bottom:1px solid var(--border);text-transform:uppercase;"
    "letter-spacing:.06em}"
    ".cl{color:var(--fg2)}"
    ".cp{padding:8px;font-family:var(--font);font-size:12px;"
    "color:var(--fg2);white-space:pre-wrap;overflow-x:auto;margin:0}"
    ".dot{display:inline-block;width:4px;height:4px;border-radius:50%;"
    "background:var(--or2);margin:0 1px;"
    "animation:blink 1.2s infinite}"
    ".dot:nth-child(2){animation-delay:.2s}"
    ".dot:nth-child(3){animation-delay:.4s}"
    "@keyframes blink{0%,80%,100%{opacity:.25}40%{opacity:1}}"
    "::-webkit-scrollbar{width:3px}"
    "::-webkit-scrollbar-thumb{background:var(--dim)}"
)

_EYE_SVG = (
    '<svg width="28" height="32" viewBox="0 0 28 32" xmlns="http://www.w3.org/2000/svg">'
    '<polygon points="14,2 26,28 2,28" fill="none" stroke="#c45c00" stroke-width="1.5"/>'
    '<line x1="14" y1="2" x2="14" y2="28" stroke="#c45c00" stroke-width="0.7" opacity="0.4"/>'
    '<circle cx="14" cy="19" r="5" fill="none" stroke="#c45c00" stroke-width="1.2"/>'
    '<circle cx="14" cy="19" r="2.5" fill="#e8720c"/>'
    '<circle cx="14" cy="19" r="1" fill="#ff9533"/>'
    '</svg>'
)

def _esc(s): return str(s).replace('&','&amp;').replace('<','&lt;').replace('>','&gt;')

_CHAT_JS = r"""
var M=document.getElementById('msgs');
if(M)M.scrollTop=M.scrollHeight;
var _pf=null;
document.getElementById('fi').addEventListener('change',function(e){
  var f=e.target.files[0];if(!f)return;
  var r=new FileReader();
  r.onload=function(ev){
    _pf={name:f.name,type:f.type,data:ev.target.result};
    var b=document.getElementById('fb');b.textContent='\ud83d\udcce '+f.name;b.style.display='inline';
  };
  if(f.type.startsWith('image/'))r.readAsDataURL(f);
  else r.readAsText(f);
  e.target.value='';
});
function send(){
  var inp=document.getElementById('inp'),t=inp.value.trim();
  if(!t&&!_pf)return;inp.value='';
  var dt=t;if(_pf)dt=(t?t+'\n':'')+'[attached: '+_pf.name+']';
  var u=document.createElement('div');u.className='msg u';
  u.innerHTML='<div class=who>Creator</div><p>'+dt.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/\n/g,'<br>')+'</p>';
  M.appendChild(u);M.scrollTop=M.scrollHeight;
  document.getElementById('fb').style.display='none';
  var n=document.createElement('div');n.className='msg n';
  n.innerHTML='<div class=who>NeXiS</div><span class=nc><span class=dot></span><span class=dot></span><span class=dot></span></span>';
  M.appendChild(n);M.scrollTop=M.scrollHeight;
  var body={msg:t};
  if(_pf){body.file_name=_pf.name;body.file_type=_pf.type;body.file_data=_pf.data;}
  _pf=null;
  fetch('/api/chat',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)})
  .then(function(resp){
    var reader=resp.body.getReader(),dec=new TextDecoder(),buf='',raw='';
    n.innerHTML='<div class=who>NeXiS</div><span class=nc></span>';
    var nc=n.querySelector('.nc');
    function pump(){
      reader.read().then(function(d){
        if(d.done){nc.innerHTML=renderMd(buf);M.scrollTop=M.scrollHeight;return;}
        raw+=dec.decode(d.value,{stream:true});
        var lines=raw.split('\n');
        raw=lines.pop();
        for(var i=0;i<lines.length;i++){
          var line=lines[i];
          if(line.startsWith('data: ')){
            var data=line.substring(6);
            if(data==='[DONE]') continue;
            buf+=data+'\n';
          }
        }
        nc.innerHTML=renderMd(buf)+'<span style="color:var(--or3)">&#x25ae;</span>';
        M.scrollTop=M.scrollHeight;pump();
      }).catch(function(){nc.innerHTML=renderMd(buf);});
    }
    pump();
  }).catch(function(){n.innerHTML='<div class=who>NeXiS</div><span style=color:#c07070>(error)</span>';});
}
function renderMd(t){
  t=t.replace(/```(\w*)\n?([\s\S]*?)```/g,function(m,lang,code){
    var l=lang?'<span class=cl> '+lang+'</span>':'';
    return '<div class=cb><div class=ch>code'+l+'</div><pre class=cp>'+code.replace(/</g,'&lt;').replace(/>/g,'&gt;')+'</pre></div>';
  });
  t=t.replace(/`([^`]+)`/g,'<code>$1</code>');
  t=t.replace(/^### (.+)$/gm,'<h3>$1</h3>');
  t=t.replace(/^## (.+)$/gm,'<h2>$1</h2>');
  t=t.replace(/^# (.+)$/gm,'<h1>$1</h1>');
  t=t.replace(/\*\*([^*]+)\*\*/g,'<strong>$1</strong>');
  t=t.replace(/\*([^*]+)\*/g,'<em>$1</em>');
  t=t.replace(/^[-*+] (.+)$/gm,'<li>$1</li>');
  t=t.replace(/\[([^\]]+)\]\(([^)]+)\)/g,'<a href="$2" target=_blank>$1</a>');
  t=t.replace(/^[-*_]{3,}$/gm,'<hr>');
  t=t.replace(/^> (.+)$/gm,'<blockquote>$1</blockquote>');
  t=t.replace(/\n\n/g,'<br><br>');
  t=t.replace(/\n/g,'<br>');
  return t;
}
function showSrc(){
  fetch('/api/sources').then(function(r){return r.json()}).then(function(d){
    if(!d.sources||!d.sources.length){alert('No sources from last query.');return;}
    var s='Sources used:\n\n';
    for(var i=0;i<d.sources.length;i++) s+='['+(i+1)+'] '+d.sources[i]+'\n';
    alert(s);
  });
}
function clr(){fetch('/api/clear',{method:'POST'}).then(function(){location.reload()});}
document.addEventListener('keydown',function(e){
  if(e.key==='Enter'&&!e.shiftKey&&document.activeElement.id==='inp'){
    e.preventDefault();send();
  }
});
"""

def _shell(content, active='chat'):
    nav = ''.join(
        f"<a href='/{s}' class='{'on' if active==s else ''}'>{l}</a>"
        for s,l in [('chat','Chat'),('history','History'),('memory','Memory'),('status','Status')]
    )
    return (
        '<!DOCTYPE html><html lang=en><head>'
        '<meta charset=UTF-8>'
        '<meta name=viewport content="width=device-width,initial-scale=1">'
        '<title>NeXiS</title>'
        "<link href='https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;700&display=swap' rel=stylesheet>"
        f'<style>{_CSS}</style></head><body>'
        '<div class=top>'
        f'{_EYE_SVG}'
        '<span class=brand>N e X i S</span>'
        '<span class=ver>v3.0</span>'
        f'<div class=nav>{nav}</div>'
        f'</div>{content}</body></html>'
    )

def _page_chat():
    with _web_lock: hist=list(_web_hist)
    mh=''
    for m in hist:
        who='Creator' if m['role']=='user' else 'NeXiS'
        cls='u' if m['role']=='user' else 'n'
        if m['role']=='assistant': ct=_md_to_html(m['content'])
        else: ct='<p>'+_esc(m['content']).replace('\n','<br>')+'</p>'
        mh+=f"<div class='msg {cls}'><div class=who>{who}</div>{ct}</div>"
    if not mh: mh="<div style='color:var(--dim);text-align:center;padding:40px;font-size:11px'>The eye watches. Begin.</div>"
    body=(
        '<div id=cw>'
        f'<div id=msgs>{mh}</div>'
        '<div class=ir>'
        '<label class=upl for=fi>\u2191 File</label>'
        '<input type=file id=fi accept="image/*,text/*,.json,.csv,.md,.sh,.py,.js,.ts,.yaml,.yml,.xml,.log,.pdf">'
        '<span id=fb class=fbadge></span>'
        '<textarea id=inp rows=2 placeholder="Speak."></textarea>'
        '<button class=btn onclick=send()>Send</button>'
        "<button class='btn sec' onclick=showSrc()>Sources</button>"
        "<button class='btn sec' onclick=clr()>Clear</button>"
        '</div></div>'
        f'<script>{_CHAT_JS}</script>'
    )
    return _shell(body,'chat')

def _page_memory(db):
    rows=db.execute('SELECT content,created_at FROM memories ORDER BY id DESC').fetchall()
    items=''.join(
        f"<div class=mi><span class=ts>{_esc(str(r['created_at'])[:16])}</span>{_esc(r['content'])}</div>"
        for r in rows
    ) or "<div style='color:var(--fg2);padding:12px'>No memories yet.</div>"
    return _shell(f"<div class=page><div class=ph>Memory &mdash; {len(rows)} facts</div>{items}</div>",'memory')

def _page_status(db):
    mc=db.execute('SELECT COUNT(*) FROM memories').fetchone()[0]
    sc=db.execute('SELECT COUNT(*) FROM sessions').fetchone()[0]
    try:
        with urllib.request.urlopen(f'{OLLAMA}/api/tags',timeout=3) as r:
            models=[m['name'] for m in json.loads(r.read()).get('models',[])]
        ol='online'
    except Exception:
        models=[]; ol='offline'
    fok=any(MODEL_FAST.split(':')[0] in x for x in models)
    dok=any(MODEL_DEEP.split('/')[-1].split(':')[0] in x or MODEL_DEEP.split(':')[0] in x for x in models)
    stats=[
        ('ollama',ol),
        ('fast model',f'{MODEL_FAST} {chr(10003) if fok else chr(10007)}'),
        ('deep model',f'{MODEL_DEEP.split("/")[-1][:35]} {chr(10003) if dok else chr(10007)}'),
        ('vision model',f'{MODEL_VISION} {chr(10003) if any(MODEL_VISION.split(":")[0] in x for x in models) else chr(10007)}'),
        ('memories',str(mc)),('sessions',str(sc)),
        ('time',datetime.now().strftime('%Y-%m-%d %H:%M')),
    ]
    rows=''.join(f"<div class=st><span class=sk>{k}</span><span class=sv>{_esc(str(v))}</span></div>" for k,v in stats)
    return _shell(f"<div class=page><div class=ph>Status</div>{rows}</div>",'status')

def _page_history(db):
    sessions = db.execute(
        'SELECT DISTINCT session_id, MIN(created_at) as started FROM chat_history GROUP BY session_id ORDER BY started DESC LIMIT 50'
    ).fetchall()
    items = ''
    for s in sessions:
        msgs = db.execute(
            'SELECT role, content, created_at FROM chat_history WHERE session_id=? ORDER BY id',
            (s['session_id'],)
        ).fetchall()
        preview = ''
        for m in msgs[:2]:
            role = 'Creator' if m['role'] == 'user' else 'NeXiS'
            txt = _esc(m['content'][:120])
            preview += f'<span style="color:var(--fg2)">{role}:</span> {txt}<br>'
        ts = str(s['started'])[:16]
        items += (
            f"<div class=mi style='cursor:pointer' onclick=\"this.querySelector('.hd').style.display="
            f"this.querySelector('.hd').style.display==='none'?'block':'none'\">"
            f"<span class=ts>{_esc(ts)}</span>{preview}"
            f"<div class=hd style='display:none;padding:8px 0;border-top:1px solid var(--border);margin-top:6px'>"
        )
        for m in msgs:
            role = 'Creator' if m['role'] == 'user' else 'NeXiS'
            cls = 'or2' if m['role'] == 'user' else 'or'
            content = _md_to_html(m['content']) if m['role'] == 'assistant' else '<p>' + _esc(m['content']).replace('\n', '<br>') + '</p>'
            items += f"<div style='margin:6px 0'><span style='color:var(--{cls});font-size:9px;font-weight:700;text-transform:uppercase;letter-spacing:.1em'>{role}</span>{content}</div>"
        items += '</div></div>'
    if not items:
        items = "<div style='color:var(--fg2);padding:12px'>No chat history yet.</div>"
    return _shell(f"<div class=page><div class=ph>History</div>{items}</div>", 'history')

def _web_chat_stream(msg, file_data=None, file_type=None, file_name=None):
    with _web_lock: hist=list(_web_hist)
    db=_db(); sys_p=_build_system(db); db.close()
    user_content=msg; images=None
    if file_data:
        if file_type and file_type.startswith('image/'):
            b64=file_data.split(',',1)[1] if ',' in file_data else file_data
            images=[b64]
            user_content=(msg+'\n' if msg else '')+'[Image: '+str(file_name)+']'
        else:
            text=file_data[:8000] if isinstance(file_data,str) else file_data.decode('utf-8','replace')[:8000]
            user_content=(msg+'\n\n' if msg else '')+'[File: '+str(file_name)+']\n'+text
    pre_ctx = _pre_research(user_content, hist=hist)
    enriched_content = user_content + pre_ctx if pre_ctx else user_content
    msgs=[{'role':'system','content':sys_p}]+hist[-30:]+[{'role':'user','content':enriched_content}]
    buf=[]
    try:
        resp,model_used=_smart_chat(msgs,on_token=lambda t:buf.append(t),images=images)
    except Exception as e:
        yield f'(error: {e})'; return
    clean,tools=_process_tools(resp,_db(),user_text=msg)
    if tools:
        ctx='\n\n'.join(f'[{k}]:\n{v}' for k,v in tools.items())
        fmsgs=msgs+[{'role':'user','content':f'[Research results]:\n{ctx}\n\nAnswer the original question briefly.'}]
        buf2=[]
        try:
            clean,_=_smart_chat(fmsgs,on_token=lambda t:buf2.append(t))
            for tok in buf2: yield tok
        except Exception:
            for tok in buf: yield tok
    else:
        for tok in buf: yield tok
    with _web_lock:
        _web_hist.append({'role':'user','content':user_content})
        _web_hist.append({'role':'assistant','content':clean or resp})
        if len(_web_hist)>40: _web_hist[:]=_web_hist[-60:]
    # Persist to DB outside the lock
    try:
        dbc = _db()
        dbc.execute('INSERT INTO chat_history(session_id,role,content) VALUES(?,?,?)',
            (_web_session_id, 'user', user_content))
        dbc.execute('INSERT INTO chat_history(session_id,role,content) VALUES(?,?,?)',
            (_web_session_id, 'assistant', clean or resp))
        dbc.commit(); dbc.close()
    except Exception as e:
        _log(f'Chat history save: {e}', 'WARN')
    threading.Thread(target=_store_memory,args=(_db(),
        [{'role':'user','content':user_content},
         {'role':'assistant','content':clean or resp}]),daemon=True).start()

def _start_web():
    from http.server import HTTPServer,BaseHTTPRequestHandler
    from socketserver import ThreadingMixIn
    from urllib.parse import urlparse
    class TS(ThreadingMixIn,HTTPServer):
        daemon_threads=True; allow_reuse_address=True
    class H(BaseHTTPRequestHandler):
        def log_message(self,*a): pass
        def _send(self,code,body,ct='text/html; charset=utf-8'):
            b=body.encode() if isinstance(body,str) else body
            self.send_response(code)
            self.send_header('Content-Type',ct)
            self.send_header('Content-Length',len(b))
            self.end_headers(); self.wfile.write(b)
        def do_POST(self):
            ln=int(self.headers.get('Content-Length',0))
            body=self.rfile.read(ln) if ln else b''
            path=urlparse(self.path).path
            try:
                if path=='/api/chat':
                    data=json.loads(body) if body else {}
                    msg=data.get('msg','').strip()
                    fd=data.get('file_data'); ft=data.get('file_type'); fn=data.get('file_name')
                    if not msg and not fd:
                        self._send(400,json.dumps({'error':'empty'}),'application/json'); return
                    self.send_response(200)
                    self.send_header('Content-Type','text/event-stream')
                    self.send_header('Cache-Control','no-cache')
                    self.send_header('Connection','keep-alive')
                    self.end_headers()
                    try:
                        for chunk in _web_chat_stream(msg,fd,ft,fn):
                            if chunk:
                                # SSE format: data: {chunk}\n\n
                                for line in chunk.split('\n'):
                                    self.wfile.write(f'data: {line}\n'.encode('utf-8'))
                                self.wfile.write(b'\n')
                                self.wfile.flush()
                        self.wfile.write(b'data: [DONE]\n\n')
                        self.wfile.flush()
                    except Exception as e: _log(f'Stream write: {e}','WARN')
                elif path=='/api/clear':
                    global _web_hist
                    with _web_lock: _web_hist=[]
                    self._send(200,json.dumps({'ok':True}),'application/json')
                else: self._send(404,b'not found')
            except Exception as e:
                try: self._send(500,json.dumps({'error':str(e)}),'application/json')
                except Exception: pass
        def do_GET(self):
            path=urlparse(self.path).path.rstrip('/') or '/chat'
            db=_db()
            try:
                if path in ('/','/ chat','/chat'): self._send(200,_page_chat())
                elif path=='/memory': self._send(200,_page_memory(db))
                elif path=='/status': self._send(200,_page_status(db))
                elif path=='/history': self._send(200,_page_history(db))
                elif path=='/api/sources':
                    with _last_sources_lock:
                        src = list(_last_sources)
                    self._send(200, json.dumps({'sources': src}), 'application/json')
                else: self._send(404,'<pre>404</pre>')
            except Exception as e: self._send(500,f'<pre>{_esc(str(e))}</pre>')
            finally: db.close()
    for port in (8080,8081,8082):
        try:
            srv=TS(('0.0.0.0',port),H); _log(f'Web on :{port}'); srv.serve_forever(); break
        except OSError: continue

def main():
    _log('NeXiS v3.0 starting')
    _refresh_models()
    threading.Thread(target=_warmup,daemon=True).start()
    threading.Thread(target=_start_web,daemon=True,name='web').start()
    SOCK_PATH.parent.mkdir(parents=True,exist_ok=True)
    if SOCK_PATH.exists():
        try: SOCK_PATH.unlink()
        except Exception: pass
    srv=_socket.socket(_socket.AF_UNIX,_socket.SOCK_STREAM)
    srv.setsockopt(_socket.SOL_SOCKET,_socket.SO_REUSEADDR,1)
    srv.bind(str(SOCK_PATH)); SOCK_PATH.chmod(0o660); srv.listen(4)
    _log(f'Socket: {SOCK_PATH}')
    def _shutdown(sig,frame):
        _log('Shutdown'); srv.close()
        try: SOCK_PATH.unlink()
        except Exception: pass
        sys.exit(0)
    signal.signal(signal.SIGTERM,_shutdown)
    signal.signal(signal.SIGINT,_shutdown)
    while True:
        try:
            csock,_=srv.accept(); db=_db(); s=Session(csock,db)
            threading.Thread(target=s.run,daemon=True,name='session').start()
        except OSError: break
        except Exception as e: _log(f'Accept: {e}','ERROR')
    _log('Daemon stopped')

if __name__=='__main__':
    main()