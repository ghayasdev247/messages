# Chatify Accessible Anonymous Messenger

An accessible anonymous messaging application built in AndroLua+ for Android with Jieshuo / Commentary Screen Reader optimizations, paired with a Python REST API backend with SQLite storage.

## Features

- **Screen Reader Optimized**: Complete accessibility labels (`ContentDescription`) and speech notifications (`announce()`) designed for Jieshuo / Commentary Screen Reader users.
- **Anonymous Login / Registration**: Easy alias sign-in connected to server backend.
- **Public Feed**: Global public broadcast channel with real-time auto-refresh polling.
- **Private Conversations**: Online user directory and private 1-on-1 messaging threads.
- **Python Backend**: Zero-dependency `http.server` & `sqlite3` REST API server.

---

## Server Setup & Execution

### Prerequisites
- Python 3.x installed on your host machine / server.

### Running the Backend Server
```bash
python server.py
```
The server will start listening on port `5000` (e.g. `http://0.0.0.0:5000`).

---

## AndroLua+ App Setup

1. Open `main.lua` in your AndroLua+ / AndroLua IDE environment.
2. Set the `BACKEND_URL` variable to point to your server IP:
   - For Android Emulator: `http://10.0.2.2:5000`
   - For Physical Device on local Wi-Fi: `http://<YOUR_COMPUTER_IP>:5000`
3. Package and run the `.apk` / `.xpk` application.

---

## API Documentation

- `POST /api/login`: Authenticates user or registers new handle.
- `POST /api/heartbeat`: Updates user online presence timestamp.
- `GET /api/public-feed`: Returns recent public chat messages.
- `POST /api/public-feed`: Posts a message to public feed.
- `GET /api/online-users`: Lists users active within the last 5 minutes.
- `GET /api/private-messages?user=...&target=...`: Retrieves 1-on-1 private message history.
- `POST /api/private-messages`: Sends a private 1-on-1 message.
