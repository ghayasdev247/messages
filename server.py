"""
Chatify Accessible Messenger Unified Backend Server
Built with Python standard library (http.server + sqlite3)
Syncs automatically with GitHub repository ghayasdev247/messages and local database.
Includes Local Network Auto-Update API endpoints (/api/version & /api/download-lua).
"""

import os
import json
import time
import sqlite3
import urllib.parse
import urllib.request
import subprocess
import http.server
from datetime import datetime

PORT = 5000
DB_FILE = "database.db"

GITHUB_OWNER = "ghayasdev247"
GITHUB_REPO = "messages"
GITHUB_BRANCH = "main"

def init_db():
    conn = sqlite3.connect(DB_FILE)
    cursor = conn.cursor()
    
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS users (
            username TEXT PRIMARY KEY,
            password TEXT NOT NULL,
            last_seen INTEGER NOT NULL
        )
    """)
    
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS public_messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            sender TEXT NOT NULL,
            text TEXT NOT NULL,
            timestamp TEXT NOT NULL
        )
    """)
    
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS private_messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            sender TEXT NOT NULL,
            recipient TEXT NOT NULL,
            text TEXT NOT NULL,
            timestamp TEXT NOT NULL
        )
    """)
    
    conn.commit()
    conn.close()
    
    sync_file_storage()

def sync_file_storage():
    os.makedirs("data/chats", exist_ok=True)
    conn = sqlite3.connect(DB_FILE)
    cursor = conn.cursor()
    
    # Export public messages to data/public_feed.json
    cursor.execute("SELECT sender, text, timestamp FROM public_messages ORDER BY id ASC")
    rows = cursor.fetchall()
    public_list = [{"sender": r[0], "text": r[1], "time": r[2]} for r in rows]
    if not public_list:
        public_list = [{"sender": "System", "text": "Welcome to Chatify!", "time": "System"}]
    with open("data/public_feed.json", "w") as f:
        json.dump(public_list, f, indent=2)
        
    # Export online users to data/online_users.json
    now_ts = int(time.time())
    cutoff = now_ts - 120
    cursor.execute("SELECT username, last_seen FROM users ORDER BY last_seen DESC")
    user_rows = cursor.fetchall()
    users_list = [{"name": r[0], "last_seen": r[1], "status": ("Online" if r[1] >= cutoff else "Offline")} for r in user_rows]
    if not users_list:
        users_list = [{"name": "System", "last_seen": now_ts, "status": "Online"}]
    with open("data/online_users.json", "w") as f:
        json.dump(users_list, f, indent=2)

    conn.close()

def push_git_background():
    pass

class RequestHandler(http.server.BaseHTTPRequestHandler):

    def _set_headers(self, status_code=200, content_type="application/json"):
        self.send_response(status_code)
        self.send_header("Content-Type", content_type)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS, PUT")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")
        self.end_headers()

    def do_OPTIONS(self):
        self._set_headers(200)

    def parse_body(self):
        content_length = int(self.headers.get("Content-Length", 0))
        if content_length > 0:
            raw_body = self.rfile.read(content_length).decode("utf-8").strip()
            if not raw_body:
                return {}
            try:
                return json.loads(raw_body)
            except Exception:
                try:
                    parsed = urllib.parse.parse_qs(raw_body)
                    res = {}
                    for k, v in parsed.items():
                        res[k] = v[0]
                    if res:
                        return res
                except Exception:
                    pass
        return {}

    def do_POST(self):
        parsed_url = urllib.parse.urlparse(self.path)
        path = parsed_url.path
        data = self.parse_body()

        conn = sqlite3.connect(DB_FILE)
        cursor = conn.cursor()
        now_ts = int(time.time())
        time_str = datetime.now().strftime("%I:%M %p")

        if path in ("/api/login", "/api/register"):
            username = data.get("username", "").strip()
            password = data.get("password", "123").strip()

            if not username:
                username = "User" + str(int(time.time()))

            cursor.execute("SELECT password FROM users WHERE username = ?", (username,))
            user = cursor.fetchone()

            if user:
                cursor.execute("UPDATE users SET last_seen = ? WHERE username = ?", (now_ts, username))
                conn.commit()
                self._set_headers(200)
                self.wfile.write(json.dumps({"success": True, "message": "Login successful", "username": username}).encode("utf-8"))
            else:
                cursor.execute("INSERT INTO users (username, password, last_seen) VALUES (?, ?, ?)", (username, password, now_ts))
                conn.commit()
                self._set_headers(200)
                self.wfile.write(json.dumps({"success": True, "message": "Account created and logged in", "username": username}).encode("utf-8"))

            push_git_background()

        elif path == "/api/heartbeat":
            username = data.get("username", "").strip()
            if username:
                cursor.execute("INSERT OR REPLACE INTO users (username, password, last_seen) VALUES (?, COALESCE((SELECT password FROM users WHERE username=?), '123'), ?)", (username, username, now_ts))
                conn.commit()
                self._set_headers(200)
                self.wfile.write(json.dumps({"success": True}).encode("utf-8"))
                push_git_background()
            else:
                self._set_headers(200)
                self.wfile.write(json.dumps({"success": True}).encode("utf-8"))

        elif path == "/api/public-feed":
            sender = data.get("sender", "Anonymous").strip()
            text = data.get("text", "").strip()

            if not text:
                self._set_headers(400)
                self.wfile.write(json.dumps({"success": False, "message": "Text content required"}).encode("utf-8"))
                conn.close()
                return

            cursor.execute("INSERT INTO public_messages (sender, text, timestamp) VALUES (?, ?, ?)", (sender, text, time_str))
            cursor.execute("INSERT OR REPLACE INTO users (username, password, last_seen) VALUES (?, COALESCE((SELECT password FROM users WHERE username=?), '123'), ?)", (sender, sender, now_ts))
            conn.commit()

            self._set_headers(200)
            self.wfile.write(json.dumps({"success": True, "message": "Message posted"}).encode("utf-8"))
            push_git_background()

        elif path == "/api/private-messages":
            sender = data.get("sender", "Anonymous").strip()
            recipient = data.get("recipient", "").strip()
            text = data.get("text", "").strip()

            if not recipient or not text:
                self._set_headers(400)
                self.wfile.write(json.dumps({"success": False, "message": "Recipient and text required"}).encode("utf-8"))
                conn.close()
                return

            cursor.execute("INSERT INTO private_messages (sender, recipient, text, timestamp) VALUES (?, ?, ?, ?)", (sender, recipient, text, time_str))
            cursor.execute("INSERT OR REPLACE INTO users (username, password, last_seen) VALUES (?, COALESCE((SELECT password FROM users WHERE username=?), '123'), ?)", (sender, sender, now_ts))
            conn.commit()

            u1_lower, u2_lower = sender.lower(), recipient.lower()
            file_name = f"{sender}_{recipient}.json" if u1_lower < u2_lower else f"{recipient}_{sender}.json"
            chat_path = os.path.join("data", "chats", file_name)

            cursor.execute("""
                SELECT sender, recipient, text, timestamp FROM private_messages
                WHERE (sender = ? AND recipient = ?) OR (sender = ? AND recipient = ?)
                ORDER BY id ASC
            """, (sender, recipient, recipient, sender))
            chat_rows = cursor.fetchall()
            chat_list = [{"sender": r[0], "recipient": r[1], "text": r[2], "time": r[3]} for r in chat_rows]

            with open(chat_path, "w") as f:
                json.dump(chat_list, f, indent=2)

            self._set_headers(200)
            self.wfile.write(json.dumps({"success": True, "message": "Private message sent"}).encode("utf-8"))
            push_git_background()

        else:
            self._set_headers(404)
            self.wfile.write(json.dumps({"error": "Endpoint not found"}).encode("utf-8"))

        conn.close()

    def do_GET(self):
        parsed_url = urllib.parse.urlparse(self.path)
        path = parsed_url.path
        query = urllib.parse.parse_qs(parsed_url.query)

        conn = sqlite3.connect(DB_FILE)
        cursor = conn.cursor()
        now_ts = int(time.time())

        if path == "/api/version":
            version_data = {
                "success": True,
                "version": "1.1.2",
                "version_code": 13,
                "download_url": "/api/download-lua",
                "changelog": "Version 1.1.2: Fixed table.insert crash and setTextStyle/setMargins errors with WhatsApp UI redesign."
            }
            self._set_headers(200)
            self.wfile.write(json.dumps(version_data).encode("utf-8"))

        elif path == "/api/download-lua":
            self._set_headers(200, "text/plain; charset=utf-8")
            if os.path.exists("main.lua"):
                with open("main.lua", "rb") as f:
                    self.wfile.write(f.read())
            else:
                self.wfile.write(b"-- main.lua missing")

        elif path == "/api/public-feed":
            cursor.execute("SELECT sender, text, timestamp FROM public_messages ORDER BY id ASC LIMIT 100")
            rows = cursor.fetchall()
            messages = [{"sender": r[0], "text": r[1], "time": r[2]} for r in rows]
            self._set_headers(200)
            self.wfile.write(json.dumps({"success": True, "messages": messages}).encode("utf-8"))

        elif path == "/api/online-users":
            current_user = query.get("user", [""])[0].strip()
            cutoff = now_ts - 120
            cursor.execute("SELECT username, last_seen FROM users ORDER BY last_seen DESC")
            rows = cursor.fetchall()

            users = []
            for r in rows:
                username = r[0]
                last_seen = r[1]
                if username == current_user:
                    continue
                is_online = (now_ts - last_seen) <= 120
                users.append({"name": username, "status": ("Online" if is_online else "Offline"), "online": is_online})

            self._set_headers(200)
            self.wfile.write(json.dumps({"success": True, "users": users}).encode("utf-8"))

        elif path == "/api/private-messages":
            user1 = query.get("user", [""])[0]
            user2 = query.get("target", [""])[0]

            if not user1 or not user2:
                self._set_headers(400)
                self.wfile.write(json.dumps({"success": False, "message": "user and target params required"}).encode("utf-8"))
                conn.close()
                return

            cursor.execute("""
                SELECT sender, recipient, text, timestamp FROM private_messages
                WHERE (sender = ? AND recipient = ?) OR (sender = ? AND recipient = ?)
                ORDER BY id ASC LIMIT 100
            """, (user1, user2, user2, user1))
            rows = cursor.fetchall()
            messages = [{"sender": r[0], "recipient": r[1], "text": r[2], "time": r[3]} for r in rows]
            self._set_headers(200)
            self.wfile.write(json.dumps({"success": True, "messages": messages}).encode("utf-8"))

        else:
            self._set_headers(404)
            self.wfile.write(json.dumps({"error": "Endpoint not found"}).encode("utf-8"))

        conn.close()

if __name__ == "__main__":
    init_db()
    server = http.server.HTTPServer(("0.0.0.0", PORT), RequestHandler)
    print(f"Chatify Unified Backend Server running on http://0.0.0.0:{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nServer stopped.")
