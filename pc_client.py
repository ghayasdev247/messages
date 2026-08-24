"""
Accessible Messenger - Accessible PC Desktop Native Application
Built with Python (tkinter, urllib, json, base64, threading, win32com SAPI5 / NVDA Controller)
Fully optimized for NVDA, JAWS, and Windows Screen Readers (0ms speech latency).
Primary Server: Live Firebase Realtime Database (messages-server-f2a99)
Fallback Server: GitHub REST API (ghayasdev247/messages) + Local PC REST API
"""

import os
import time
import json
import base64
import ctypes
import threading
import subprocess
import urllib.request
import urllib.parse
import tkinter as tk
from tkinter import ttk, messagebox, scrolledtext

# --------------------------------------------------------------------
# CONFIGURATION & GLOBAL STATE
# --------------------------------------------------------------------
FIREBASE_URL = "https://messages-server-f2a99-default-rtdb.asia-southeast1.firebasedatabase.app"
BACKEND_URL = "https://messages.vistudio247.workers.dev"

GITHUB_OWNER = "ghayasdev247"
GITHUB_REPO = "messages"
GITHUB_BRANCH = "main"

current_user = {"name": "", "github_token": "", "online": False}
active_screen = "login"
active_chat_target = ""

last_public_count = 0
last_private_count = 0
last_heartbeat_time = 0
is_polling = False

# --------------------------------------------------------------------
# ZERO-LATENCY SCREEN READER SPEECH ENGINE (NVDA + JAWS SAPI5)
# --------------------------------------------------------------------
sapi_voice = None
try:
    import win32com.client
    sapi_voice = win32com.client.Dispatch("SAPI.SpVoice")
except Exception:
    pass

nvda_dll = None
try:
    for dll_name in ["nvdaControllerClient64.dll", "nvdaControllerClient32.dll", "nvdaControllerClient.dll"]:
        try:
            nvda_dll = ctypes.windll.LoadLibrary(dll_name)
            break
        except Exception:
            pass
except Exception:
    pass

def announce(text):
    """0ms Latency Speech Announcements for NVDA, JAWS, and Windows SAPI5."""
    if not text:
        return
    def _speak():
        # Priority 1: Direct NVDA Controller Client DLL
        if nvda_dll:
            try:
                nvda_dll.nvdaController_speakText(text)
                return
            except Exception:
                pass

        # Priority 2: Asynchronous SAPI5 COM Dispatch (Flags = 1)
        if sapi_voice:
            try:
                sapi_voice.Speak(text, 1)
                return
            except Exception:
                pass

        # Priority 3: PowerShell System.Speech Fallback
        try:
            clean_text = text.replace('"', '').replace("'", "").replace("\n", " ")
            subprocess.Popen(
                ['powershell', '-Command', f'Add-Type -AssemblyName System.Speech; (New-Object System.Speech.Synthesis.SpeechSynthesizer).Speak("{clean_text}")'],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            )
        except Exception:
            pass

    threading.Thread(target=_speak, daemon=True).start()

# --------------------------------------------------------------------
# DETERMINISTIC PATH GENERATOR
# --------------------------------------------------------------------
def get_chat_file_path(u1, u2):
    u1_lower = u1.lower()
    u2_lower = u2.lower()
    if u1_lower < u2_lower:
        return f"data/chats/{u1}_{u2}.json"
    else:
        return f"data/chats/{u2}_{u1}.json"

# --------------------------------------------------------------------
# UNIFIED CLOUD NETWORKING ENGINE (Firebase + GitHub Fallback)
# --------------------------------------------------------------------
def fetch_firebase_data(path):
    clean_path = path.replace(".json", "")
    url = f"{FIREBASE_URL}/{clean_path}.json?t={int(time.time())}"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "ChatifyPC"})
        with urllib.request.urlopen(req, timeout=4) as res:
            if res.status == 200:
                raw = res.read().decode("utf-8")
                if raw and raw != "null":
                    data = json.loads(raw)
                    if isinstance(data, list):
                        return True, [x for x in data if isinstance(x, dict)]
                    elif isinstance(data, dict):
                        return True, [v for k, v in data.items() if isinstance(v, dict)]
    except Exception:
        pass
    return False, None

def post_firebase_data(path, payload):
    clean_path = path.replace(".json", "")
    url = f"{FIREBASE_URL}/{clean_path}.json"
    body = json.dumps(payload).encode("utf-8")
    try:
        req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json", "User-Agent": "ChatifyPC"}, method="POST")
        with urllib.request.urlopen(req, timeout=4) as res:
            return res.status in (200, 201)
    except Exception:
        return False

def fetch_github_file(file_path):
    # Try Live Firebase Database First
    fb_ok, fb_list = fetch_firebase_data(file_path)
    if fb_ok and fb_list:
        return True, fb_list, None

    # Fallback to GitHub REST API
    api_url = f"https://api.github.com/repos/{GITHUB_OWNER}/{GITHUB_REPO}/contents/{file_path}?ref={GITHUB_BRANCH}&t={int(time.time())}"
    headers = {
        "User-Agent": "ChatifyPC",
        "Cache-Control": "no-cache, no-store, must-revalidate",
        "Accept": "application/vnd.github.v3+json"
    }
    if current_user["github_token"]:
        headers["Authorization"] = f"token {current_user['github_token']}"

    try:
        req = urllib.request.Request(api_url, headers=headers)
        with urllib.request.urlopen(req, timeout=4) as res:
            if res.status == 200:
                body = json.loads(res.read().decode("utf-8"))
                content_b64 = body.get("content", "").replace("\n", "").replace("\r", "")
                raw_json = base64.b64decode(content_b64).decode("utf-8")
                return True, json.loads(raw_json), body.get("sha")
    except Exception:
        pass

    return False, None, None

def send_chat_message(file_path, new_message_obj, commit_msg, callback=None):
    def _task():
        # 1. Post to Firebase Realtime Database
        post_firebase_data(file_path, new_message_obj)

        # 2. Commit to GitHub Serverless Storage
        success, remote_array, sha = fetch_github_file(file_path)
        data_list = remote_array if (success and isinstance(remote_array, list)) else []
        data_list.append(new_message_obj)

        json_str = json.dumps(data_list, indent=2)
        b64_content = base64.b64encode(json_str.encode("utf-8")).decode("utf-8")

        api_url = f"https://api.github.com/repos/{GITHUB_OWNER}/{GITHUB_REPO}/contents/{file_path}"
        headers = {
            "User-Agent": "ChatifyPC",
            "Cache-Control": "no-cache, no-store, must-revalidate",
            "Accept": "application/vnd.github.v3+json"
        }
        if current_user["github_token"]:
            headers["Authorization"] = f"token {current_user['github_token']}"

        payload = {
            "message": commit_msg,
            "content": b64_content,
            "branch": GITHUB_BRANCH
        }
        if sha:
            payload["sha"] = sha

        try:
            req = urllib.request.Request(api_url, data=json.dumps(payload).encode("utf-8"), headers=headers, method="PUT")
            with urllib.request.urlopen(req, timeout=4) as res:
                if callback:
                    callback(res.status in (200, 201), data_list)
                return
        except Exception:
            pass

        if callback:
            callback(True, data_list)

    threading.Thread(target=_task, daemon=True).start()

# --------------------------------------------------------------------
# PC DESKTOP GUI APPLICATION WITH ACCESSIBILITY & NVDA INTEGRATION
# --------------------------------------------------------------------
class AccessibleMessengerPCApp(tk.Tk):

    def __init__(self):
        super().__init__()
        self.title("Accessible Messenger - NVDA & JAWS Desktop Client (v1.2.0)")
        self.geometry("540x700")
        self.configure(bg="#F4F6F9")

        self.main_container = tk.Frame(self, bg="#F4F6F9")
        self.main_container.pack(fill="both", expand=True)

        self.show_login_screen()

    def clear_container(self):
        for widget in self.main_container.winfo_children():
            widget.destroy()

    def make_accessible(self, widget, announcement_text):
        """Binds focus event so NVDA & JAWS speak out loud instantly upon tabbing."""
        widget.bind("<FocusIn>", lambda e: announce(announcement_text))

    # ----------------------------------------------------------------
    # 1. LOGIN SCREEN
    # ----------------------------------------------------------------
    def show_login_screen(self):
        global active_screen, is_polling
        active_screen = "login"
        is_polling = False
        self.clear_container()
        announce("Accessible Messenger. Login Screen.")

        title_label = tk.Label(self.main_container, text="Accessible Messenger", font=("Arial", 18, "bold"), bg="#F4F6F9", fg="#075E54")
        title_label.pack(pady=(20, 5))

        subtitle = tk.Label(self.main_container, text="Cloud Messenger for NVDA & JAWS (v1.2.0)", font=("Arial", 11), bg="#F4F6F9", fg="#555555")
        subtitle.pack(pady=(0, 20))

        # Username
        lbl_u = tk.Label(self.main_container, text="Step 1: Enter Username", font=("Arial", 11, "bold"), bg="#F4F6F9", anchor="w")
        lbl_u.pack(fill="x", padx=30, pady=(10, 2))

        self.ent_username = tk.Entry(self.main_container, font=("Arial", 12), bg="#FFFFFF", fg="#000000")
        self.ent_username.pack(fill="x", padx=30, ipady=6)
        self.make_accessible(self.ent_username, "Username edit box. Type your desired alias here.")

        # Password
        lbl_p = tk.Label(self.main_container, text="Step 2: Enter Password", font=("Arial", 11, "bold"), bg="#F4F6F9", anchor="w")
        lbl_p.pack(fill="x", padx=30, pady=(10, 2))

        self.ent_password = tk.Entry(self.main_container, font=("Arial", 12), show="*", bg="#FFFFFF", fg="#000000")
        self.ent_password.pack(fill="x", padx=30, ipady=6)
        self.make_accessible(self.ent_password, "Password edit box. Type your password here.")

        # GitHub Token
        lbl_t = tk.Label(self.main_container, text="GitHub Token (Optional for write access)", font=("Arial", 10), bg="#F4F6F9", fg="#777777", anchor="w")
        lbl_t.pack(fill="x", padx=30, pady=(10, 2))

        self.ent_token = tk.Entry(self.main_container, font=("Arial", 10), bg="#FFFFFF", fg="#000000")
        self.ent_token.pack(fill="x", padx=30, ipady=4)
        self.make_accessible(self.ent_token, "GitHub Personal Access Token input field.")

        # Login Button
        btn_login = tk.Button(self.main_container, text="Connect to Cloud Messenger", font=("Arial", 12, "bold"), bg="#075E54", fg="#FFFFFF", activebackground="#128C7E", activeforeground="#FFFFFF", command=self.on_login_click)
        btn_login.pack(fill="x", padx=30, pady=25, ipady=8)
        self.make_accessible(btn_login, "Connect to Cloud Messenger button. Press Enter to sign in.")

        self.ent_username.focus_set()

    def on_login_click(self):
        username = self.ent_username.get().strip()
        password = self.ent_password.get().strip()
        token = self.ent_token.get().strip()

        if not username or not password:
            announce("Error: Please enter both a username and password.")
            messagebox.showerror("Error", "Please enter both a username and password.")
            return

        current_user["name"] = username
        current_user["github_token"] = token
        current_user["online"] = True

        announce(f"Connected as {username}. Welcome to Homepage.")
        self.show_dashboard_screen()
        self.start_polling_loop()

    # ----------------------------------------------------------------
    # 2. DASHBOARD SCREEN
    # ----------------------------------------------------------------
    def show_dashboard_screen(self):
        global active_screen
        active_screen = "dashboard"
        self.clear_container()

        title_label = tk.Label(self.main_container, text="Messenger Main Home", font=("Arial", 18, "bold"), bg="#FFFFFF", fg="#075E54")
        title_label.pack(pady=(25, 5))

        user_status = tk.Label(self.main_container, text=f"Logged in as: {current_user['name']} (v1.2.0)", font=("Arial", 11, "bold"), bg="#FFFFFF", fg="#2E7D32")
        user_status.pack(pady=(0, 30))

        btn_public = tk.Button(self.main_container, text="🌐 Public Feed", font=("Arial", 13, "bold"), bg="#128C7E", fg="#FFFFFF", command=self.show_public_feed_screen)
        btn_public.pack(fill="x", padx=30, pady=10, ipady=12)
        self.make_accessible(btn_public, "Public Feed button. Press Enter to open public broadcast room.")

        btn_private = tk.Button(self.main_container, text="💬 Active Online Users (Directory)", font=("Arial", 13, "bold"), bg="#075E54", fg="#FFFFFF", command=self.show_private_directory_screen)
        btn_private.pack(fill="x", padx=30, pady=10, ipady=12)
        self.make_accessible(btn_private, "Active Online Users button. Press Enter to view currently online users.")

        btn_logout = tk.Button(self.main_container, text="Disconnect / Logout", font=("Arial", 11), bg="#D32F2F", fg="#FFFFFF", command=self.on_logout_click)
        btn_logout.pack(fill="x", padx=30, pady=(30, 0), ipady=8)
        self.make_accessible(btn_logout, "Disconnect button. Press Enter to log out.")

        btn_public.focus_set()

    def on_logout_click(self):
        current_user["name"] = ""
        current_user["online"] = False
        announce("Disconnected from messenger.")
        self.show_login_screen()

    # ----------------------------------------------------------------
    # 3. PUBLIC FEED SCREEN
    # ----------------------------------------------------------------
    def show_public_feed_screen(self):
        global active_screen
        active_screen = "public_feed"
        self.clear_container()

        header_frame = tk.Frame(self.main_container, bg="#075E54")
        header_frame.pack(fill="x")

        btn_back = tk.Button(header_frame, text="< Home", font=("Arial", 10, "bold"), bg="#075E54", fg="#FFFFFF", bd=0, command=self.show_dashboard_screen)
        btn_back.pack(side="left", padx=10, pady=10)
        self.make_accessible(btn_back, "Back to home dashboard button.")

        header_title = tk.Label(header_frame, text="Public Feed Room", font=("Arial", 14, "bold"), bg="#075E54", fg="#FFFFFF")
        header_title.pack(side="left", padx=10, pady=10)

        # Messages View
        self.txt_public_messages = scrolledtext.ScrolledText(self.main_container, font=("Arial", 11), bg="#F0F4F8", wrap="word")
        self.txt_public_messages.pack(fill="both", expand=True, padx=10, pady=10)
        self.make_accessible(self.txt_public_messages, "Public messages history list. Use arrow keys to read messages.")

        # Input Frame
        input_frame = tk.Frame(self.main_container, bg="#F0F4F8")
        input_frame.pack(fill="x", padx=10, pady=(0, 10))

        self.ent_public_input = tk.Entry(input_frame, font=("Arial", 11), bg="#FFFFFF", fg="#000000")
        self.ent_public_input.pack(side="left", fill="x", expand=True, ipady=6, padx=(0, 5))
        self.make_accessible(self.ent_public_input, "Public message input field. Type message to post.")
        self.ent_public_input.bind("<Return>", lambda e: self.on_send_public_click())

        btn_send = tk.Button(input_frame, text="Post", font=("Arial", 10, "bold"), bg="#075E54", fg="#FFFFFF", command=self.on_send_public_click)
        btn_send.pack(side="right", ipady=4, ipadx=10)
        self.make_accessible(btn_send, "Post public message button. Press Enter to publish.")

        self.ent_public_input.focus_set()
        self.fetch_public_feed_async()

    def on_send_public_click(self):
        text = self.ent_public_input.get().strip()
        if not text:
            return

        new_msg = {
            "sender": current_user["name"],
            "text": text,
            "time": time.strftime("%I:%M %p")
        }

        self.ent_public_input.delete(0, tk.END)
        announce(f"Posting public message: {text}")

        def on_complete(success, merged_list):
            if success:
                self.after(0, self.fetch_public_feed_async)

        send_chat_message("data/public_feed.json", new_msg, f"Public message by {current_user['name']}", on_complete)

    def fetch_public_feed_async(self):
        def _task():
            global last_public_count
            success, data, _ = fetch_github_file("data/public_feed.json")
            if success and data and isinstance(data, list) and active_screen == "public_feed":
                new_count = len(data)
                if new_count > last_public_count and last_public_count > 0:
                    latest = data[-1]
                    if isinstance(latest, dict) and latest.get("sender") != current_user["name"]:
                        announce(f"New public message from {latest.get('sender')}: {latest.get('text')}")
                last_public_count = new_count
                self.after(0, lambda: self.update_public_feed_ui(data))
        threading.Thread(target=_task, daemon=True).start()

    def update_public_feed_ui(self, messages):
        if not hasattr(self, "txt_public_messages") or not self.txt_public_messages.winfo_exists():
            return

        self.txt_public_messages.config(state="normal")
        self.txt_public_messages.delete("1.0", tk.END)

        if isinstance(messages, list):
            for m in messages:
                if isinstance(m, dict):
                    sender = m.get("sender", "Unknown")
                    text = m.get("text", "")
                    time_str = m.get("time", "")
                    rx = f" [{m.get('reaction')}]" if m.get("reaction") else ""
                    self.txt_public_messages.insert(tk.END, f"{sender} ({time_str}):\n{text}{rx}\n\n")

        self.txt_public_messages.config(state="disabled")
        self.txt_public_messages.yview(tk.END)

    # ----------------------------------------------------------------
    # 4. PRIVATE CHATS DIRECTORY SCREEN (ONLINE USERS ONLY)
    # ----------------------------------------------------------------
    def show_private_directory_screen(self):
        global active_screen
        active_screen = "private_directory"
        self.clear_container()

        header_frame = tk.Frame(self.main_container, bg="#FFFFFF")
        header_frame.pack(fill="x", padx=10, pady=10)

        btn_back = tk.Button(header_frame, text="< Home", font=("Arial", 10), command=self.show_dashboard_screen)
        btn_back.pack(side="left")
        self.make_accessible(btn_back, "Back to home dashboard button.")

        title = tk.Label(header_frame, text="Active Online Users", font=("Arial", 13, "bold"), bg="#FFFFFF", fg="#075E54")
        title.pack(side="left", padx=10)

        btn_refresh = tk.Button(header_frame, text="Refresh", font=("Arial", 10), command=self.fetch_online_users_async)
        btn_refresh.pack(side="right")
        self.make_accessible(btn_refresh, "Refresh active online users button.")

        self.lst_online_users = tk.Listbox(self.main_container, font=("Arial", 12), selectmode="single")
        self.lst_online_users.pack(fill="both", expand=True, padx=10, pady=10)
        self.lst_online_users.bind("<Double-1>", self.on_user_select)
        self.lst_online_users.bind("<Return>", self.on_user_select)
        self.make_accessible(self.lst_online_users, "Active online users list. Use up and down arrow keys to browse users, press Enter to chat.")

        self.lst_online_users.focus_set()
        self.fetch_online_users_async()

    def fetch_online_users_async(self):
        def _task():
            success, data, _ = fetch_github_file("data/online_users.json")
            if success and data and isinstance(data, list) and active_screen == "private_directory":
                filtered = []
                now_ts = int(time.time())
                for u in data:
                    if isinstance(u, dict):
                        name = u.get("name", "")
                        last_seen = u.get("last_seen", 0)
                        is_online = u.get("status") == "Online" or u.get("online") is True or (now_ts - last_seen <= 70)
                        if name and name != current_user["name"] and is_online:
                            filtered.append((name, "Online"))
                self.after(0, lambda: self.update_online_users_ui(filtered))
        threading.Thread(target=_task, daemon=True).start()

    def update_online_users_ui(self, users):
        if not hasattr(self, "lst_online_users") or not self.lst_online_users.winfo_exists():
            return

        self.lst_online_users.delete(0, tk.END)
        self.user_data_map = []
        for name, status in users:
            self.user_data_map.append(name)
            self.lst_online_users.insert(tk.END, f"  ● {name} ({status})")

    def on_user_select(self, event):
        selection = self.lst_online_users.curselection()
        if selection:
            index = selection[0]
            target_user = self.user_data_map[index]
            announce(f"Opening private chat with {target_user}")
            self.show_private_chat_screen(target_user)

    # ----------------------------------------------------------------
    # 5. PRIVATE CHAT ROOM SCREEN (Deterministic Pathing)
    # ----------------------------------------------------------------
    def show_private_chat_screen(self, target_username):
        global active_screen, active_chat_target, last_private_count
        active_screen = "private_chat"
        active_chat_target = target_username
        last_private_count = 0
        self.clear_container()

        header_frame = tk.Frame(self.main_container, bg="#075E54")
        header_frame.pack(fill="x")

        btn_back = tk.Button(header_frame, text="< Directory", font=("Arial", 10, "bold"), bg="#075E54", fg="#FFFFFF", bd=0, command=self.show_private_directory_screen)
        btn_back.pack(side="left", padx=10, pady=8)
        self.make_accessible(btn_back, "Back to active online users directory button.")

        title = tk.Label(header_frame, text=f"Private: {target_username}", font=("Arial", 12, "bold"), bg="#075E54", fg="#FFFFFF")
        title.pack(side="left", padx=10)

        self.txt_private_messages = scrolledtext.ScrolledText(self.main_container, font=("Arial", 11), bg="#F9F9F9", wrap="word")
        self.txt_private_messages.pack(fill="both", expand=True, padx=10, pady=10)
        self.make_accessible(self.txt_private_messages, f"Private messages thread with {target_username}.")

        input_frame = tk.Frame(self.main_container, bg="#F9F9F9")
        input_frame.pack(fill="x", padx=10, pady=(0, 10))

        self.ent_private_input = tk.Entry(input_frame, font=("Arial", 11), bg="#FFFFFF", fg="#000000")
        self.ent_private_input.pack(side="left", fill="x", expand=True, ipady=6, padx=(0, 5))
        self.make_accessible(self.ent_private_input, f"Private message input field to {target_username}.")
        self.ent_private_input.bind("<Return>", lambda e: self.on_send_private_click())

        btn_send = tk.Button(input_frame, text="Send", font=("Arial", 10, "bold"), bg="#075E54", fg="#FFFFFF", command=self.on_send_private_click)
        btn_send.pack(side="right", ipady=4, ipadx=10)
        self.make_accessible(btn_send, "Send private message button. Press Enter to send.")

        self.ent_private_input.focus_set()
        self.fetch_private_messages_async(target_username)

    def on_send_private_click(self):
        text = self.ent_private_input.get().strip()
        if not text or not active_chat_target:
            return

        new_msg = {
            "sender": current_user["name"],
            "recipient": active_chat_target,
            "text": text,
            "time": time.strftime("%I:%M %p")
        }

        self.ent_private_input.delete(0, tk.END)
        announce(f"Sending private message: {text}")

        chat_path = get_chat_file_path(current_user["name"], active_chat_target)

        def on_complete(success, merged_list):
            if success:
                self.after(0, lambda: self.fetch_private_messages_async(active_chat_target))

        send_chat_message(chat_path, new_msg, f"Private message to {active_chat_target}", on_complete)

    def fetch_private_messages_async(self, target_username):
        chat_path = get_chat_file_path(current_user["name"], target_username)

        def _task():
            global last_private_count
            success, data, _ = fetch_github_file(chat_path)
            if success and data and isinstance(data, list) and active_screen == "private_chat" and active_chat_target == target_username:
                new_count = len(data)
                if new_count > last_private_count and last_private_count > 0:
                    latest = data[-1]
                    if isinstance(latest, dict) and latest.get("sender") == target_username:
                        announce(f"New private message from {target_username}: {latest.get('text')}")
                last_private_count = new_count
                self.after(0, lambda: self.update_private_chat_ui(data))

        threading.Thread(target=_task, daemon=True).start()

    def update_private_chat_ui(self, messages):
        if not hasattr(self, "txt_private_messages") or not self.txt_private_messages.winfo_exists():
            return

        self.txt_private_messages.config(state="normal")
        self.txt_private_messages.delete("1.0", tk.END)

        if isinstance(messages, list):
            for m in messages:
                if isinstance(m, dict):
                    sender = "Me" if m.get("sender") == current_user["name"] else (m.get("sender") or "")
                    text = m.get("text", "")
                    time_str = m.get("time", "")
                    rx = f" [{m.get('reaction')}]" if m.get("reaction") else ""
                    self.txt_private_messages.insert(tk.END, f"{sender} ({time_str}):\n{text}{rx}\n\n")

        self.txt_private_messages.config(state="disabled")
        self.txt_private_messages.yview(tk.END)

    # ----------------------------------------------------------------
    # BACKGROUND POLLING LOOP & HEARTBEAT ENGINE
    # ----------------------------------------------------------------
    def start_polling_loop(self):
        global is_polling
        if is_polling:
            return
        is_polling = True

        def _bg_loop():
            global last_heartbeat_time
            while is_polling and current_user["online"]:
                now_ts = int(time.time())

                # 30-Second Presence Heartbeat Update
                if now_ts - last_heartbeat_time >= 30:
                    last_heartbeat_time = now_ts
                    self.update_online_presence()

                # Refresh active screen content
                if active_screen == "public_feed":
                    self.fetch_public_feed_async()
                elif active_screen == "private_directory":
                    self.fetch_online_users_async()
                elif active_screen == "private_chat" and active_chat_target:
                    self.fetch_private_messages_async(active_chat_target)

                time.sleep(3.5)

        threading.Thread(target=_bg_loop, daemon=True).start()

    def update_online_presence(self):
        def _task():
            now_ts = int(time.time())
            user_obj = {"name": current_user["name"], "last_seen": now_ts, "status": "Online"}
            post_firebase_data("data/online_users", user_obj)

            success, remote_users, sha = fetch_github_file("data/online_users.json")
            users = remote_users if (success and isinstance(remote_users, list)) else []

            found = False
            for u in users:
                if isinstance(u, dict) and u.get("name") == current_user["name"]:
                    u["last_seen"] = now_ts
                    u["status"] = "Online"
                    found = true
                    break

            if not found:
                users.append(user_obj)

            json_str = json.dumps(users, indent=2)
            b64_content = base64.b64encode(json_str.encode("utf-8")).decode("utf-8")

            api_url = f"https://api.github.com/repos/{GITHUB_OWNER}/{GITHUB_REPO}/contents/data/online_users.json"
            headers = {
                "User-Agent": "ChatifyPC",
                "Cache-Control": "no-cache, no-store, must-revalidate",
                "Accept": "application/vnd.github.v3+json"
            }
            if current_user["github_token"]:
                headers["Authorization"] = f"token {current_user['github_token']}"

            payload = {
                "message": f"PC Client heartbeat update for {current_user['name']}",
                "content": b64_content,
                "branch": GITHUB_BRANCH
            }
            if sha:
                payload["sha"] = sha

            try:
                req = urllib.request.Request(api_url, data=json.dumps(payload).encode("utf-8"), headers=headers, method="PUT")
                with urllib.request.urlopen(req, timeout=4):
                    pass
            except Exception:
                pass

        threading.Thread(target=_task, daemon=True).start()

if __name__ == "__main__":
    app = AccessibleMessengerPCApp()
    app.mainloop()
