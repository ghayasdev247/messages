"""
GitHub-Native Synchronization Bridge for Chatify Accessible Messenger
Syncs messages and online status between local storage and https://github.com/ghayasdev247/messages.git
"""

import os
import json
import time
import urllib.request
import urllib.parse
from datetime import datetime

REPO_OWNER = "ghayasdev247"
REPO_NAME = "messages"
BRANCH = "main"

DATA_DIR = "data"
PUBLIC_FEED_FILE = os.path.join(DATA_DIR, "public_feed.json")
ONLINE_USERS_FILE = os.path.join(DATA_DIR, "online_users.json")
CHATS_DIR = os.path.join(DATA_DIR, "chats")

def init_local_data():
    os.makedirs(DATA_DIR, exist_ok=True)
    os.makedirs(CHATS_DIR, exist_ok=True)

    if not os.path.exists(PUBLIC_FEED_FILE):
        with open(PUBLIC_FEED_FILE, "w") as f:
            json.dump([{"sender": "System", "text": "Welcome to Chatify!", "time": "System"}], f, indent=2)

    if not os.path.exists(ONLINE_USERS_FILE):
        with open(ONLINE_USERS_FILE, "w") as f:
            json.dump([{"name": "System", "last_seen": int(time.time()), "status": "Online"}], f, indent=2)

def fetch_raw_github_file(file_path):
    url = f"https://raw.githubusercontent.com/{REPO_OWNER}/{REPO_NAME}/{BRANCH}/{file_path}"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "ChatifyApp"})
        with urllib.request.urlopen(req) as res:
            if res.status == 200:
                return json.loads(res.read().decode("utf-8"))
    except Exception as e:
        print(f"Error reading raw GitHub file {file_path}: {e}")
    return None

if __name__ == "__main__":
    init_local_data()
    print(f"GitHub Sync Bridge initialized for https://github.com/{REPO_OWNER}/{REPO_NAME}")
    feed = fetch_raw_github_file("data/public_feed.json")
    if feed:
        print("Successfully read public feed from GitHub:", feed)
