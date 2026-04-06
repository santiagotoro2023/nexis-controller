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
    try:
        q = urllib.parse.quote_plus(query)
        url = f'https://www.google.com/search?q={q}&num=8&hl=en'
        req = urllib.request.Request(url, headers={
            'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
            'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            'Accept-Language': 'en-US,en;q=0.5',
        })
        with urllib.request.urlopen(req, timeout=15) as r:
            html = r.read().decode('utf-8', errors='replace')
        results = []
        # Google: h3 = title, following span/div = snippet
        blocks = re.findall(
            r'<h3[^>]*>(.*?)</h3>.*?<span[^>]*>([^<]{30,})</span>',
            html, re.DOTALL)
        for title_r, snip_r in blocks[:max_results * 3]:
            title = re.sub(r'<[^>]+>', '', title_r).strip()
            snip  = re.sub(r'<[^>]+>', '', snip_r).strip()
            for e, c in [('&amp;','&'),('&lt;','<'),('&gt;','>'),
                         ('&quot;','"'),('&#x27;',"'"),('&nbsp;',' ')]:
                title = title.replace(e,c); snip = snip.replace(e,c)
            if title and snip and len(title) > 5 and len(snip) > 20:
                results.append(f'**{title}**\n{snip}')
            if len(results) >= max_results:
                break
        return '\n\n'.join(results) if results else f'No results for: {query}'
    except Exception as e:
        return f'Search failed: {e}'

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
            'Review this conversation and extract two types of memory:\n'
            '1. FACTS: Concrete things the Creator explicitly stated about themselves, their setup, preferences, or context.\n'
            '2. TOPICS: Key subjects or knowledge areas discussed (e.g. "Discussed WDS and MDT deployment", "Discussed IPv6 vs IPv4").\n'
            'Rules: No inference. No generic statements like "user prefers concise answers".\n'
            'Each line starts with "- ". Max 6 lines total. No preamble.\n'
            'If nothing worth storing, respond exactly: none\n\n' + convo}],
            temperature=0.1, num_ctx=1024)
        if not raw or raw.strip().lower() == 'none': return
        stored = 0
        for line in raw.splitlines():
            line = line.strip().lstrip('- ').strip()
            if len(line) < 15: continue
            SKIP = ['prefers concise','values utility','aims for','assistant aligns',
                    'creator communicates','creator values learning','creator interacts',
                    'creator expects','creator requests','creator prefers',
                    'requests elaboration','expects research','prefers explicit',
                    'actions be taken','serves with','precise and efficient',
                    'aligned with','creator instructs']
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


def _youtube_latest(query):
    """Find latest YouTube videos via Google search."""
    results = []
    # Search 1: direct latest videos query
    for search_q in [f'{query} latest videos site:youtube.com', f'{query} youtube channel videos']:
        try:
            q = urllib.parse.quote_plus(search_q)
            req = urllib.request.Request(
                f'https://www.google.com/search?q={q}&num=6&hl=en',
                headers={
                    'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
                    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                    'Accept-Language': 'en-US,en;q=0.5',
                })
            with urllib.request.urlopen(req, timeout=15) as resp:
                html = resp.read().decode('utf-8', errors='replace')
            # Extract titles and snippets
            for title_r, snip_r in re.findall(
                    r'<h3[^>]*>(.*?)</h3>.*?<span[^>]*>([^<]{20,})</span>', html, re.DOTALL)[:5]:
                title = re.sub(r'<[^>]+>', '', title_r).strip()
                snip  = re.sub(r'<[^>]+>', '', snip_r).strip()
                for e, c in [('&amp;','&'),('&lt;','<'),('&gt;','>'),('&quot;','"'),('&#x27;',"'"),('&nbsp;',' ')]:
                    title = title.replace(e,c); snip = snip.replace(e,c)
                if title and len(title) > 5:
                    results.append(f'{title}: {snip}')
            if results:
                break
        except Exception:
            continue
    return '\n'.join(results[:5])


def _pre_research(text, on_status=None):
    """Run searches/fetches BEFORE the LLM call and return a context block."""
    results = []

    # 1. Fetch any URLs in the message
    urls = re.findall(r'https?://[^\s\]>),"]+', text)
    for url in urls[:2]:
        if on_status: on_status(f'fetching: {url[:55]}')
        r = _fetch_url(url)
        if r and not r.startswith('Fetch failed'):
            results.append(f'[Fetched {url[:60]}]:\n{r[:3000]}')

    # 2. YouTube queries
    if re.search(r'youtube|youtu\.be|yt\.be', text, re.IGNORECASE) and not urls:
        q = re.sub(
            r'(?i)(can you|could you|please|search up|search for|look up|find|tell me|show me|what are|what is|newest|latest|recent videos?|youtube channel|youtube|on youtube)',
            '', text).strip()
        q = re.sub(r'\s+', ' ', q).strip()
        if q and len(q) > 3:
            if on_status: on_status(f'YouTube: {q[:50]}')
            r = _youtube_latest(q)
            if r:
                results.append(f'[YouTube results for "{q}"]:\n{r}')

    # 3. General research triggers (skip if URL already fetched)
    elif not urls:
        needs = re.search(
            r'\b(who is|what is|when did|where is|how (much|many|old|do)|'
            r'latest|newest|recent|current|today|price|version|release|'
            r'score|news|weather|tell me about|find|look up|lookup|search)\b',
            text, re.IGNORECASE)
        if needs:
            # Strip filler from query
            q = re.sub(
                r'(?i)^(hey|hi|please|can you|could you|tell me|find out|look up|search for|give me a|give me)\s+',
                '', text.strip())
            q = re.sub(r'[?!.,]+$', '', q).strip()[:140]
            if len(q) > 6:
                if on_status: on_status(f'searching: {q[:55]}')
                r = _web_search(q)
                if r and not r.startswith(('No results', 'Search failed')):
                    results.append(f'[Search: {q[:60]}]:\n{r[:3000]}')

    if not results:
        return ''
    sep = '\n\n--- Research context (use this; do not quote verbatim) ---\n'
    return sep + '\n\n'.join(results)


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
        '\n\n## Tools'
        '\n- System info: include [PROBE] in response'
        '\n- Open/close/launch apps, notify, clipboard: [DESKTOP: action | argument]'
        '\n  Actions: open, close, launch, notify, clip'
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
        if act == 'open':
            subprocess.Popen(['xdg-open', arg], env=env,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return f'opened: {arg[:60]}'
        elif act == 'close':
            r = subprocess.run(['wmctrl','-c',arg], capture_output=True)
            if r.returncode != 0:
                subprocess.run(['pkill','-f',arg], capture_output=True)
            return f'closed: {arg[:40]}'
        elif act == 'notify':
            subprocess.Popen(['notify-send','NeXiS',arg], env=env,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return 'notified'
        elif act == 'launch':
            import shlex
            subprocess.Popen(shlex.split(arg), env=env,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return f'launched: {arg[:40]}'
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

def _process_tools(text, conn, on_status=None):
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
    for m in re.finditer(r'\[DESKTOP:\s*(\w+)\s*\|\s*([^\]]+)\]', text, re.IGNORECASE):
        tools[m.group(0)] = _desktop(m.group(1), m.group(2))
    clean = text
    for tag in tools: clean = clean.replace(tag, '')
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
            pre_ctx = _pre_research(user_msg, on_status)
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

            clean, tools = _process_tools(resp, self.db, on_status)

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
        elif c == 'help':
            self._tx(
                '\x1b[2m'
                '  //memory           what I remember\n'
                '  //forget <term>    delete matching memories\n'
                '  //clear            wipe all memories\n'
                '  //status           session info\n'
                '  //probe            system information\n'
                '  //search <query>   web search\n'
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
    var reader=resp.body.getReader(),dec=new TextDecoder(),buf='';
    n.innerHTML='<div class=who>NeXiS</div><span class=nc></span>';
    var nc=n.querySelector('.nc');
    function pump(){
      reader.read().then(function(d){
        if(d.done){nc.innerHTML=renderMd(buf);M.scrollTop=M.scrollHeight;return;}
        buf+=dec.decode(d.value,{stream:true});
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
        for s,l in [('chat','Chat'),('memory','Memory'),('status','Status')]
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
    pre_ctx = _pre_research(user_content)
    enriched_content = user_content + pre_ctx if pre_ctx else user_content
    msgs=[{'role':'system','content':sys_p}]+hist[-30:]+[{'role':'user','content':enriched_content}]
    buf=[]
    try:
        resp,model_used=_smart_chat(msgs,on_token=lambda t:buf.append(t),images=images)
    except Exception as e:
        yield f'(error: {e})'; return
    clean,tools=_process_tools(resp,_db())
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
                    self.send_header('Content-Type','text/plain; charset=utf-8')
                    self.send_header('Transfer-Encoding','chunked')
                    self.send_header('Cache-Control','no-cache')
                    self.end_headers()
                    try:
                        for chunk in _web_chat_stream(msg,fd,ft,fn):
                            if chunk:
                                enc=chunk.encode('utf-8','replace')
                                self.wfile.write(f'{len(enc):x}\r\n'.encode())
                                self.wfile.write(enc); self.wfile.write(b'\r\n')
                                self.wfile.flush()
                        self.wfile.write(b'0\r\n\r\n'); self.wfile.flush()
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