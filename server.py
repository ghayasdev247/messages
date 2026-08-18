"""
Chatify Accessible Messenger Backend Server
Built with Python standard library (http.server + sqlite3)
Zero external dependencies required.
Supports online/offline status, public feed, 1-on-1 private messaging, and CORS.
"""

import http.server
import json
import sqlite3
import time
import urllib.parse
from datetime import datetime

PORT = 5000
DB_FILE = "database.db"

def init_db():
    conn = sqlite3.connect(DB_FILE)
    cursor = conn.cursor()
    
    # Users table
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS users (
            username TEXT PRIMARY KEY,
            password TEXT NOT NULL,
            last_seen INTEGER NOT NULL
        )
    """)
    
    # Public messages table
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS public_messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            sender TEXT NOT NULL,
            text TEXT NOT NULL,
            timestamp TEXT NOT NULL
        )
    """)
    
    # Private messages table
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

class RequestHandler(http.server.BaseHTTPRequestHandler):

    def _set_headers(self, status_code=200):
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_OPTIONS(self):
        self._set_headers(200)

    def parse_body(self):
        content_length = int(self.headers.get("Content-Length", 0))
        if content_length > 0:
            body = self.rfile.read(content_length).decode("utf-8")
            try:
                return json.loads(body)
            except json.JSONDecodeError:
                parsed = urllib.parse.parse_qs(body)
                return {k: v[0] for k, v in parsed.items()}
        return {}

    def do_POST(self):
        parsed_url = urllib.parse.urlparse(self.path)
        path = parsed_url.path
        data = self.parse_body()

        conn = sqlite3.connect(DB_FILE)
        cursor = conn.cursor()
        now_ts = int(time.time())
        time_str = datetime.now().strftime("%I:%M %p")

        if path == "/api/login" or path == "/api/register":
            username = data.get("username", "").strip()
            password = data.get("password", "").strip()

            if not username or not password:
                self._set_headers(400)
                self.wfile.write(json.dumps({"success": False, "message": "Username and password required"}).encode("utf-8"))
                conn.close()
                return

            cursor.execute("SELECT password FROM users WHERE username = ?", (username,))
            user = cursor.fetchone()

            if user:
                if user[0] == password:
                    cursor.execute("UPDATE users SET last_seen = ? WHERE username = ?", (now_ts, username))
                    conn.commit()
                    self._set_headers(200)
                    self.wfile.write(json.dumps({"success": True, "message": "Login successful", "username": username}).encode("utf-8"))
                else:
                    self._set_headers(401)
                    self.wfile.write(json.dumps({"success": False, "message": "Incorrect password"}).encode("utf-8"))
            else:
                # Register new user automatically
                cursor.execute("INSERT INTO users (username, password, last_seen) VALUES (?, ?, ?)", (username, password, now_ts))
                conn.commit()
                self._set_headers(200)
                self.wfile.write(json.dumps({"success": True, "message": "Account created and logged in", "username": username}).encode("utf-8"))

        elif path == "/api/heartbeat":
            username = data.get("username", "").strip()
            if username:
                cursor.execute("UPDATE users SET last_seen = ? WHERE username = ?", (now_ts, username))
                conn.commit()
                self._set_headers(200)
                self.wfile.write(json.dumps({"success": True}).encode("utf-8"))
            else:
                self._set_headers(400)
                self.wfile.write(json.dumps({"success": False, "message": "Username required"}).encode("utf-8"))

        elif path == "/api/public-feed":
            sender = data.get("sender", "").strip()
            text = data.get("text", "").strip()

            if not sender or not text:
                self._set_headers(400)
                self.wfile.write(json.dumps({"success": False, "message": "Sender and text required"}).encode("utf-8"))
                conn.close()
                return

            cursor.execute("INSERT INTO public_messages (sender, text, timestamp) VALUES (?, ?, ?)", (sender, text, time_str))
            cursor.execute("UPDATE users SET last_seen = ? WHERE username = ?", (now_ts, sender))
            conn.commit()
            self._set_headers(200)
            self.wfile.write(json.dumps({"success": True, "message": "Message posted"}).encode("utf-8"))

        elif path == "/api/private-messages":
            sender = data.get("sender", "").strip()
            recipient = data.get("recipient", "").strip()
            text = data.get("text", "").strip()

            if not sender or not recipient or not text:
                self._set_headers(400)
                self.wfile.write(json.dumps({"success": False, "message": "Sender, recipient, and text required"}).encode("utf-8"))
                conn.close()
                return

            cursor.execute("INSERT INTO private_messages (sender, recipient, text, timestamp) VALUES (?, ?, ?, ?)", (sender, recipient, text, time_str))
            cursor.execute("UPDATE users SET last_seen = ? WHERE username = ?", (now_ts, sender))
            conn.commit()
            self._set_headers(200)
            self.wfile.write(json.dumps({"success": True, "message": "Private message sent"}).encode("utf-8"))

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

        if path == "/api/public-feed":
            cursor.execute("SELECT sender, text, timestamp FROM public_messages ORDER BY id ASC LIMIT 100")
            rows = cursor.fetchall()
            messages = [{"sender": r[0], "text": r[1], "time": r[2]} for r in rows]
            self._set_headers(200)
            self.wfile.write(json.dumps({"success": True, "messages": messages}).encode("utf-8"))

        elif path == "/api/online-users":
            current_user = query.get("user", [""])[0].strip()
            # Users active in the last 120 seconds are marked "Online", others "Offline"
            cursor.execute("SELECT username, last_seen FROM users ORDER BY last_seen DESC")
            rows = cursor.fetchall()
            
            users = []
            for r in rows:
                username = r[0]
                last_seen = r[1]
                if username == current_user:
                    continue  # Exclude self from messaging target list
                
                is_online = (now_ts - last_seen) <= 120
                status_str = "Online" if is_online else "Offline"
                users.append({"name": username, "status": status_str, "online": is_online})
            
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
    print(f"Chatify Backend Server running on http://0.0.0.0:{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nServer stopped.")
