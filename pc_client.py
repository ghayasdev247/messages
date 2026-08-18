"""
Accessible Messenger - PC Desktop Testing Client
Built with Python standard library (tkinter, urllib, json, base64, threading)
Zero external dependencies required.
Communicates directly with GitHub repository: ghayasdev247/messages (branch main)
"""

import os
import time
import json
import base64
import threading
import urllib.request
import urllib.parse
import tkinter as tk
from tkinter import ttk, messagebox, scrolledtext

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
# GITHUB API CLIENT & READ-MERGE-COMMIT PATTERN
# --------------------------------------------------------------------
def fetch_github_file(file_path):
    api_url = f"https://api.github.com/repos/{GITHUB_OWNER}/{GITHUB_REPO}/contents/{file_path}?ref={GITHUB_BRANCH}&t={int(time.time())}"
    headers = {
        "User-Agent": "ChatifyPCPopup",
        "Cache-Control": "no-cache, no-store, must-revalidate",
        "Accept": "application/vnd.github.v3+json"
    }
    if current_user["github_token"]:
        headers["Authorization"] = f"token {current_user['github_token']}"

    try:
        req = urllib.request.Request(api_url, headers=headers)
        with urllib.request.urlopen(req) as res:
            if res.status == 200:
                body = json.loads(res.read().decode("utf-8"))
                content_b64 = body.get("content", "").replace("\n", "").replace("\r", "")
                raw_json = base64.b64decode(content_b64).decode("utf-8")
                return True, json.loads(raw_json), body.get("sha")
    except Exception:
        pass

    # Fallback raw content URL
    raw_url = f"https://raw.githubusercontent.com/{GITHUB_OWNER}/{GITHUB_REPO}/{GITHUB_BRANCH}/{file_path}?t={int(time.time())}"
    try:
        req = urllib.request.Request(raw_url, headers={"User-Agent": "ChatifyPC"})
        with urllib.request.urlopen(req) as res:
            if res.status == 200:
                return True, json.loads(res.read().decode("utf-8")), None
    except Exception:
        pass

    return False, None, None

def read_merge_commit(file_path, new_message_obj, commit_msg, callback=None):
    def _task():
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
            with urllib.request.urlopen(req) as res:
                if callback:
                    callback(res.status in (200, 201), data_list)
                return
        except Exception as e:
            print("Commit error:", e)

        if callback:
            callback(False, data_list)

    threading.Thread(target=_task, daemon=True).start()

# --------------------------------------------------------------------
# PC DESKTOP GUI APPLICATION
# --------------------------------------------------------------------
class AccessibleMessengerPCApp(tk.Tk):

    def __init__(self):
        super().__init__()
        self.title("Accessible Messenger - PC Testing Client")
        self.geometry("480x640")
        self.configure(bg="#F4F6F9")

        self.main_container = tk.Frame(self, bg="#F4F6F9")
        self.main_container.pack(fill="both", expand=True)

        self.show_login_screen()

    def clear_container(self):
        for widget in self.main_container.winfo_children():
            widget.destroy()

    # ----------------------------------------------------------------
    # 1. LOGIN SCREEN
    # ----------------------------------------------------------------
    def show_login_screen(self):
        global active_screen, is_polling
        active_screen = "login"
        is_polling = False
        self.clear_container()

        title_label = tk.Label(self.main_container, text="Accessible Messenger", font=("Arial", 18, "bold"), bg="#F4F6F9", fg="#000000")
        title_label.pack(pady=(20, 5))

        subtitle = tk.Label(self.main_container, text="PC Desktop Testing Client (GitHub Serverless)", font=("Arial", 11), bg="#F4F6F9", fg="#555555")
        subtitle.pack(pady=(0, 20))

        # Username
        tk.Label(self.main_container, text="Step 1: Enter Username", font=("Arial", 11, "bold"), bg="#F4F6F9", anchor="w").pack(fill="x", padx=30, pady=(10, 2))
        self.ent_username = ttk.Entry(self.main_container, font=("Arial", 12))
        self.ent_username.pack(fill="x", padx=30, ipady=6)

        # Password
        tk.Label(self.main_container, text="Step 2: Enter Password", font=("Arial", 11, "bold"), bg="#F4F6F9", anchor="w").pack(fill="x", padx=30, pady=(10, 2))
        self.ent_password = ttk.Entry(self.main_container, font=("Arial", 12), show="*")
        self.ent_password.pack(fill="x", padx=30, ipady=6)

        # GitHub Token
        tk.Label(self.main_container, text="GitHub Token (Optional for write access)", font=("Arial", 10), bg="#F4F6F9", fg="#777777", anchor="w").pack(fill="x", padx=30, pady=(10, 2))
        self.ent_token = ttk.Entry(self.main_container, font=("Arial", 10))
        self.ent_token.pack(fill="x", padx=30, ipady=4)

        # Login Button
        btn_login = tk.Button(self.main_container, text="Connect via GitHub", font=("Arial", 12, "bold"), bg="#1565C0", fg="#FFFFFF", activebackground="#0D47A1", activeforeground="#FFFFFF", command=self.on_login_click)
        btn_login.pack(fill="x", padx=30, pady=25, ipady=8)

    def on_login_click(self):
        username = self.ent_username.get().strip()
        password = self.ent_password.get().strip()
        token = self.ent_token.get().strip()

        if not username or not password:
            messagebox.showerror("Error", "Please enter both a username and password.")
            return

        current_user["name"] = username
        current_user["github_token"] = token
        current_user["online"] = True

        self.show_dashboard_screen()
        self.start_polling_loop()

    # ----------------------------------------------------------------
    # 2. DASHBOARD SCREEN
    # ----------------------------------------------------------------
    def show_dashboard_screen(self):
        global active_screen
        active_screen = "dashboard"
        self.clear_container()

        title_label = tk.Label(self.main_container, text="Messenger Home", font=("Arial", 18, "bold"), bg="#FFFFFF", fg="#000000")
        title_label.pack(pady=(25, 5))

        user_status = tk.Label(self.main_container, text=f"Logged in as: {current_user['name']} (PC Client)", font=("Arial", 11, "bold"), bg="#FFFFFF", fg="#2E7D32")
        user_status.pack(pady=(0, 30))

        btn_public = tk.Button(self.main_container, text="🌐 Public Feed", font=("Arial", 13, "bold"), bg="#0288D1", fg="#FFFFFF", command=self.show_public_feed_screen)
        btn_public.pack(fill="x", padx=30, pady=10, ipady=12)

        btn_private = tk.Button(self.main_container, text="💬 Private Chats & Online Users", font=("Arial", 13, "bold"), bg="#2E7D32", fg="#FFFFFF", command=self.show_private_directory_screen)
        btn_private.pack(fill="x", padx=30, pady=10, ipady=12)

        btn_logout = tk.Button(self.main_container, text="Disconnect / Logout", font=("Arial", 11), bg="#D32F2F", fg="#FFFFFF", command=self.on_logout_click)
        btn_logout.pack(fill="x", padx=30, pady=(30, 0), ipady=8)

    def on_logout_click(self):
        current_user["name"] = ""
        current_user["online"] = False
        self.show_login_screen()

    # ----------------------------------------------------------------
    # 3. PUBLIC FEED SCREEN
    # ----------------------------------------------------------------
    def show_public_feed_screen(self):
        global active_screen
        active_screen = "public_feed"
        self.clear_container()

        # Header bar
        header_frame = tk.Frame(self.main_container, bg="#0288D1")
        header_frame.pack(fill="x")

        btn_back = tk.Button(header_frame, text="< Home", font=("Arial", 10, "bold"), bg="#0288D1", fg="#FFFFFF", bd=0, command=self.show_dashboard_screen)
        btn_back.pack(side="left", padx=10, pady=10)

        header_title = tk.Label(header_frame, text="Public Feed (GitHub)", font=("Arial", 14, "bold"), bg="#0288D1", fg="#FFFFFF")
        header_title.pack(side="left", padx=10, pady=10)

        # Messages View
        self.txt_public_messages = scrolledtext.ScrolledText(self.main_container, font=("Arial", 11), bg="#F0F4F8", wrap="word")
        self.txt_public_messages.pack(fill="both", expand=True, padx=10, pady=10)

        # Input Frame
        input_frame = tk.Frame(self.main_container, bg="#F0F4F8")
        input_frame.pack(fill="x", padx=10, pady=(0, 10))

        self.ent_public_input = ttk.Entry(input_frame, font=("Arial", 11))
        self.ent_public_input.pack(side="left", fill="x", expand=True, ipady=6, padx=(0, 5))

        btn_send = tk.Button(input_frame, text="Post", font=("Arial", 10, "bold"), bg="#0288D1", fg="#FFFFFF", command=self.on_send_public_click)
        btn_send.pack(side="right", ipady=4, ipadx=10)

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

        def on_complete(success, merged_list):
            if success:
                self.after(0, self.fetch_public_feed_async)

        read_merge_commit("data/public_feed.json", new_msg, f"Public message by {current_user['name']}", on_complete)

    def fetch_public_feed_async(self):
        def _task():
            success, data, _ = fetch_github_file("data/public_feed.json")
            if success and data and active_screen == "public_feed":
                self.after(0, lambda: self.update_public_feed_ui(data))
        threading.Thread(target=_task, daemon=True).start()

    def update_public_feed_ui(self, messages):
        if not hasattr(self, "txt_public_messages") or not self.txt_public_messages.winfo_exists():
            return

        self.txt_public_messages.config(state="normal")
        self.txt_public_messages.delete("1.0", tk.END)

        for m in messages:
            sender = m.get("sender", "Unknown")
            text = m.get("text", "")
            time_str = m.get("time", "")
            self.txt_public_messages.insert(tk.END, f"{sender} ({time_str}):\n{text}\n\n")

        self.txt_public_messages.config(state="disabled")
        self.txt_public_messages.yview(tk.END)

    # ----------------------------------------------------------------
    # 4. PRIVATE CHATS DIRECTORY SCREEN
    # ----------------------------------------------------------------
    def show_private_directory_screen(self):
        global active_screen
        active_screen = "private_directory"
        self.clear_container()

        header_frame = tk.Frame(self.main_container, bg="#FFFFFF")
        header_frame.pack(fill="x", padx=10, pady=10)

        btn_back = tk.Button(header_frame, text="< Home", font=("Arial", 10), command=self.show_dashboard_screen)
        btn_back.pack(side="left")

        title = tk.Label(header_frame, text="Private Conversations", font=("Arial", 13, "bold"), bg="#FFFFFF")
        title.pack(side="left", padx=10)

        btn_refresh = tk.Button(header_frame, text="Refresh", font=("Arial", 10), command=self.fetch_online_users_async)
        btn_refresh.pack(side="right")

        self.lst_online_users = tk.Listbox(self.main_container, font=("Arial", 12), selectmode="single")
        self.lst_online_users.pack(fill="both", expand=True, padx=10, pady=10)
        self.lst_online_users.bind("<Double-1>", self.on_user_select)

        self.fetch_online_users_async()

    def fetch_online_users_async(self):
        def _task():
            success, data, _ = fetch_github_file("data/online_users.json")
            if success and data and active_screen == "private_directory":
                filtered = []
                now_ts = int(time.time())
                for u in data:
                    name = u.get("name", "")
                    if name != current_user["name"]:
                        last_seen = u.get("last_seen", 0)
                        is_online = (now_ts - last_seen) <= 120
                        status_str = "Online" if is_online else "Offline"
                        filtered.append((name, status_str))
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
            self.show_private_chat_screen(target_user)

    # ----------------------------------------------------------------
    # 5. PRIVATE CHAT ROOM SCREEN (Deterministic Pathing)
    # ----------------------------------------------------------------
    def show_private_chat_screen(self, target_username):
        global active_screen, active_chat_target
        active_screen = "private_chat"
        active_chat_target = target_username
        self.clear_container()

        header_frame = tk.Frame(self.main_container, bg="#E0E0E0")
        header_frame.pack(fill="x")

        btn_back = tk.Button(header_frame, text="< Directory", font=("Arial", 10), command=self.show_private_directory_screen)
        btn_back.pack(side="left", padx=10, pady=8)

        title = tk.Label(header_frame, text=f"Private: {target_username}", font=("Arial", 12, "bold"), bg="#E0E0E0")
        title.pack(side="left", padx=10)

        self.txt_private_messages = scrolledtext.ScrolledText(self.main_container, font=("Arial", 11), bg="#F9F9F9", wrap="word")
        self.txt_private_messages.pack(fill="both", expand=True, padx=10, pady=10)

        input_frame = tk.Frame(self.main_container, bg="#F9F9F9")
        input_frame.pack(fill="x", padx=10, pady=(0, 10))

        self.ent_private_input = ttk.Entry(input_frame, font=("Arial", 11))
        self.ent_private_input.pack(side="left", fill="x", expand=True, ipady=6, padx=(0, 5))

        btn_send = tk.Button(input_frame, text="Send", font=("Arial", 10, "bold"), bg="#2E7D32", fg="#FFFFFF", command=self.on_send_private_click)
        btn_send.pack(side="right", ipady=4, ipadx=10)

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
        chat_path = get_chat_file_path(current_user["name"], active_chat_target)

        def on_complete(success, merged_list):
            if success:
                self.after(0, lambda: self.fetch_private_messages_async(active_chat_target))

        read_merge_commit(chat_path, new_msg, f"Private message to {active_chat_target}", on_complete)

    def fetch_private_messages_async(self, target_username):
        chat_path = get_chat_file_path(current_user["name"], target_username)

        def _task():
            success, data, _ = fetch_github_file(chat_path)
            if success and data and active_screen == "private_chat" and active_chat_target == target_username:
                self.after(0, lambda: self.update_private_chat_ui(data))

        threading.Thread(target=_task, daemon=True).start()

    def update_private_chat_ui(self, messages):
        if not hasattr(self, "txt_private_messages") or not self.txt_private_messages.winfo_exists():
            return

        self.txt_private_messages.config(state="normal")
        self.txt_private_messages.delete("1.0", tk.END)

        for m in messages:
            sender = "Me" if m.get("sender") == current_user["name"] else m.get("sender", "")
            text = m.get("text", "")
            time_str = m.get("time", "")
            self.txt_private_messages.insert(tk.END, f"{sender} ({time_str}):\n{text}\n\n")

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
            success, remote_users, sha = fetch_github_file("data/online_users.json")
            users = remote_users if (success and isinstance(remote_users, list)) else []

            found = False
            for u in users:
                if u.get("name") == current_user["name"]:
                    u["last_seen"] = now_ts
                    u["status"] = "Online"
                    found = True
                    break

            if not found:
                users.append({"name": current_user["name"], "last_seen": now_ts, "status": "Online"})

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
                with urllib.request.urlopen(req):
                    pass
            except Exception as e:
                print("Heartbeat update error:", e)

        threading.Thread(target=_task, daemon=True).start()

if __name__ == "__main__":
    app = AccessibleMessengerPCApp()
    app.mainloop()
