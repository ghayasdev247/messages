/**
 * Cloudflare Worker Backend for Accessible Messenger
 * Handles real-time messaging, online presence, group chats, auto-updates,
 * user feedback, server diagnostics, Ghost Admin Controls, and Live Voice Calls.
 */

const FIREBASE_DB = "https://messages-server-f2a99-default-rtdb.asia-southeast1.firebasedatabase.app";
const GITHUB_RAW = "https://raw.githubusercontent.com/ghayasdev247/messages/main";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Requested-With",
  "Content-Type": "application/json; charset=utf-8"
};

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const path = url.pathname;
    const method = request.method.toUpperCase();

    // 1. Handle CORS preflight
    if (method === "OPTIONS") {
      return new Response(null, { headers: CORS_HEADERS, status: 204 });
    }

    // 2. Extract Client IP
    const clientIP = request.headers.get("CF-Connecting-IP") || 
                     request.headers.get("x-real-ip") || 
                     request.headers.get("x-forwarded-for") || 
                     "127.0.0.1";
    const ipKey = clientIP.replace(/[^a-zA-Z0-9]/g, "_");

    try {
      // 3. Check if IP is Blocked (except for root, version, ping)
      if (path !== "/" && path !== "/api/health" && path !== "/api/ping" && path !== "/api/version" && !path.startsWith("/api/admin")) {
        const ipCheckRes = await fetch(`${FIREBASE_DB}/data/blocked_ips/${ipKey}.json`);
        if (ipCheckRes.ok) {
          const ipData = await ipCheckRes.json();
          if (ipData && ipData.blocked) {
            return new Response(JSON.stringify({
              error: "ACCESS_DENIED_IP_BLOCKED",
              message: "Your IP address has been suspended by the administrator.",
              ip: clientIP,
              reason: ipData.reason || "Violation of network guidelines"
            }), { headers: CORS_HEADERS, status: 403 });
          }
        }
      }

      // 4. Client IP & Latency Ping endpoint
      if (path === "/api/my-ip") {
        return new Response(JSON.stringify({ ip: clientIP }), { headers: CORS_HEADERS, status: 200 });
      }

      if (path === "/api/ping" || path === "/api/server-status") {
        const maintRes = await fetch(`${FIREBASE_DB}/data/maintenance.json`);
        const maintData = maintRes.ok ? await maintRes.json() : null;
        return new Response(JSON.stringify({
          status: (maintData && maintData.active) ? "maintenance" : "online",
          server_name: "Accessible Messenger Real-Time Cloud Engine",
          version: "3.6.0",
          maintenance: Boolean(maintData && maintData.active),
          maintenance_message: (maintData && maintData.message) || "Server is temporarily under scheduled maintenance.",
          client_ip: clientIP,
          server_time: Date.now()
        }), { headers: CORS_HEADERS, status: 200 });
      }

      // 5. Health check / Root
      if (path === "/" || path === "/api/health") {
        return new Response(JSON.stringify({
          status: "online",
          service: "Accessible Messenger Real-Time Cloud Engine",
          version: "3.6.0",
          client_ip: clientIP,
          timestamp: Date.now()
        }), { headers: CORS_HEADERS, status: 200 });
      }

      // 6. Version Check API
      if (path === "/api/version") {
        const fbRes = await fetch(`${FIREBASE_DB}/data/version.json`);
        let versionData = null;
        if (fbRes.ok) versionData = await fbRes.json();
        if (!versionData) {
          const ghRes = await fetch(`${GITHUB_RAW}/data/version.json`);
          if (ghRes.ok) versionData = await ghRes.json();
        }
        if (!versionData) {
          versionData = {
            version: "3.6.0",
            version_code: 54,
            download_url: "/api/download-lua",
            changelog: "Version 3.6.0: Live Voice Calling (Public Stage, Lounge Group Calls, 1-on-1 Private Calls) with Adaptive Audio Quality Engine."
          };
        }
        return new Response(JSON.stringify(versionData), { headers: CORS_HEADERS, status: 200 });
      }

      // 7. Download Raw Lua Plugin
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

      // ====================================================================
      // 8. LIVE VOICE CALL & GROUP AUDIO STAGE ENGINE
      // ====================================================================
      
      // Join Live Voice Call / Audio Room
      if (path === "/api/call/join" && method === "POST") {
        const body = await request.json();
        const roomId = (body.roomId || "public_stage").replace(/[^a-zA-Z0-9_-]/g, "_");
        const username = (body.username || "User").trim();
        const userKey = username.toLowerCase().replace(/[^a-z0-9]/g, "_");
        const nowTs = Math.floor(Date.now() / 1000);

        const participantObj = {
          name: username,
          isMuted: Boolean(body.isMuted),
          quality: body.quality || "HD",
          joined_at: nowTs,
          last_ping: nowTs,
          ip: clientIP
        };

        await fetch(`${FIREBASE_DB}/data/active_calls/${roomId}/participants/${userKey}.json`, {
          method: "PUT",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(participantObj)
        });

        return new Response(JSON.stringify({ success: true, roomId: roomId, participant: participantObj }), { headers: CORS_HEADERS, status: 200 });
      }

      // Leave Live Voice Call Room
      if (path === "/api/call/leave" && method === "POST") {
        const body = await request.json();
        const roomId = (body.roomId || "public_stage").replace(/[^a-zA-Z0-9_-]/g, "_");
        const username = (body.username || "").trim();
        const userKey = username.toLowerCase().replace(/[^a-z0-9]/g, "_");

        if (userKey) {
          await fetch(`${FIREBASE_DB}/data/active_calls/${roomId}/participants/${userKey}.json`, { method: "DELETE" });
        }

        return new Response(JSON.stringify({ success: true, message: "Left voice call room." }), { headers: CORS_HEADERS, status: 200 });
      }

      // Transmit Audio Packet Stream in Room
      if (path === "/api/call/audio" && method === "POST") {
        const body = await request.json();
        const roomId = (body.roomId || "public_stage").replace(/[^a-zA-Z0-9_-]/g, "_");
        const sender = (body.sender || "User").trim();
        const userKey = sender.toLowerCase().replace(/[^a-z0-9]/g, "_");
        const nowTs = Math.floor(Date.now() / 1000);

        const audioPacket = {
          sender: sender,
          audio: body.audio || "",
          quality: body.quality || "HD",
          timestamp: nowTs,
          seq: Date.now()
        };

        // Broadcast active audio chunk
        await fetch(`${FIREBASE_DB}/data/active_calls/${roomId}/audio_stream.json`, {
          method: "PUT",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(audioPacket)
        });

        // Update speaker heartbeat
        await fetch(`${FIREBASE_DB}/data/active_calls/${roomId}/participants/${userKey}/last_ping.json`, {
          method: "PUT",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(nowTs)
        });

        return new Response(JSON.stringify({ success: true }), { headers: CORS_HEADERS, status: 200 });
      }

      // Get Live Call Room Status & Participants
      if (path === "/api/call/status" && method === "GET") {
        const roomId = (url.searchParams.get("room") || "public_stage").replace(/[^a-zA-Z0-9_-]/g, "_");
        const res = await fetch(`${FIREBASE_DB}/data/active_calls/${roomId}.json`);
        const data = res.ok ? await res.json() : null;
        
        let participantsList = [];
        let latestAudio = null;
        const nowSec = Math.floor(Date.now() / 1000);

        if (data && typeof data === "object") {
          latestAudio = data.audio_stream || null;
          if (data.participants && typeof data.participants === "object") {
            for (const key in data.participants) {
              const p = data.participants[key];
              if (p && typeof p === "object") {
                const pingTime = Number(p.last_ping || 0);
                if (nowSec - pingTime <= 30) {
                  participantsList.push(p);
                }
              }
            }
          }
        }

        return new Response(JSON.stringify({
          success: true,
          roomId: roomId,
          participants: participantsList,
          latest_audio: latestAudio
        }), { headers: CORS_HEADERS, status: 200 });
      }

      // 1-on-1 Call Signaling (Ringing / Accept / Decline / End)
      if (path === "/api/call/signal" && method === "POST") {
        const body = await request.json();
        const action = body.action || "call"; // call, accept, decline, end
        const fromUser = (body.from || "").trim();
        const toUser = (body.to || "").trim();
        const targetKey = toUser.toLowerCase().replace(/[^a-z0-9]/g, "_");
        const fromKey = fromUser.toLowerCase().replace(/[^a-z0-9]/g, "_");

        const signalObj = {
          action: action,
          from: fromUser,
          to: toUser,
          roomId: body.roomId || `private_call_${fromKey < targetKey ? fromKey + "_" + targetKey : targetKey + "_" + fromKey}`,
          timestamp: Math.floor(Date.now() / 1000)
        };

        if (action === "end" || action === "decline") {
          await fetch(`${FIREBASE_DB}/data/call_signals/${targetKey}.json`, { method: "DELETE" });
          await fetch(`${FIREBASE_DB}/data/call_signals/${fromKey}.json`, { method: "DELETE" });
        } else {
          await fetch(`${FIREBASE_DB}/data/call_signals/${targetKey}.json`, {
            method: "PUT",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(signalObj)
          });
        }

        return new Response(JSON.stringify({ success: true, signal: signalObj }), { headers: CORS_HEADERS, status: 200 });
      }

      // Poll Call Signals (For Incoming Call Notifications)
      if (path === "/api/call/signal" && method === "GET") {
        const user = (url.searchParams.get("user") || "").trim().toLowerCase().replace(/[^a-z0-9]/g, "_");
        if (user) {
          const res = await fetch(`${FIREBASE_DB}/data/call_signals/${user}.json`);
          const data = res.ok ? await res.json() : null;
          return new Response(JSON.stringify({ success: true, signal: data }), { headers: CORS_HEADERS, status: 200 });
        }
        return new Response(JSON.stringify({ success: false }), { headers: CORS_HEADERS, status: 400 });
      }

      // ====================================================================
      // 8B. WEBRTC REAL-TIME SIGNALING & PEER MESH ENGINE
      // ====================================================================
      
      // WebRTC Signal Dispatcher (Offer, Answer, ICE Candidate)
      if (path === "/api/webrtc/signal" && method === "POST") {
        const body = await request.json();
        const roomId = (body.roomId || "default_room").replace(/[^a-zA-Z0-9_-]/g, "_");
        const sender = (body.sender || "").trim();
        const target = (body.target || "").trim();
        const signalType = body.type; // "offer", "answer", "candidate", "bye"
        const signalData = body.data || {};
        
        if (!sender || !target || !signalType) {
          return new Response(JSON.stringify({ success: false, error: "Missing required signal parameters" }), { headers: CORS_HEADERS, status: 400 });
        }

        const targetKey = target.toLowerCase().replace(/[^a-z0-9]/g, "_");
        const senderKey = sender.toLowerCase().replace(/[^a-z0-9]/g, "_");
        const signalId = `sig_${Date.now()}_${Math.floor(Math.random() * 10000)}`;

        const signalPayload = {
          id: signalId,
          roomId: roomId,
          sender: sender,
          target: target,
          type: signalType,
          data: signalData,
          timestamp: Math.floor(Date.now() / 1000)
        };

        await fetch(`${FIREBASE_DB}/data/webrtc_signals/${roomId}/${targetKey}/${signalId}.json`, {
          method: "PUT",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(signalPayload)
        });

        return new Response(JSON.stringify({ success: true, signalId: signalId }), { headers: CORS_HEADERS, status: 200 });
      }

      // WebRTC Signals Poller (Fetch & Clean Pending Signals for User + Room Peer Sync)
      if (path === "/api/webrtc/signals" && method === "GET") {
        const roomId = (url.searchParams.get("room") || "").replace(/[^a-zA-Z0-9_-]/g, "_");
        const user = (url.searchParams.get("user") || "").trim().toLowerCase().replace(/[^a-z0-9]/g, "_");
        const nowSec = Math.floor(Date.now() / 1000);

        if (!roomId || !user) {
          return new Response(JSON.stringify({ success: false, error: "Missing room or user parameter" }), { headers: CORS_HEADERS, status: 400 });
        }

        // 1. Update heartbeat
        await fetch(`${FIREBASE_DB}/data/webrtc_rooms/${roomId}/peers/${user}/last_ping.json`, {
          method: "PUT",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(nowSec)
        });

        // 2. Fetch pending signals
        const res = await fetch(`${FIREBASE_DB}/data/webrtc_signals/${roomId}/${user}.json`);
        const rawSignals = res.ok ? await res.json() : null;
        let signalList = [];

        if (rawSignals && typeof rawSignals === "object") {
          signalList = Object.values(rawSignals);
          // Clean consumed signals to prevent double-processing
          await fetch(`${FIREBASE_DB}/data/webrtc_signals/${roomId}/${user}.json`, { method: "DELETE" });
        }

        // 3. Fetch active peers in room
        const peersRes = await fetch(`${FIREBASE_DB}/data/webrtc_rooms/${roomId}/peers.json`);
        const rawPeers = peersRes.ok ? await peersRes.json() : {};
        let activePeersList = [];

        if (rawPeers && typeof rawPeers === "object") {
          for (const key in rawPeers) {
            const peer = rawPeers[key];
            if (peer && typeof peer === "object" && peer.name) {
              if (nowSec - Number(peer.last_ping || 0) <= 30) {
                activePeersList.push({ name: peer.name, isOnline: true });
              }
            }
          }
        }

        return new Response(JSON.stringify({
          success: true,
          roomId: roomId,
          signals: signalList,
          participants: activePeersList,
          iceServers: [
            { urls: "stun:stun.l.google.com:19302" },
            { urls: "stun:stun1.l.google.com:19302" },
            { urls: "stun:stun2.l.google.com:19302" },
            { urls: "stun:stun.cloudflare.com:3478" }
          ]
        }), { headers: CORS_HEADERS, status: 200 });
      }

      // WebRTC Room Join & Peer Discovery
      if (path === "/api/webrtc/room/join" && method === "POST") {
        const body = await request.json();
        const roomId = (body.roomId || "default_room").replace(/[^a-zA-Z0-9_-]/g, "_");
        const username = (body.username || "").trim();
        const userKey = username.toLowerCase().replace(/[^a-z0-9]/g, "_");
        const nowSec = Math.floor(Date.now() / 1000);

        if (!username) {
          return new Response(JSON.stringify({ success: false, error: "Missing username" }), { headers: CORS_HEADERS, status: 400 });
        }

        // Register peer in room
        await fetch(`${FIREBASE_DB}/data/webrtc_rooms/${roomId}/peers/${userKey}.json`, {
          method: "PUT",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            name: username,
            joined_at: nowSec,
            last_ping: nowSec
          })
        });

        // Get list of existing peers in room
        const peersRes = await fetch(`${FIREBASE_DB}/data/webrtc_rooms/${roomId}/peers.json`);
        const rawPeers = peersRes.ok ? await peersRes.json() : {};
        let activePeers = [];

        if (rawPeers && typeof rawPeers === "object") {
          for (const key in rawPeers) {
            const peer = rawPeers[key];
            if (peer && typeof peer === "object" && peer.name) {
              if (nowSec - Number(peer.last_ping || 0) <= 45 && peer.name !== username) {
                activePeers.push(peer.name);
              }
            }
          }
        }

        return new Response(JSON.stringify({
          success: true,
          roomId: roomId,
          peers: activePeers,
          iceServers: [
            { urls: "stun:stun.l.google.com:19302" },
            { urls: "stun:stun1.l.google.com:19302" },
            { urls: "stun:stun2.l.google.com:19302" }
          ]
        }), { headers: CORS_HEADERS, status: 200 });
      }

      // WebRTC Room Leave
      if (path === "/api/webrtc/room/leave" && method === "POST") {
        const body = await request.json();
        const roomId = (body.roomId || "").replace(/[^a-zA-Z0-9_-]/g, "_");
        const username = (body.username || "").trim();
        const userKey = username.toLowerCase().replace(/[^a-z0-9]/g, "_");

        if (roomId && userKey) {
          await fetch(`${FIREBASE_DB}/data/webrtc_rooms/${roomId}/peers/${userKey}.json`, { method: "DELETE" });
          await fetch(`${FIREBASE_DB}/data/webrtc_signals/${roomId}/${userKey}.json`, { method: "DELETE" });
        }

        return new Response(JSON.stringify({ success: true }), { headers: CORS_HEADERS, status: 200 });
      }

      // ====================================================================
      // 9. FEEDBACK & MESSAGING PIPELINE
      // ====================================================================

      // User Feedback & Feature Request API
      if (path === "/api/feedback") {
        if (method === "GET") {
          const fbRes = await fetch(`${FIREBASE_DB}/data/feedbacks.json`);
          const data = fbRes.ok ? await fbRes.json() : {};
          let list = [];
          if (data && typeof data === "object") {
            list = Array.isArray(data) ? data : Object.values(data);
          }
          return new Response(JSON.stringify({ success: true, feedbacks: list }), { headers: CORS_HEADERS, status: 200 });
        } else if (method === "POST") {
          const body = await request.json();
          const fbId = `fb_${Date.now()}_${Math.floor(Math.random() * 1000)}`;
          const fbObj = {
            id: fbId,
            sender: body.sender || "Anonymous",
            type: body.type || "Feature Request",
            text: body.text || "",
            time: body.time || new Date().toLocaleTimeString(),
            timestamp: Math.floor(Date.now() / 1000),
            ip: clientIP,
            status: "New"
          };
          const fbRes = await fetch(`${FIREBASE_DB}/data/feedbacks/${fbId}.json`, {
            method: "PUT",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(fbObj)
          });
          return new Response(JSON.stringify({ success: fbRes.ok, feedback: fbObj }), { headers: CORS_HEADERS, status: fbRes.ok ? 200 : 500 });
        }
      }

      // ====================================================================
      // 9. ON-DEMAND AUDIO VAULT & STREAMING
      // ====================================================================

      // Upload Audio to Vault
      if (path === "/api/audio/upload" && method === "POST") {
        const body = await request.json();
        const rawAudio = body.audio || "";
        const duration = Number(body.duration || 0);
        const sizeKb = Number(body.size_kb || Math.round(rawAudio.length * 0.75 / 1024));
        const audioId = body.audio_id || `aud_${Date.now()}_${Math.floor(Math.random() * 10000)}`;

        if (!rawAudio) {
          return new Response(JSON.stringify({ success: false, error: "Audio data required" }), { headers: CORS_HEADERS, status: 400 });
        }

        const audioVaultObj = {
          audio_id: audioId,
          audio: rawAudio,
          duration: duration,
          size_kb: sizeKb,
          uploaded_at: Math.floor(Date.now() / 1000),
          ip: clientIP
        };

        await fetch(`${FIREBASE_DB}/data/audio_vault/${audioId}.json`, {
          method: "PUT",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(audioVaultObj)
        });

        return new Response(JSON.stringify({
          success: true,
          audio_id: audioId,
          duration: duration,
          size_kb: sizeKb
        }), { headers: CORS_HEADERS, status: 200 });
      }

      // Fetch Audio from Vault (On-Demand with Immutable Cache)
      if ((path === "/api/audio" || path.startsWith("/api/audio/")) && method === "GET") {
        let audioId = url.searchParams.get("id") || path.replace("/api/audio/", "");
        audioId = audioId.replace(/[^a-zA-Z0-9_-]/g, "");

        if (!audioId) {
          return new Response(JSON.stringify({ success: false, error: "Missing audio ID" }), { headers: CORS_HEADERS, status: 400 });
        }

        const clientEtag = request.headers.get("if-none-match");
        if (clientEtag && clientEtag === `"${audioId}"`) {
          return new Response(null, {
            status: 304,
            headers: {
              ...CORS_HEADERS,
              "ETag": `"${audioId}"`,
              "Cache-Control": "public, max-age=31536000, immutable"
            }
          });
        }

        const res = await fetch(`${FIREBASE_DB}/data/audio_vault/${audioId}.json`);
        if (res.ok) {
          const data = await res.json();
          if (data && data.audio) {
            return new Response(JSON.stringify({
              success: true,
              audio_id: audioId,
              audio: data.audio,
              duration: data.duration || 0,
              size_kb: data.size_kb || 0
            }), {
              headers: {
                ...CORS_HEADERS,
                "ETag": `"${audioId}"`,
                "Cache-Control": "public, max-age=31536000, immutable"
              },
              status: 200
            });
          }
        }
        return new Response(JSON.stringify({ success: false, error: "Audio note not found" }), { headers: CORS_HEADERS, status: 404 });
      }

      // Helper function for processing delta messages & windowing
      async function handleMessageFeedResponse(rawFeed, req) {
        const reqUrl = new URL(req.url);
        const sinceTs = Number(reqUrl.searchParams.get("since_ts") || 0);
        const limit = Math.min(Math.max(Number(reqUrl.searchParams.get("limit") || 30), 1), 100);

        let list = [];
        if (rawFeed && typeof rawFeed === "object") {
          list = Array.isArray(rawFeed) ? rawFeed : Object.values(rawFeed);
        }

        // Sort ascending by timestamp
        list.sort((a, b) => Number(a.timestamp || 0) - Number(b.timestamp || 0));

        // Strip heavy inline base64 audio to minimize bandwidth (transmits audio_id instead)
        const lightList = list.map(m => {
          if (!m || typeof m !== "object") return m;
          const copy = { ...m };
          if (copy.audio && copy.audio.length > 500) {
            if (!copy.audio_id) copy.audio_id = `aud_legacy_${copy.timestamp || Date.now()}`;
            delete copy.audio; // strip large base64 from feed
          }
          return copy;
        });

        let resultList = lightList;
        if (sinceTs > 0) {
          resultList = lightList.filter(m => Number(m.timestamp || 0) > sinceTs);
        } else {
          resultList = lightList.slice(-limit);
        }

        const latestTs = resultList.length > 0 ? Number(resultList[resultList.length - 1].timestamp || 0) : 0;
        const etag = `W/"${resultList.length}-${latestTs}"`;

        const clientEtag = req.headers.get("if-none-match");
        if (clientEtag && clientEtag === etag && resultList.length === 0) {
          return new Response(null, {
            status: 304,
            headers: {
              ...CORS_HEADERS,
              "ETag": etag,
              "Cache-Control": "public, max-age=1"
            }
          });
        }

        return new Response(JSON.stringify({
          success: true,
          delta: Boolean(sinceTs > 0),
          count: resultList.length,
          latest_timestamp: latestTs,
          messages: resultList
        }), {
          headers: {
            ...CORS_HEADERS,
            "ETag": etag,
            "Cache-Control": "public, max-age=1"
          },
          status: 200
        });
      }

      // Public Feed API (Delta & On-Demand Voice Support)
      if (path === "/api/public-feed") {
        if (method === "GET") {
          const fbRes = await fetch(`${FIREBASE_DB}/data/public_feed.json`);
          const data = fbRes.ok ? await fbRes.json() : null;
          return await handleMessageFeedResponse(data, request);
        } else if (method === "POST") {
          const body = await request.json();
          const sender = body.sender || "Anonymous";
          const senderKey = sender.toLowerCase().replace(/[^a-z0-9]/g, "_");

          // Check if sender is banned
          const userCheck = await fetch(`${FIREBASE_DB}/data/all_users/${senderKey}.json`);
          if (userCheck.ok) {
            const uData = await userCheck.json();
            const nowTs = Math.floor(Date.now() / 1000);
            if (uData && uData.ban_until && uData.ban_until > nowTs) {
              const remainingMin = Math.ceil((uData.ban_until - nowTs) / 60);
              return new Response(JSON.stringify({
                error: "USER_SUSPENDED",
                message: `Account is temporarily suspended for another ${remainingMin} minutes.`,
                ban_until: uData.ban_until,
                reason: uData.ban_reason || "Violation of rules"
              }), { headers: CORS_HEADERS, status: 403 });
            }
          }

          let audioId = body.audio_id || null;
          if (body.audio && !audioId) {
            audioId = `aud_${Date.now()}_${Math.floor(Math.random() * 10000)}`;
            await fetch(`${FIREBASE_DB}/data/audio_vault/${audioId}.json`, {
              method: "PUT",
              headers: { "Content-Type": "application/json" },
              body: JSON.stringify({ audio_id: audioId, audio: body.audio, uploaded_at: Math.floor(Date.now() / 1000) })
            });
          }

          const msgObj = {
            id: `msg_${Date.now()}_${Math.floor(Math.random() * 1000)}`,
            sender: sender,
            text: body.text || "[Voice Message]",
            isVoice: Boolean(body.isVoice || audioId || body.audio),
            audio_id: audioId,
            duration: Number(body.duration || 0),
            size_kb: Number(body.size_kb || 0),
            time: body.time || new Date().toLocaleTimeString(),
            timestamp: Math.floor(Date.now() / 1000),
            ip: clientIP
          };
          const fbRes = await fetch(`${FIREBASE_DB}/data/public_feed.json`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(msgObj)
          });
          return new Response(JSON.stringify({ success: fbRes.ok, message: msgObj }), { headers: CORS_HEADERS, status: fbRes.ok ? 200 : 500 });
        }
      }

      // Online Users & All Users Directory
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
                onlineList.push({
                  name: u.name || key,
                  status: "Online",
                  last_seen: lastSeen,
                  ip: u.ip || clientIP
                });
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

      // Login & Heartbeat (Tracks IP, Password, and verifies Ban)
      if (path === "/api/heartbeat" || path === "/api/login") {
        if (method === "POST") {
          const body = await request.json();
          const username = (body.username || body.name || "").trim();
          if (username) {
            const userKey = username.toLowerCase().replace(/[^a-z0-9]/g, "_");
            const nowTs = Math.floor(Date.now() / 1000);

            // Fetch existing account record if available
            let existing = {};
            const exRes = await fetch(`${FIREBASE_DB}/data/all_users/${userKey}.json`);
            if (exRes.ok) {
              const exData = await exRes.json();
              if (exData && typeof exData === "object") existing = exData;
            }

            // Check if user is currently banned
            if (existing.ban_until && existing.ban_until > nowTs) {
              const remainingMin = Math.ceil((existing.ban_until - nowTs) / 60);
              return new Response(JSON.stringify({
                error: "USER_SUSPENDED",
                message: `Account is suspended for another ${remainingMin} minutes.`,
                ban_until: existing.ban_until,
                reason: existing.ban_reason || "Violation of guidelines"
              }), { headers: CORS_HEADERS, status: 403 });
            }

            const userObj = {
              name: username,
              last_seen: nowTs,
              status: "Online",
              ip: clientIP
            };

            const allUserObj = {
              name: username,
              password: body.password || existing.password || "",
              registered_at: existing.registered_at || nowTs,
              last_seen: nowTs,
              ip: clientIP,
              ban_until: existing.ban_until || 0,
              ban_reason: existing.ban_reason || ""
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

            return new Response(JSON.stringify({ success: true, user: allUserObj }), { headers: CORS_HEADERS, status: 200 });
          }
          return new Response(JSON.stringify({ success: false, error: "Username required" }), { headers: CORS_HEADERS, status: 400 });
        }
      }

      // Private Messages API (Delta & On-Demand Voice Support)
      if (path === "/api/private-messages") {
        const u1 = (url.searchParams.get("user") || "").trim().toLowerCase();
        const u2 = (url.searchParams.get("target") || "").trim().toLowerCase();
        const chatKey = u1 < u2 ? `${u1}_${u2}` : `${u2}_${u1}`;

        if (method === "GET") {
          const fbRes = await fetch(`${FIREBASE_DB}/data/chats/${chatKey}.json`);
          const data = fbRes.ok ? await fbRes.json() : null;
          return await handleMessageFeedResponse(data, request);
        } else if (method === "POST") {
          const body = await request.json();
          const sender = (body.sender || "").trim();
          const recipient = (body.recipient || "").trim();
          const postKey = sender.toLowerCase() < recipient.toLowerCase() ? `${sender.toLowerCase()}_${recipient.toLowerCase()}` : `${recipient.toLowerCase()}_${sender.toLowerCase()}`;
          
          let audioId = body.audio_id || null;
          if (body.audio && !audioId) {
            audioId = `aud_${Date.now()}_${Math.floor(Math.random() * 10000)}`;
            await fetch(`${FIREBASE_DB}/data/audio_vault/${audioId}.json`, {
              method: "PUT",
              headers: { "Content-Type": "application/json" },
              body: JSON.stringify({ audio_id: audioId, audio: body.audio, uploaded_at: Math.floor(Date.now() / 1000) })
            });
          }

          const msgObj = {
            id: `msg_${Date.now()}_${Math.floor(Math.random() * 1000)}`,
            sender: sender,
            recipient: recipient,
            text: body.text || "[Voice Message]",
            isVoice: Boolean(body.isVoice || audioId || body.audio),
            audio_id: audioId,
            duration: Number(body.duration || 0),
            size_kb: Number(body.size_kb || 0),
            time: body.time || new Date().toLocaleTimeString(),
            timestamp: Math.floor(Date.now() / 1000),
            ip: clientIP
          };
          const fbRes = await fetch(`${FIREBASE_DB}/data/chats/${postKey}.json`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(msgObj)
          });
          return new Response(JSON.stringify({ success: fbRes.ok, message: msgObj }), { headers: CORS_HEADERS, status: fbRes.ok ? 200 : 500 });
        }
      }

      // Groups API
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

      // Group Chat Messages API (Delta & On-Demand Voice Support)
      if (path === "/api/group-messages") {
        const groupId = url.searchParams.get("group") || "general";
        if (method === "GET") {
          const fbRes = await fetch(`${FIREBASE_DB}/data/groups/${groupId}_messages.json`);
          const data = fbRes.ok ? await fbRes.json() : null;
          return await handleMessageFeedResponse(data, request);
        } else if (method === "POST") {
          const body = await request.json();
          const targetGroup = body.groupId || groupId;
          
          let audioId = body.audio_id || null;
          if (body.audio && !audioId) {
            audioId = `aud_${Date.now()}_${Math.floor(Math.random() * 10000)}`;
            await fetch(`${FIREBASE_DB}/data/audio_vault/${audioId}.json`, {
              method: "PUT",
              headers: { "Content-Type": "application/json" },
              body: JSON.stringify({ audio_id: audioId, audio: body.audio, uploaded_at: Math.floor(Date.now() / 1000) })
            });
          }

          const msgObj = {
            id: `msg_${Date.now()}_${Math.floor(Math.random() * 1000)}`,
            sender: body.sender,
            groupId: targetGroup,
            text: body.text || "[Voice Message]",
            isVoice: Boolean(body.isVoice || audioId || body.audio),
            audio_id: audioId,
            duration: Number(body.duration || 0),
            size_kb: Number(body.size_kb || 0),
            time: body.time || new Date().toLocaleTimeString(),
            timestamp: Math.floor(Date.now() / 1000),
            ip: clientIP
          };
          const fbRes = await fetch(`${FIREBASE_DB}/data/groups/${targetGroup}_messages.json`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(msgObj)
          });
          return new Response(JSON.stringify({ success: fbRes.ok, message: msgObj }), { headers: CORS_HEADERS, status: fbRes.ok ? 200 : 500 });
        }
      }

      // ====================================================================
      // 10. GHOST ADMIN CONTROL ENDPOINTS
      // ====================================================================

      // Ban / Unban User (10m, 30m, 1h, 24h, Permanent)
      if (path === "/api/admin/ban-user" && method === "POST") {
        const body = await request.json();
        const username = (body.username || "").trim();
        const durationMinutes = Number(body.durationMinutes || 0);
        const reason = body.reason || "Rule violation";
        const userKey = username.toLowerCase().replace(/[^a-z0-9]/g, "_");
        const nowTs = Math.floor(Date.now() / 1000);

        let banUntil = 0;
        if (durationMinutes > 0) {
          banUntil = now_ts = (durationMinutes * 60) + nowTs;
        } else if (durationMinutes === -1) {
          banUntil = 2147483647; // Permanent
        }

        // Update in all_users
        const uRes = await fetch(`${FIREBASE_DB}/data/all_users/${userKey}.json`);
        let uData = uRes.ok ? (await uRes.json() || {}) : {};
        uData.ban_until = banUntil;
        uData.ban_reason = reason;

        await fetch(`${FIREBASE_DB}/data/all_users/${userKey}.json`, {
          method: "PUT",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(uData)
        });

        // Kick from online presence if banned
        if (banUntil > nowTs) {
          await fetch(`${FIREBASE_DB}/data/online_users/${userKey}.json`, { method: "DELETE" });
        }

        return new Response(JSON.stringify({
          success: true,
          message: banUntil > nowTs ? `User ${username} banned successfully.` : `User ${username} unbanned.`,
          ban_until: banUntil
        }), { headers: CORS_HEADERS, status: 200 });
      }

      // Block / Ban IP Address
      if (path === "/api/admin/block-ip" && method === "POST") {
        const body = await request.json();
        const targetIP = (body.ip || "").trim();
        const reason = body.reason || "Suspicious network behavior";
        if (targetIP) {
          const targetKey = targetIP.replace(/[^a-zA-Z0-9]/g, "_");
          const blockObj = {
            ip: targetIP,
            blocked: true,
            blocked_at: Math.floor(Date.now() / 1000),
            reason: reason
          };
          await fetch(`${FIREBASE_DB}/data/blocked_ips/${targetKey}.json`, {
            method: "PUT",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(blockObj)
          });
          return new Response(JSON.stringify({ success: true, message: `IP ${targetIP} blocked successfully.` }), { headers: CORS_HEADERS, status: 200 });
        }
        return new Response(JSON.stringify({ success: false, error: "IP required" }), { headers: CORS_HEADERS, status: 400 });
      }

      // Unblock IP Address
      if (path === "/api/admin/unblock-ip" && method === "POST") {
        const body = await request.json();
        const targetIP = (body.ip || "").trim();
        if (targetIP) {
          const targetKey = targetIP.replace(/[^a-zA-Z0-9]/g, "_");
          await fetch(`${FIREBASE_DB}/data/blocked_ips/${targetKey}.json`, { method: "DELETE" });
          return new Response(JSON.stringify({ success: true, message: `IP ${targetIP} unblocked.` }), { headers: CORS_HEADERS, status: 200 });
        }
        return new Response(JSON.stringify({ success: false, error: "IP required" }), { headers: CORS_HEADERS, status: 400 });
      }

      // Get all Blocked IPs
      if (path === "/api/admin/blocked-ips" && method === "GET") {
        const res = await fetch(`${FIREBASE_DB}/data/blocked_ips.json`);
        const data = res.ok ? await res.json() : {};
        let list = [];
        if (data && typeof data === "object") {
          list = Array.isArray(data) ? data : Object.values(data);
        }
        return new Response(JSON.stringify({ success: true, blocked_ips: list }), { headers: CORS_HEADERS, status: 200 });
      }

      // Get all User Feedbacks (Admin Inbox)
      if (path === "/api/admin/feedbacks" && method === "GET") {
        const res = await fetch(`${FIREBASE_DB}/data/feedbacks.json`);
        const data = res.ok ? await res.json() : {};
        let list = [];
        if (data && typeof data === "object") {
          list = Array.isArray(data) ? data : Object.values(data);
        }
        return new Response(JSON.stringify({ success: true, feedbacks: list }), { headers: CORS_HEADERS, status: 200 });
      }

      // Delete / Resolve User Feedback
      if (path === "/api/admin/delete-feedback" && method === "POST") {
        const body = await request.json();
        const fbId = body.id || "";
        if (fbId) {
          await fetch(`${FIREBASE_DB}/data/feedbacks/${fbId}.json`, { method: "DELETE" });
          return new Response(JSON.stringify({ success: true, message: "Feedback resolved." }), { headers: CORS_HEADERS, status: 200 });
        }
        return new Response(JSON.stringify({ success: false, error: "Feedback ID required" }), { headers: CORS_HEADERS, status: 400 });
      }

      // Maintenance Mode Toggle
      if (path === "/api/admin/maintenance" && method === "POST") {
        const body = await request.json();
        const active = Boolean(body.active);
        const msg = body.message || "Server is temporarily under maintenance.";
        const maintObj = { active: active, message: msg, updated_at: Math.floor(Date.now() / 1000) };
        await fetch(`${FIREBASE_DB}/data/maintenance.json`, {
          method: "PUT",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(maintObj)
        });
        return new Response(JSON.stringify({ success: true, maintenance: maintObj }), { headers: CORS_HEADERS, status: 200 });
      }

      // Reset User Password (Admin Password Recovery)
      if (path === "/api/admin/reset-password" && method === "POST") {
        const body = await request.json();
        const username = (body.username || "").trim();
        const newPassword = body.newPassword || "123456";
        if (username) {
          const userKey = username.toLowerCase().replace(/[^a-z0-9]/g, "_");
          const uRes = await fetch(`${FIREBASE_DB}/data/all_users/${userKey}.json`);
          let uData = uRes.ok ? (await uRes.json() || {}) : {};
          uData.password = newPassword;
          await fetch(`${FIREBASE_DB}/data/all_users/${userKey}.json`, {
            method: "PUT",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(uData)
          });
          return new Response(JSON.stringify({ success: true, message: `Password for ${username} reset successfully to: ${newPassword}` }), { headers: CORS_HEADERS, status: 200 });
        }
        return new Response(JSON.stringify({ success: false, error: "Username required" }), { headers: CORS_HEADERS, status: 400 });
      }

      // Purge Public Lobby
      if (path === "/api/admin/purge-public" && method === "POST") {
        await fetch(`${FIREBASE_DB}/data/public_feed.json`, {
          method: "PUT",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({})
        });
        return new Response(JSON.stringify({ success: true, message: "Public feed wiped clean." }), { headers: CORS_HEADERS, status: 200 });
      }

      return new Response(JSON.stringify({ error: "Endpoint not found" }), { headers: CORS_HEADERS, status: 404 });
    } catch (err) {
      return new Response(JSON.stringify({ error: err.message }), { headers: CORS_HEADERS, status: 500 });
    }
  }
};
