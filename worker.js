/**
 * Cloudflare Worker Backend for Accessible Messenger
 * Handles real-time messaging, online presence, group chats, and auto-updates.
 */

const FIREBASE_DB = "https://messages-server-f2a99-default-rtdb.asia-southeast1.firebasedatabase.app";
const GITHUB_RAW = "https://raw.githubusercontent.com/ghayasdev247/messages/main";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization",
  "Content-Type": "application/json; charset=utf-8"
};

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const path = url.pathname;
    const method = request.method.toUpperCase();

    // 1. Handle CORS preflight options
    if (method === "OPTIONS") {
      return new Response(null, { headers: CORS_HEADERS, status: 204 });
    }

    try {
      // 2. Health check / Root
      if (path === "/" || path === "/api/health") {
        return new Response(JSON.stringify({
          status: "online",
          service: "Accessible Messenger Cloudflare Serverless Backend",
          version: "3.1.0",
          timestamp: Date.now()
        }), { headers: CORS_HEADERS, status: 200 });
      }

      // 3. Version Check API
      if (path === "/api/version") {
        const fbRes = await fetch(`${FIREBASE_DB}/data/version.json`);
        let versionData = null;
        if (fbRes.ok) {
          versionData = await fbRes.json();
        }
        if (!versionData) {
          const ghRes = await fetch(`${GITHUB_RAW}/data/version.json`);
          if (ghRes.ok) versionData = await ghRes.json();
        }
        if (!versionData) {
          versionData = {
            version: "3.1.0",
            version_code: 44,
            download_url: "/api/download-lua",
            changelog: "Accessible Messenger Live Cloudflare Backend."
          };
        }
        return new Response(JSON.stringify(versionData), { headers: CORS_HEADERS, status: 200 });
      }

      // 4. Download Raw Lua Plugin
      if (path === "/api/download-lua" || path === "/main.lua") {
        const ghRes = await fetch(`${GITHUB_RAW}/main.lua?t=${Date.now()}`);
        if (ghRes.ok) {
          const code = await ghRes.text();
          return new Response(code, {
            headers: {
              "Content-Type": "text/plain; charset=utf-8",
              "Access-Control-Allow-Origin": "*",
              "Cache-Control": "no-cache"
            },
            status: 200
          });
        }
        return new Response("Error: main.lua not found.", { status: 404 });
      }

      // 5. Public Feed API
      if (path === "/api/public-feed") {
        if (method === "GET") {
          const fbRes = await fetch(`${FIREBASE_DB}/data/public_feed.json`);
          const data = fbRes.ok ? await fbRes.json() : null;
          let list = [];
          if (data && typeof data === "object") {
            list = Array.isArray(data) ? data : Object.values(data);
          }
          return new Response(JSON.stringify({ success: true, messages: list }), { headers: CORS_HEADERS, status: 200 });
        } else if (method === "POST") {
          const body = await request.json();
          const msgObj = {
            sender: body.sender || "Anonymous",
            text: body.text || "[Voice Message]",
            isVoice: Boolean(body.isVoice || body.audio),
            audio: body.audio || null,
            time: body.time || new Date().toLocaleTimeString(),
            timestamp: Math.floor(Date.now() / 1000)
          };
          const fbRes = await fetch(`${FIREBASE_DB}/data/public_feed.json`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(msgObj)
          });
          return new Response(JSON.stringify({ success: fbRes.ok, message: msgObj }), { headers: CORS_HEADERS, status: fbRes.ok ? 200 : 500 });
        }
      }

      // 6. Online Users & Heartbeat API
      if (path === "/api/online-users") {
        const fbRes = await fetch(`${FIREBASE_DB}/data/online_users.json`);
        const data = fbRes.ok ? await fbRes.json() : {};
        const nowSec = Math.floor(Date.now() / 1000);
        let onlineList = [];
        if (data && typeof data === "object") {
          for (const key in data) {
            const u = data[key];
            if (u && typeof u === "object") {
              const lastSeen = Number(u.last_seen || 0);
              if (nowSec - lastSeen <= 60) {
                onlineList.push({ name: u.name || key, status: "Online", last_seen: lastSeen });
              }
            }
          }
        }
        return new Response(JSON.stringify({ success: true, users: onlineList }), { headers: CORS_HEADERS, status: 200 });
      }

      if (path === "/api/all-users") {
        const fbRes = await fetch(`${FIREBASE_DB}/data/all_users.json`);
        const data = fbRes.ok ? await fbRes.json() : {};
        let allList = [];
        if (data && typeof data === "object") {
          allList = Array.isArray(data) ? data : Object.values(data);
        }
        return new Response(JSON.stringify({ success: true, users: allList }), { headers: CORS_HEADERS, status: 200 });
      }

      if (path === "/api/heartbeat" || path === "/api/login") {
        if (method === "POST") {
          const body = await request.json();
          const username = (body.username || body.name || "").trim();
          if (username) {
            const userKey = username.toLowerCase().replace(/[^a-z0-9]/g, "_");
            const nowTs = Math.floor(Date.now() / 1000);
            const userObj = {
              name: username,
              last_seen: nowTs,
              status: "Online"
            };
            const allUserObj = {
              name: username,
              registered_at: nowTs,
              last_seen: nowTs
            };
            await fetch(`${FIREBASE_DB}/data/online_users/${userKey}.json`, {
              method: "PUT",
              headers: { "Content-Type": "application/json" },
              body: JSON.stringify(userObj)
            });
            await fetch(`${FIREBASE_DB}/data/all_users/${userKey}.json`, {
              method: "PUT",
              headers: { "Content-Type": "application/json" },
              body: JSON.stringify(allUserObj)
            });
            return new Response(JSON.stringify({ success: true, user: userObj }), { headers: CORS_HEADERS, status: 200 });
          }
          return new Response(JSON.stringify({ success: false, error: "Username required" }), { headers: CORS_HEADERS, status: 400 });
        }
      }

      // 7. Private Messages API
      if (path === "/api/private-messages") {
        const u1 = (url.searchParams.get("user") || "").trim().toLowerCase();
        const u2 = (url.searchParams.get("target") || "").trim().toLowerCase();
        const chatKey = u1 < u2 ? `${u1}_${u2}` : `${u2}_${u1}`;

        if (method === "GET") {
          const fbRes = await fetch(`${FIREBASE_DB}/data/chats/${chatKey}.json`);
          const data = fbRes.ok ? await fbRes.json() : null;
          let list = [];
          if (data && typeof data === "object") {
            list = Array.isArray(data) ? data : Object.values(data);
          }
          return new Response(JSON.stringify({ success: true, messages: list }), { headers: CORS_HEADERS, status: 200 });
        } else if (method === "POST") {
          const body = await request.json();
          const sender = (body.sender || "").trim().toLowerCase();
          const recipient = (body.recipient || "").trim().toLowerCase();
          const postKey = sender < recipient ? `${sender}_${recipient}` : `${recipient}_${sender}`;
          
          const msgObj = {
            sender: body.sender,
            recipient: body.recipient,
            text: body.text || "[Voice Message]",
            isVoice: Boolean(body.isVoice || body.audio),
            audio: body.audio || null,
            time: body.time || new Date().toLocaleTimeString(),
            timestamp: Math.floor(Date.now() / 1000)
          };
          const fbRes = await fetch(`${FIREBASE_DB}/data/chats/${postKey}.json`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(msgObj)
          });
          return new Response(JSON.stringify({ success: fbRes.ok, message: msgObj }), { headers: CORS_HEADERS, status: fbRes.ok ? 200 : 500 });
        }
      }

      // 8. Groups API
      if (path === "/api/groups") {
        if (method === "GET") {
          const fbRes = await fetch(`${FIREBASE_DB}/data/groups.json`);
          const data = fbRes.ok ? await fbRes.json() : null;
          let list = [];
          if (data && typeof data === "object") {
            list = Array.isArray(data) ? data : Object.values(data);
          }
          return new Response(JSON.stringify({ success: true, groups: list }), { headers: CORS_HEADERS, status: 200 });
        } else if (method === "POST") {
          const body = await request.json();
          const groupId = body.id || `grp_${Date.now()}`;
          const groupObj = {
            id: groupId,
            name: body.name || "Untitled Group",
            desc: body.desc || "",
            admin: body.admin || "Admin",
            members: body.members || [body.admin || "Admin"],
            isPublic: body.isPublic !== false,
            requireApproval: Boolean(body.requireApproval),
            pendingRequests: body.pendingRequests || []
          };
          await fetch(`${FIREBASE_DB}/data/groups/${groupId}.json`, {
            method: "PUT",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(groupObj)
          });
          return new Response(JSON.stringify({ success: true, group: groupObj }), { headers: CORS_HEADERS, status: 200 });
        }
      }

      // 9. Group Chat Messages API
      if (path === "/api/group-messages") {
        const groupId = url.searchParams.get("group") || "general";
        if (method === "GET") {
          const fbRes = await fetch(`${FIREBASE_DB}/data/groups/${groupId}_messages.json`);
          const data = fbRes.ok ? await fbRes.json() : null;
          let list = [];
          if (data && typeof data === "object") {
            list = Array.isArray(data) ? data : Object.values(data);
          }
          return new Response(JSON.stringify({ success: true, messages: list }), { headers: CORS_HEADERS, status: 200 });
        } else if (method === "POST") {
          const body = await request.json();
          const targetGroup = body.groupId || groupId;
          const msgObj = {
            sender: body.sender,
            groupId: targetGroup,
            text: body.text || "[Voice Message]",
            isVoice: Boolean(body.isVoice || body.audio),
            audio: body.audio || null,
            time: body.time || new Date().toLocaleTimeString(),
            timestamp: Math.floor(Date.now() / 1000)
          };
          const fbRes = await fetch(`${FIREBASE_DB}/data/groups/${targetGroup}_messages.json`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(msgObj)
          });
          return new Response(JSON.stringify({ success: fbRes.ok, message: msgObj }), { headers: CORS_HEADERS, status: fbRes.ok ? 200 : 500 });
        }
      }

      return new Response(JSON.stringify({ error: "Endpoint not found" }), { headers: CORS_HEADERS, status: 404 });
    } catch (err) {
      return new Response(JSON.stringify({ error: err.message }), { headers: CORS_HEADERS, status: 500 });
    }
  }
};
