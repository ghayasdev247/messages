-- ====================================================================
-- ACCESSIBLE ANONYMOUS MESSENGER FOR JIESHUO / COMMENTARY SCREEN READER
-- Developed in AndroLua+
-- Version: 2.3.0 (Build Code: 30)
-- Features: Multi-Select Add Members with Checkboxes, Group & Message Deduplication,
--           Permanent Voice Button Labels, Zero-Lag Presence & 5-Tab Navigation
-- ====================================================================

require "import"
import "android.app.*"
import "android.os.*"
import "android.widget.*"
import "android.view.*"
import "android.graphics.*"
import "android.graphics.Typeface"
import "android.text.InputType"
import "android.content.Context"
import "android.content.DialogInterface"
import "java.io.File"

-- --------------------------------------------------------------------
-- CONFIGURATION & GLOBAL STATE
-- --------------------------------------------------------------------
local APP_VERSION = "2.3.0"
local APP_VERSION_CODE = 30

local VERSION_MANIFEST_URL = "https://raw.githubusercontent.com/ghayasdev247/messages/main/data/version.json"
local LUA_UPDATE_URL = "https://raw.githubusercontent.com/ghayasdev247/messages/main/main.lua"
local XPK_UPDATE_URL = "https://raw.githubusercontent.com/ghayasdev247/messages/main/Chatify%20Accessible%20Messenger%20for%20the%20Blind_Updated.xpk"

-- Primary Live Firebase Realtime Database Endpoint
local FIREBASE_URL = "https://messages-server-f2a99-default-rtdb.asia-southeast1.firebasedatabase.app"

-- Active PC Wi-Fi Server IP
local BACKEND_URL = "http://10.20.244.148:5000"

local GITHUB_OWNER = "ghayasdev247"
local GITHUB_REPO = "messages"
local GITHUB_BRANCH = "main"

local currentUser = { name = "", online = false, githubToken = "", bio = "Accessible Messenger User" }
local activeTab = "home" -- "home", "lounge", "public", "private", "you"
local activeChatTarget = ""
local activeGroup = nil
local isPolling = false

local lastPublicMessageCount = 0
local lastPrivateMessageCount = 0
local lastGroupMessageCount = 0
local lastRenderedPublicCount = -1
local lastRenderedPrivateCount = -1
local lastRenderedGroupCount = -1
local lastRenderedUsersSignature = ""

-- Audio Recording Global State
local mediaRecorder = nil
local isRecordingVoice = false
local voiceRecordPath = ""
local activeVoicePlayer = nil

-- Data Stores
local publicFeedMessages = {}
local onlineUsersList = {}
local privateChatHistory = {}
local groupsList = {}
local groupChatHistory = {}
local groupSearchQuery = ""

-- --------------------------------------------------------------------
-- STORAGE DIRECTORY RESOLVER
-- --------------------------------------------------------------------
function getAppAudioDir()
  local dir = "/sdcard/Download/Accessible_Messenger_Voice"
  pcall(function()
    if activity and activity.getExternalFilesDir then
      local ext = activity.getExternalFilesDir("voice_notes")
      if ext then dir = ext.getAbsolutePath() end
    elseif activity and activity.getFilesDir then
      local f = activity.getFilesDir()
      if f then dir = f.getAbsolutePath() .. "/voice_notes" end
    end
  end)
  pcall(function()
    local folder = File(dir)
    if not folder.exists() then folder.mkdirs() end
  end)
  return dir
end

function getSavedAccountPath()
  return getAppAudioDir() .. "/saved_account.json"
end

function getChatFilePath(u1, u2)
  local u1_lower = string.lower(u1)
  local u2_lower = string.lower(u2)
  if u1_lower < u2_lower then
    return "data/chats/" .. u1 .. "_" .. u2 .. ".json"
  else
    return "data/chats/" .. u2 .. "_" .. u1 .. ".json"
  end
end

function getGroupChatFilePath(groupId)
  return "data/groups/" .. groupId .. "_messages.json"
end

-- --------------------------------------------------------------------
-- JSON & FAST CHUNKED BASE64 ENGINE
-- --------------------------------------------------------------------
local jsonModule = nil
pcall(function() jsonModule = require("cjson") end)

function decodeJSON(str)
  if not str or str == "" then return nil end
  if jsonModule and jsonModule.decode then
    local ok, res = pcall(jsonModule.decode, str)
    if ok then return res end
  end
  local ok, res = pcall(loadstring("return " .. str:gsub('"(%w+)":', '["%1"]=')))
  if ok then return res end
  return nil
end

function encodeJSON(val)
  if jsonModule and jsonModule.encode then
    local ok, res = pcall(jsonModule.encode, val)
    if ok then return res end
  end
  if type(val) == "table" then
    local isArray = #val > 0 or next(val) == nil
    local parts = {}
    if isArray then
      for _, item in ipairs(val) do
        table.insert(parts, encodeJSON(item))
      end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      for k, v in pairs(val) do
        table.insert(parts, string.format("%q:%s", tostring(k), encodeJSON(v)))
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  elseif type(val) == "string" then
    return string.format("%q", val)
  elseif type(val) == "number" or type(val) == "boolean" then
    return tostring(val)
  else
    return "null"
  end
end

local b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local b64lookup = {}
for i = 1, 64 do
  b64lookup[b64chars:sub(i, i)] = i - 1
end

function base64Encode(data)
  if not data or data == "" then return "" end
  local len = #data
  local out = {}
  local index = 1
  for i = 1, len, 3 do
    local b1 = data:byte(i)
    local b2 = data:byte(i + 1) or 0
    local b3 = data:byte(i + 2) or 0
    
    local n = b1 * 65536 + b2 * 256 + b3
    
    local c1 = math.floor(n / 262144) % 64 + 1
    local c2 = math.floor(n / 4096) % 64 + 1
    local c3 = math.floor(n / 64) % 64 + 1
    local c4 = n % 64 + 1
    
    out[index] = b64chars:sub(c1, c1)
    out[index + 1] = b64chars:sub(c2, c2)
    out[index + 2] = (i + 1 <= len) and b64chars:sub(c3, c3) or "="
    out[index + 3] = (i + 2 <= len) and b64chars:sub(c4, c4) or "="
    index = index + 4
  end
  return table.concat(out)
end

function base64Decode(data)
  if not data or data == "" or type(data) ~= "string" then return "" end
  local ok, res = pcall(function()
    local clean = data:gsub("[^A-Za-z0-9+/=]", "")
    local len = #clean
    if len % 4 ~= 0 then return "" end
    
    local out = {}
    local index = 1
    for i = 1, len, 4 do
      local c1 = b64lookup[clean:sub(i, i)] or 0
      local c2 = b64lookup[clean:sub(i + 1, i + 1)] or 0
      local c3_char = clean:sub(i + 2, i + 2)
      local c4_char = clean:sub(i + 3, i + 3)
      
      local c3 = (c3_char ~= "=") and (b64lookup[c3_char] or 0) or 0
      local c4 = (c4_char ~= "=") and (b64lookup[c4_char] or 0) or 0
      
      local n = c1 * 262144 + c2 * 4096 + c3 * 64 + c4
      
      local b1 = math.floor(n / 65536) % 256
      local b2 = math.floor(n / 256) % 256
      local b3 = n % 256
      
      out[index] = string.char(b1)
      index = index + 1
      if c3_char ~= "=" then
        out[index] = string.char(b2)
        index = index + 1
      end
      if c4_char ~= "=" then
        out[index] = string.char(b3)
        index = index + 1
      end
    end
    return table.concat(out)
  end)
  if ok and res then return res end
  return ""
end

function encodeAudioFileToBase64(filePath)
  local b64Result = ""
  pcall(function()
    local f = io.open(filePath, "rb")
    if f then
      local data = f:read("*a")
      f:close()
      if data and #data > 0 then
        b64Result = base64Encode(data)
      end
    end
  end)
  return b64Result
end

function decodeBase64ToAudioFile(b64Data, targetPath)
  local success = false
  pcall(function()
    local cleanB64 = b64Data:gsub("^data:audio/[%w%+]+;base64,", "")
    local decodedBytes = base64Decode(cleanB64)
    if decodedBytes and #decodedBytes > 0 then
      local f = io.open(targetPath, "wb")
      if f then
        f:write(decodedBytes)
        f:close()
        success = true
      end
    end
  end)
  return success
end

-- --------------------------------------------------------------------
-- MESSAGE DEDUPLICATION & CHRONOLOGICAL SORTING ENGINE
-- --------------------------------------------------------------------
function deduplicateAndSortMessages(msgList)
  if type(msgList) ~= "table" then return {} end
  local cleanList = {}
  local seenSignatures = {}
  
  for _, m in ipairs(msgList) do
    if type(m) == "table" then
      local sender = string.lower(tostring(m.sender or ""))
      local text = tostring(m.text or "")
      local timeStr = tostring(m.time or "")
      local isVoice = (m.isVoice or m.audio or m.voicePath) and "1" or "0"
      local sig = sender .. "||" .. text .. "||" .. isVoice .. "||" .. timeStr
      
      if not seenSignatures[sig] then
        seenSignatures[sig] = true
        table.insert(cleanList, m)
      end
    end
  end
  
  table.sort(cleanList, function(a, b)
    local tA = tonumber(a.timestamp or 0) or 0
    local tB = tonumber(b.timestamp or 0) or 0
    if tA ~= tB and tA > 0 and tB > 0 then
      return tA < tB
    end
    local kA = tostring(a._fb_key or a.time or "")
    local kB = tostring(b._fb_key or b.time or "")
    return kA < kB
  end)
  
  return cleanList
end

function announce(text)
  pcall(function()
    Toast.makeText(activity, text, Toast.LENGTH_SHORT).show()
    activity.getWindow().getDecorView().announceForAccessibility(text)
  end)
end

-- --------------------------------------------------------------------
-- PERMANENT SAVED ACCOUNTS ENGINE (Remember Me)
-- --------------------------------------------------------------------
function saveUserCredentials(username, password, remember)
  if not remember then
    clearSavedCredentials()
    return
  end
  local data = {
    username = username,
    password = password,
    saved_at = os.time()
  }
  pcall(function()
    local path = getSavedAccountPath()
    local f = io.open(path, "w")
    if f then
      f:write(encodeJSON(data))
      f:close()
    end
  end)
end

function loadSavedCredentials()
  local path = getSavedAccountPath()
  local creds = nil
  pcall(function()
    local f = io.open(path, "r")
    if f then
      local content = f:read("*a")
      f:close()
      if content and content ~= "" then
        creds = decodeJSON(content)
      end
    end
  end)
  return creds
end

function clearSavedCredentials()
  pcall(function()
    local path = getSavedAccountPath()
    local f = File(path)
    if f.exists() then f.delete() end
  end)
end

-- --------------------------------------------------------------------
-- EPHEMERAL STORAGE CLEANUP ENGINE
-- --------------------------------------------------------------------
function purgeEphemeralAudioFiles()
  pcall(function()
    local voiceFolder = getAppAudioDir()
    local folder = File(voiceFolder)
    if folder.exists() and folder.isDirectory() then
      local files = folder.listFiles()
      if files then
        for i = 0, #files - 1 do
          local name = files[i].getName()
          if name ~= "saved_account.json" then
            files[i].delete()
          end
        end
      end
    end
  end)
end

function purgeCloudFeed(path)
  local fbPath = path:gsub("%.json$", "")
  local fbUrl = FIREBASE_URL .. "/" .. fbPath .. ".json"
  Http.post(fbUrl, "[]", function() end)
end

-- --------------------------------------------------------------------
-- LOCAL CHAT EXPORTER
-- --------------------------------------------------------------------
function saveChatLocally(chatType, targetName, messagesList)
  local downloadDir = "/sdcard/Download/Accessible_Messenger_Chats"
  pcall(function()
    import "android.os.Environment"
    local baseDownload = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS).getAbsolutePath()
    downloadDir = baseDownload .. "/Accessible_Messenger_Chats"
  end)
  
  pcall(function()
    local folder = File(downloadDir)
    if not folder.exists() then folder.mkdirs() end
  end)
  
  local cleanTarget = (targetName ~= "") and targetName or "PublicFeed"
  local fileName = chatType .. "_" .. cleanTarget .. "_" .. os.date("%Y%m%d_%H%M%S") .. ".txt"
  local filePath = downloadDir .. "/" .. fileName
  
  local contentLines = {}
  table.insert(contentLines, "==========================================")
  table.insert(contentLines, "ACCESSIBLE MESSENGER EXPORTED CONVERSATION")
  table.insert(contentLines, "Chat Room: " .. cleanTarget)
  table.insert(contentLines, "Exported Date: " .. os.date("%Y-%m-%d %H:%M:%S"))
  table.insert(contentLines, "==========================================")
  table.insert(contentLines, "")
  
  if type(messagesList) == "table" then
    for _, m in ipairs(messagesList) do
      if type(m) == "table" then
        local sender = m.sender or "Anonymous"
        local timeStr = m.time or ""
        local text = m.text or ""
        local rx = (m.reaction and m.reaction ~= "") and (" [Reaction: " .. m.reaction .. "]") or ""
        table.insert(contentLines, string.format("[%s] %s: %s%s", timeStr, sender, text, rx))
      end
    end
  end
  
  local saved = false
  pcall(function()
    local f = io.open(filePath, "w")
    if f then
      f:write(table.concat(contentLines, "\n"))
      f:close()
      saved = true
    end
  end)
  
  if saved then
    announce("Chat saved locally to Downloads: Accessible_Messenger_Chats/" .. fileName)
  else
    announce("Failed to save chat locally.")
  end
end

-- --------------------------------------------------------------------
-- GITHUB REST API ENGINE
-- --------------------------------------------------------------------
function fetchGitHubFile(filePath, callback)
  local apiUrl = string.format("https://api.github.com/repos/%s/%s/contents/%s?ref=%s&t=%d",
    GITHUB_OWNER, GITHUB_REPO, filePath, GITHUB_BRANCH, os.time())
  
  local headers = {}
  headers["User-Agent"] = "Chatify-Accessible-Client"
  headers["Accept"] = "application/vnd.github.v3+json"
  headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
  if currentUser.githubToken and currentUser.githubToken ~= "" then
    headers["Authorization"] = "token " .. currentUser.githubToken
  end

  Http.get(apiUrl, nil, nil, headers, function(code, content)
    if code == 200 then
      local resp = decodeJSON(content)
      if resp and resp.content then
        local rawData = base64Decode(resp.content:gsub("%s+", ""))
        callback(true, decodeJSON(rawData), resp.sha)
      else
        callback(false, nil, nil)
      end
    elseif code == 404 then
      callback(true, nil, nil)
    else
      callback(false, nil, nil)
    end
  end)
end

function commitGitHubFile(filePath, newTableData, commitMessage, callback)
  local apiUrl = string.format("https://api.github.com/repos/%s/%s/contents/%s", GITHUB_OWNER, GITHUB_REPO, filePath)
  local headers = {}
  headers["User-Agent"] = "Chatify-Accessible-Client"
  headers["Accept"] = "application/vnd.github.v3+json"
  headers["Content-Type"] = "application/json"
  if currentUser.githubToken and currentUser.githubToken ~= "" then
    headers["Authorization"] = "token " .. currentUser.githubToken
  end

  fetchGitHubFile(filePath, function(ok, currentData, sha)
    local payload = {
      message = commitMessage,
      content = base64Encode(encodeJSON(newTableData)),
      branch = GITHUB_BRANCH
    }
    if sha then payload.sha = sha end

    Http.post(apiUrl, encodeJSON(payload), nil, nil, headers, function(pCode, pContent)
      if pCode == 200 or pCode == 201 then
        if callback then callback(true) end
      else
        if callback then callback(false) end
      end
    end)
  end)
end

-- --------------------------------------------------------------------
-- STORAGE & REMOTE UPDATE ENGINE
-- --------------------------------------------------------------------
function checkForRemoteUpdates(manualCheck)
  if manualCheck then
    announce("Checking for updates...")
  end
  
  Http.get(BACKEND_URL .. "/api/version", function(lCode, lContent)
    if lCode == 200 then
      local manifest = decodeJSON(lContent)
      if manifest and manifest.version_code and (tonumber(manifest.version_code) or 1) > APP_VERSION_CODE then
        local versionStr = manifest.version or tostring(manifest.version_code)
        announce("Downloading update Version " .. versionStr .. " from Local Server...")
        Http.get(BACKEND_URL .. "/api/download-lua", function(uCode, uContent)
          if uCode == 200 and uContent and uContent ~= "" then
            saveUpdateFile(versionStr, uContent)
            return
          end
        end)
        return
      end
    end
    
    local checkUrl = VERSION_MANIFEST_URL .. "?t=" .. os.time()
    Http.get(checkUrl, function(code, content)
      if code == 200 then
        local manifest = decodeJSON(content)
        if manifest and manifest.version_code and (tonumber(manifest.version_code) or 1) > APP_VERSION_CODE then
          local versionStr = manifest.version or tostring(manifest.version_code)
          announce("Downloading update Version " .. versionStr .. " from GitHub...")
          local updateUrl = (manifest.download_url or LUA_UPDATE_URL) .. "?t=" .. os.time()
          Http.get(updateUrl, function(uCode, uContent)
            if uCode == 200 and uContent and uContent ~= "" then
              saveUpdateFile(versionStr, uContent)
            else
              announce("Failed to download update script from GitHub.")
            end
          end)
          return
        end
      end
      
      if manualCheck then
        announce("You are using the latest version of Accessible Messenger (v" .. APP_VERSION .. ").")
      end
    end)
  end)
end

function saveUpdateFile(versionStr, uContent)
  local downloadDir = "/sdcard/Download"
  pcall(function()
    import "android.os.Environment"
    downloadDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS).getAbsolutePath()
  end)
  
  local fileName = "Accessible_Messenger_v" .. versionStr .. ".lua"
  local savePath = downloadDir .. "/" .. fileName
  
  pcall(function()
    local file = io.open(savePath, "w")
    if file then
      file:write(uContent)
      file:close()
    end
  end)
  
  local jieshuoPaths = {
    "/sdcard/JieShuo/tools/Chatify Accessible Messenger for the Blind/main.lua",
    "/sdcard/JieShuo/tools/Accessible Messenger/main.lua",
    activity.getFilesDir().getAbsolutePath() .. "/main.lua"
  }
  
  for _, jPath in ipairs(jieshuoPaths) do
    pcall(function()
      local f = io.open(jPath, "w")
      if f then
        f:write(uContent)
        f:close()
      end
    end)
  end
  
  announce("Update v" .. versionStr .. " successful! Saved to Download folder: " .. fileName .. ". Re-import plugin in Jieshuo to apply.")
end

-- --------------------------------------------------------------------
-- UNIFIED NETWORKING ENGINE
-- --------------------------------------------------------------------
function fetchFirebaseData(path, callback)
  local fbPath = path:gsub("%.json$", "")
  local fbUrl = FIREBASE_URL .. "/" .. fbPath .. ".json?t=" .. os.time()
  
  Http.get(fbUrl, function(code, content)
    if code == 200 and content and content ~= "null" then
      local fbData = decodeJSON(content)
      if fbData and type(fbData) == "table" then
        local list = {}
        if fbData[1] ~= nil then
          for _, item in ipairs(fbData) do
            if type(item) == "table" then
              table.insert(list, item)
            end
          end
        else
          for k, v in pairs(fbData) do
            if type(v) == "table" then
              v._fb_key = tostring(k)
              table.insert(list, v)
            end
          end
        end
        callback(true, list)
        return
      end
    end
    callback(false, nil)
  end)
end

function postFirebaseData(path, payload, callback)
  local fbPath = path:gsub("%.json$", "")
  local fbUrl = FIREBASE_URL .. "/" .. fbPath .. ".json"
  local payloadStr = encodeJSON(payload)
  
  Http.post(fbUrl, payloadStr, function(code, content)
    if (code == 200 or code == 201) and callback then
      callback(true)
    elseif callback then
      callback(false)
    end
  end)
end

function apiGet(endpoint, githubFilePath, callback)
  fetchFirebaseData(githubFilePath, function(fbSuccess, fbData)
    if fbSuccess and fbData and type(fbData) == "table" and #fbData > 0 then
      callback(true, fbData)
      return
    end
    
    Http.get(BACKEND_URL .. endpoint, function(code, content)
      if code == 200 then
        local res = decodeJSON(content)
        if res and (res.success or res.messages or res.users or res.groups) then
          local fetched = res.messages or res.users or res.groups or res
          callback(true, fetched)
          return
        end
      end
      
      fetchGitHubFile(githubFilePath, function(success, data)
        callback(success, data)
      end)
    end)
  end)
end

function apiPost(endpoint, payload, callback)
  local payloadStr = encodeJSON(payload)
  local headers = { ["Content-Type"] = "application/json" }

  if string.find(endpoint, "/api/public%-feed") then
    local msgObj = {
      sender = payload.sender or currentUser.name,
      text = payload.text,
      isVoice = payload.isVoice,
      audio = payload.audio,
      time = payload.time or os.date("%I:%M %p"),
      timestamp = os.time()
    }
    postFirebaseData("data/public_feed", msgObj, function() end)
    Http.post(BACKEND_URL .. endpoint, payloadStr, nil, nil, headers, function() end)
    fetchGitHubFile("data/public_feed.json", function(ok, currentFeed)
      local feedToSave = currentFeed or {}
      table.insert(feedToSave, msgObj)
      commitGitHubFile("data/public_feed.json", feedToSave, "Public message from " .. msgObj.sender, callback)
    end)

  elseif string.find(endpoint, "/api/private%-messages") then
    local msgObj = {
      sender = payload.sender or currentUser.name,
      recipient = payload.recipient,
      text = payload.text,
      isVoice = payload.isVoice,
      audio = payload.audio,
      time = payload.time or os.date("%I:%M %p"),
      timestamp = os.time()
    }
    local filePath = getChatFilePath(msgObj.sender, msgObj.recipient)
    postFirebaseData(filePath, msgObj, function() end)
    Http.post(BACKEND_URL .. endpoint, payloadStr, nil, nil, headers, function() end)
    fetchGitHubFile(filePath, function(ok, currentThread)
      local threadToSave = currentThread or {}
      table.insert(threadToSave, msgObj)
      commitGitHubFile(filePath, threadToSave, "Private message to " .. msgObj.recipient, callback)
    end)

  elseif string.find(endpoint, "/api/group%-messages") then
    local msgObj = {
      sender = payload.sender or currentUser.name,
      groupId = payload.groupId,
      text = payload.text,
      isVoice = payload.isVoice,
      audio = payload.audio,
      time = payload.time or os.date("%I:%M %p"),
      timestamp = os.time()
    }
    local filePath = getGroupChatFilePath(msgObj.groupId)
    postFirebaseData(filePath, msgObj, function() end)
    Http.post(BACKEND_URL .. endpoint, payloadStr, nil, nil, headers, function() end)
    fetchGitHubFile(filePath, function(ok, currentThread)
      local threadToSave = currentThread or {}
      table.insert(threadToSave, msgObj)
      commitGitHubFile(filePath, threadToSave, "Group message in " .. msgObj.groupId, callback)
    end)

  elseif string.find(endpoint, "/api/heartbeat") or string.find(endpoint, "/api/login") then
    local username = payload.username or currentUser.name
    if username and username ~= "" then
      local now_ts = os.time()
      local userObj = { name = username, last_seen = now_ts, status = "Online" }
      postFirebaseData("data/online_users", userObj, function(fbOk)
        if callback then callback(true) end
      end)
      Http.post(BACKEND_URL .. endpoint, payloadStr, nil, nil, headers, function() end)
    else
      if callback then callback(false) end
    end
  else
    if callback then callback(false) end
  end
end

-- --------------------------------------------------------------------
-- ANDROID SCREEN-READER ACCESSIBLE VOICE RECORDING & PLAYBACK ENGINE
-- --------------------------------------------------------------------
function downloadAndPlayVoiceNote(msgItem)
  import "android.media.MediaPlayer"
  
  if not msgItem then return end
  local audioData = msgItem.audio or msgItem.voicePath
  
  if not audioData or audioData == "" then
    announce("Error: Voice note audio data not found.")
    return
  end
  
  local voiceFolder = getAppAudioDir()
  local msgHash = (msgItem.sender or "voice") .. "_" .. (msgItem.time or "now"):gsub("%s+", ""):gsub(":", "")
  local targetAudioFile = voiceFolder .. "/voice_" .. msgHash .. ".m4a"
  local isFileReady = false
  
  pcall(function()
    local fObj = File(targetAudioFile)
    if fObj.exists() and fObj.length() > 0 then
      isFileReady = true
    end
  end)

  if not isFileReady then
    local fallback3gp = voiceFolder .. "/voice_" .. msgHash .. ".3gp"
    pcall(function()
      local fObj = File(fallback3gp)
      if fObj.exists() and fObj.length() > 0 then
        targetAudioFile = fallback3gp
        isFileReady = true
      end
    end)
  end

  if not isFileReady then
    pcall(function()
      local fObj = File(audioData)
      if fObj.exists() and fObj.length() > 0 then
        targetAudioFile = audioData
        isFileReady = true
      end
    end)
  end
  
  if not isFileReady then
    announce("Downloading voice note...")
    isFileReady = decodeBase64ToAudioFile(audioData, targetAudioFile)
  end
  
  if isFileReady then
    announce("Playing voice note...")
    pcall(function()
      if activeVoicePlayer then
        pcall(function()
          if activeVoicePlayer.isPlaying() then activeVoicePlayer.stop() end
          activeVoicePlayer.release()
        end)
        activeVoicePlayer = nil
      end
      
      activeVoicePlayer = MediaPlayer()
      activeVoicePlayer.reset()
      activeVoicePlayer.setDataSource(targetAudioFile)
      activeVoicePlayer.prepare()
      activeVoicePlayer.start()
      
      activeVoicePlayer.setOnCompletionListener(MediaPlayer.OnCompletionListener{
        onCompletion = function(player)
          announce("Voice note finished playing.")
          pcall(function() player.release() end)
          activeVoicePlayer = nil
        end
      })
    end)
  else
    announce("Failed to decode voice note audio.")
  end
end

function setupHoldToRecordVoiceButton(btnWidget, isPublic, targetName, isGroup)
  import "android.media.MediaRecorder"
  
  btnWidget.setText("🎙️ Voice")
  btnWidget.setTextColor(0xFFFFFFFF)
  btnWidget.setContentDescription("Record voice note button. Double tap to start or stop recording.")
  
  local function startVoiceRecording()
    if isRecordingVoice then return end
    local ok = pcall(function()
      local voiceFolder = getAppAudioDir()
      voiceRecordPath = voiceFolder .. "/voice_" .. os.time() .. ".m4a"
      
      mediaRecorder = MediaRecorder()
      mediaRecorder.setAudioSource(MediaRecorder.AudioSource.MIC)
      mediaRecorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
      mediaRecorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
      mediaRecorder.setAudioSamplingRate(44100)
      mediaRecorder.setAudioEncodingBitRate(128000)
      mediaRecorder.setOutputFile(voiceRecordPath)
      mediaRecorder.prepare()
      mediaRecorder.start()
      isRecordingVoice = true
      
      btnWidget.setText("⏹️ Stop")
      btnWidget.setTextColor(0xFFFFCDD2)
      btnWidget.setContentDescription("Recording voice note. Double tap to stop and send.")
      announce("Recording HD voice note. Speak now, then tap to stop and send.")
    end)
    if not ok then
      pcall(function()
        local voiceFolder = getAppAudioDir()
        voiceRecordPath = voiceFolder .. "/voice_" .. os.time() .. ".3gp"
        mediaRecorder = MediaRecorder()
        mediaRecorder.setAudioSource(MediaRecorder.AudioSource.MIC)
        mediaRecorder.setOutputFormat(MediaRecorder.OutputFormat.THREE_GPP)
        mediaRecorder.setAudioEncoder(MediaRecorder.AudioEncoder.AMR_NB)
        mediaRecorder.setOutputFile(voiceRecordPath)
        mediaRecorder.prepare()
        mediaRecorder.start()
        isRecordingVoice = true
        btnWidget.setText("⏹️ Stop")
        btnWidget.setTextColor(0xFFFFCDD2)
        btnWidget.setContentDescription("Recording voice note. Double tap to stop and send.")
        announce("Recording voice note. Speak now, then tap to stop and send.")
      end)
    end
  end
  
  local function stopAndSendVoiceRecording()
    if not isRecordingVoice then return end
    pcall(function()
      if mediaRecorder then
        mediaRecorder.stop()
        mediaRecorder.release()
        mediaRecorder = nil
      end
    end)
    isRecordingVoice = false
    btnWidget.setText("🎙️ Voice")
    btnWidget.setTextColor(0xFFFFFFFF)
    btnWidget.setContentDescription("Record voice note button. Double tap to record.")
    
    local b64Audio = encodeAudioFileToBase64(voiceRecordPath)
    if b64Audio and #b64Audio > 10 then
      local msgObj = {
        sender = currentUser.name,
        recipient = targetName,
        groupId = targetName,
        text = "🎤 Voice Message 🔊",
        isVoice = true,
        audio = b64Audio,
        voicePath = voiceRecordPath,
        time = os.date("%I:%M %p"),
        timestamp = os.time()
      }
      
      if isGroup then
        apiPost("/api/group-messages", msgObj, function() fetchGroupChatThread(targetName) end)
      elseif isPublic then
        apiPost("/api/public-feed", msgObj, function() fetchPublicFeedMessages() end)
      else
        apiPost("/api/private-messages", msgObj, function() fetchPrivateChatThread(targetName) end)
      end
      announce("Voice message sent successfully!")
    else
      announce("Voice recording too short or cancelled.")
    end
  end
  
  btnWidget.onClick = function()
    if not isRecordingVoice then
      startVoiceRecording()
    else
      stopAndSendVoiceRecording()
    end
  end
end

-- --------------------------------------------------------------------
-- LONG-PRESS-ONLY MESSAGE OPTIONS MODAL
-- --------------------------------------------------------------------
function showMessageOptionsDialog(msgItem, msgIndex, isPublic, targetName, isGroup)
  local options = { "❤️ React with Emoji", "↩️ Reply to Message", "📌 Pin Message", "🗑️ Delete Message" }

  local builder = AlertDialog.Builder(activity)
  builder.setTitle("Message Options")
  builder.setItems(options, DialogInterface.OnClickListener{
    onClick = function(dialog, which)
      local selectedOption = options[which + 1]
      
      if string.find(selectedOption, "React") then
        showEmojiReactionDialog(msgItem, msgIndex, isPublic, targetName, isGroup)
      elseif string.find(selectedOption, "Reply") then
        local replyPrefix = string.format("Replying to %s: \"%s\"\n---\n", msgItem.sender or "User", msgItem.text or "")
        pcall(function()
          if isGroup and editGroupMessageInput then
            editGroupMessageInput.setText(replyPrefix)
            pcall(function() editGroupMessageInput.setSelection(string.len(replyPrefix)) end)
            editGroupMessageInput.requestFocus()
          elseif isPublic and editPublicMessageInput then
            editPublicMessageInput.setText(replyPrefix)
            pcall(function() editPublicMessageInput.setSelection(string.len(replyPrefix)) end)
            editPublicMessageInput.requestFocus()
          elseif editMessageInput then
            editMessageInput.setText(replyPrefix)
            pcall(function() editMessageInput.setSelection(string.len(replyPrefix)) end)
            editMessageInput.requestFocus()
          end
        end)
        announce("Replying to message from " .. (msgItem.sender or "User"))
      elseif string.find(selectedOption, "Pin") then
        local pinnedText = string.format("📌 Pinned [%s]: %s", msgItem.sender or "User", msgItem.text or "")
        announce("Pinned message: " .. (msgItem.text or ""))
        Toast.makeText(activity, pinnedText, Toast.LENGTH_LONG).show()
      elseif string.find(selectedOption, "Delete") then
        if isGroup then
          if groupChatHistory[targetName] then
            table.remove(groupChatHistory[targetName], msgIndex)
            updateGroupChatUI(targetName)
          end
        elseif isPublic then
          table.remove(publicFeedMessages, msgIndex)
          updatePublicFeedUI()
        else
          if privateChatHistory[targetName] then
            table.remove(privateChatHistory[targetName], msgIndex)
            updatePrivateChatUI(targetName)
          end
        end
        announce("Message deleted.")
      end
    end
  })
  builder.show()
end

function showEmojiReactionDialog(msgItem, msgIndex, isPublic, targetName, isGroup)
  local emojis = { "👍 Like", "❤️ Love", "😂 Laugh", "😮 Wow", "😢 Sad", "🔥 Fire" }
  local emojiCodes = { "👍", "❤️", "😂", "😮", "😢", "🔥" }
  
  local builder = AlertDialog.Builder(activity)
  builder.setTitle("Choose Reaction")
  builder.setItems(emojis, DialogInterface.OnClickListener{
    onClick = function(dialog, which)
      local chosenEmoji = emojiCodes[which + 1]
      msgItem.reaction = chosenEmoji
      if isGroup then
        updateGroupChatUI(targetName)
      elseif isPublic then
        updatePublicFeedUI()
      else
        updatePrivateChatUI(targetName)
      end
      announce("Reacted with " .. emojis[which + 1] .. " to message")
    end
  })
  builder.show()
end

-- --------------------------------------------------------------------
-- 1. LOGIN SCREEN WITH PERMANENT ACCOUNT & REMEMBER ME
-- --------------------------------------------------------------------
function showLoginScreen()
  activeTab = "login"
  isPolling = false
  
  local savedAccount = loadSavedCredentials()
  
  local loginLayout = {
    LinearLayout;
    orientation = "vertical";
    layout_width = "fill";
    layout_height = "fill";
    padding = "20dp";
    backgroundColor = "#F4F6F9";
    {
      TextView;
      text = "Accessible Messenger";
      textSize = "26sp";
      textColor = "#075E54";
      Typeface = Typeface.DEFAULT_BOLD;
      layout_gravity = "center";
      padding = "10dp";
      ContentDescription = "Accessible Messenger Application Header";
    };
    {
      TextView;
      text = "Anonymous Cloud Login (v" .. APP_VERSION .. ")";
      textSize = "15sp";
      textColor = "#555555";
      layout_gravity = "center";
      layout_marginBottom = "15dp";
      ContentDescription = "Subtitle: Anonymous Cloud Login version " .. APP_VERSION;
    };
    {
      LinearLayout;
      id = "layoutQuickConnect";
      orientation = "vertical";
      layout_width = "fill";
      padding = "14dp";
      backgroundColor = "#E0F2F1";
      layout_marginBottom = "15dp";
      visibility = (savedAccount ~= nil) and View.VISIBLE or View.GONE;
      {
        TextView;
        id = "txtSavedUser";
        text = "⚡ Saved Account: " .. (savedAccount and savedAccount.username or "");
        textSize = "16sp";
        textColor = "#004D40";
        Typeface = Typeface.DEFAULT_BOLD;
        ContentDescription = "Saved account found on this device.";
      };
      {
        Button;
        id = "btnQuickConnect";
        text = "Connect as Saved User";
        layout_width = "fill";
        layout_height = "48dp";
        layout_marginTop = "8dp";
        backgroundColor = "#00796B";
        textColor = "#FFFFFF";
        textSize = "15sp";
        ContentDescription = "Connect as Saved User button. Double tap to sign in instantly.";
      };
      {
        Button;
        id = "btnRemoveSavedAccount";
        text = "Forget / Remove Saved Account";
        layout_width = "fill";
        layout_height = "38dp";
        layout_marginTop = "6dp";
        backgroundColor = "#CFD8DC";
        textColor = "#37474F";
        textSize = "13sp";
        ContentDescription = "Forget Saved Account button. Double tap to remove saved credentials.";
      };
    };
    {
      TextView;
      text = "Step 1: Enter Username";
      textSize = "15sp";
      textColor = "#222222";
      layout_marginTop = "5dp";
      ContentDescription = "Step 1: Enter Username label";
    };
    {
      EditText;
      id = "editUsername";
      hint = "Type any alias or handle";
      layout_width = "fill";
      textSize = "17sp";
      padding = "14dp";
      backgroundColor = "#FFFFFF";
      text = (savedAccount and savedAccount.username or "");
      ContentDescription = "Username edit box.";
    };
    {
      TextView;
      text = "Step 2: Enter Password";
      textSize = "15sp";
      textColor = "#222222";
      layout_marginTop = "12dp";
      ContentDescription = "Step 2: Enter Password label";
    };
    {
      EditText;
      id = "editPassword";
      hint = "Type a password";
      inputType = InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD;
      layout_width = "fill";
      textSize = "17sp";
      padding = "14dp";
      backgroundColor = "#FFFFFF";
      text = (savedAccount and savedAccount.password or "");
      ContentDescription = "Password edit box.";
    };
    {
      CheckBox;
      id = "chkRememberMe";
      text = "Remember me on this device (Save Account)";
      textSize = "15sp";
      textColor = "#075E54";
      layout_marginTop = "10dp";
      checked = (savedAccount ~= nil);
      ContentDescription = "Remember me on this device checkbox.";
    };
    {
      Button;
      id = "btnLogin";
      text = "Connect to Messenger";
      layout_width = "fill";
      layout_height = "55dp";
      layout_marginTop = "20dp";
      backgroundColor = "#075E54";
      textColor = "#FFFFFF";
      textSize = "18sp";
      ContentDescription = "Connect to Messenger button. Double tap to sign in.";
    };
    {
      Button;
      id = "btnCheckUpdate";
      text = "🔄 Check for Auto Updates";
      layout_width = "fill";
      layout_height = "45dp";
      layout_marginTop = "10dp";
      backgroundColor = "#455A64";
      textColor = "#FFFFFF";
      textSize = "14sp";
      ContentDescription = "Check for Auto Updates button.";
    };
  }

  activity.setContentView(loadlayout(loginLayout))
  
  if btnQuickConnect then
    btnQuickConnect.onClick = function()
      if savedAccount and savedAccount.username and savedAccount.username ~= "" then
        executeLogin(savedAccount.username, savedAccount.password or "", true)
      end
    end
  end
  
  if btnRemoveSavedAccount then
    btnRemoveSavedAccount.onClick = function()
      clearSavedCredentials()
      savedAccount = nil
      layoutQuickConnect.setVisibility(View.GONE)
      editUsername.setText("")
      editPassword.setText("")
      chkRememberMe.setChecked(false)
      announce("Saved account credentials removed from device.")
    end
  end
  
  btnCheckUpdate.onClick = function()
    checkForRemoteUpdates(true)
  end
  
  btnLogin.onClick = function()
    local name = editUsername.getText().toString()
    local pass = editPassword.getText().toString()
    local remember = chkRememberMe.isChecked()
    
    if name == "" or pass == "" then
      announce("Error: Please enter both a username and password.")
      return
    end
    
    executeLogin(name, pass, remember)
  end
end

function executeLogin(name, pass, remember)
  announce("Connecting to messenger...")
  currentUser.name = name
  currentUser.online = true
  saveUserCredentials(name, pass, remember)
  
  apiPost("/api/login", { username = name, password = pass }, function(success) end)
  
  announce("Connected as " .. name .. ". Welcome to Homepage.")
  showMainAppContainer()
  switchTab("home")
  startPollingLoop()
end

-- --------------------------------------------------------------------
-- 2. UNIFIED 5-TAB CONTAINER & NAVIGATION ENGINE
-- --------------------------------------------------------------------
function showMainAppContainer()
  local mainContainerLayout = {
    LinearLayout;
    orientation = "vertical";
    layout_width = "fill";
    layout_height = "fill";
    backgroundColor = "#F4F6F9";
    {
      FrameLayout;
      id = "tabContentContainer";
      layout_width = "fill";
      layout_weight = "1";
    };
    {
      LinearLayout;
      id = "bottomTabBar";
      orientation = "horizontal";
      layout_width = "fill";
      layout_height = "60dp";
      backgroundColor = "#FFFFFF";
      gravity = "center_vertical";
      elevation = "8dp";
      {
        Button;
        id = "tabBtnHome";
        text = "🏠 Home";
        layout_weight = "1";
        layout_height = "fill";
        textSize = "12sp";
        textColor = "#075E54";
        backgroundColor = "#FFFFFF";
        ContentDescription = "Home Tab. Double tap to open.";
      };
      {
        Button;
        id = "tabBtnLounge";
        text = "🚀 Lounge";
        layout_weight = "1";
        layout_height = "fill";
        textSize = "12sp";
        textColor = "#555555";
        backgroundColor = "#FFFFFF";
        ContentDescription = "Lounge Groups Tab. Double tap to open.";
      };
      {
        Button;
        id = "tabBtnPublic";
        text = "🌐 Public";
        layout_weight = "1";
        layout_height = "fill";
        textSize = "12sp";
        textColor = "#555555";
        backgroundColor = "#FFFFFF";
        ContentDescription = "Public Lobby Tab. Double tap to open.";
      };
      {
        Button;
        id = "tabBtnPrivate";
        text = "💬 Private";
        layout_weight = "1";
        layout_height = "fill";
        textSize = "12sp";
        textColor = "#555555";
        backgroundColor = "#FFFFFF";
        ContentDescription = "Private Lobby Tab. Double tap to open.";
      };
      {
        Button;
        id = "tabBtnYou";
        text = "👤 You";
        layout_weight = "1";
        layout_height = "fill";
        textSize = "12sp";
        textColor = "#555555";
        backgroundColor = "#FFFFFF";
        ContentDescription = "You Profile and Settings Tab. Double tap to open.";
      };
    };
  }

  activity.setContentView(loadlayout(mainContainerLayout))
  
  tabBtnHome.onClick = function() switchTab("home") end
  tabBtnLounge.onClick = function() switchTab("lounge") end
  tabBtnPublic.onClick = function() switchTab("public") end
  tabBtnPrivate.onClick = function() switchTab("private") end
  tabBtnYou.onClick = function() switchTab("you") end
end

function updateTabButtonsUI(currentTab)
  local buttons = {
    home = tabBtnHome,
    lounge = tabBtnLounge,
    public = tabBtnPublic,
    private = tabBtnPrivate,
    you = tabBtnYou
  }
  for name, btn in pairs(buttons) do
    if btn then
      if name == currentTab then
        btn.setTextColor(0xFF075E54)
        btn.setTypeface(Typeface.DEFAULT_BOLD)
        btn.setBackgroundColor(0xFFE0F2F1)
      else
        btn.setTextColor(0xFF666666)
        btn.setTypeface(Typeface.DEFAULT)
        btn.setBackgroundColor(0xFFFFFFFF)
      end
    end
  end
end

function switchTab(tabName)
  activeTab = tabName
  updateTabButtonsUI(tabName)
  tabContentContainer.removeAllViews()
  
  if tabName == "home" then
    tabContentContainer.addView(createHomeTabView())
    announce("Home Tab selected.")
  elseif tabName == "lounge" then
    tabContentContainer.addView(createLoungeTabView())
    fetchGroupsList()
    announce("Lounge Groups Tab selected.")
  elseif tabName == "public" then
    tabContentContainer.addView(createPublicTabView())
    fetchPublicFeedMessages()
    announce("Public Lobby Tab selected.")
  elseif tabName == "private" then
    tabContentContainer.addView(createPrivateTabView())
    fetchOnlineUsersList()
    announce("Private Lobby Tab selected.")
  elseif tabName == "you" then
    tabContentContainer.addView(createYouTabView())
    announce("You Profile & Settings Tab selected.")
  end
end

-- --------------------------------------------------------------------
-- TAB 1: HOME VIEW
-- --------------------------------------------------------------------
function createHomeTabView()
  local viewLayout = {
    ScrollView;
    layout_width = "fill";
    layout_height = "fill";
    padding = "16dp";
    backgroundColor = "#F4F6F9";
    {
      LinearLayout;
      orientation = "vertical";
      layout_width = "fill";
      layout_height = "wrap";
      {
        TextView;
        text = "Welcome back, " .. currentUser.name .. "!";
        textSize = "22sp";
        textColor = "#075E54";
        Typeface = Typeface.DEFAULT_BOLD;
        layout_marginBottom = "4dp";
      };
      {
        TextView;
        text = "● Connected to Realtime Cloud (v" .. APP_VERSION .. ")";
        textSize = "14sp";
        textColor = "#2E7D32";
        layout_marginBottom = "20dp";
      };
      {
        LinearLayout;
        orientation = "vertical";
        layout_width = "fill";
        padding = "16dp";
        backgroundColor = "#FFFFFF";
        layout_marginBottom = "14dp";
        elevation = "2dp";
        {
          TextView;
          text = "🚀 Quick Discovery: Groups Lounge";
          textSize = "16sp";
          textColor = "#075E54";
          Typeface = Typeface.DEFAULT_BOLD;
        };
        {
          TextView;
          text = "Join public accessibility groups, search topics, or create your own group with privacy & admin approval.";
          textSize = "13sp";
          textColor = "#666666";
          layout_marginTop = "4dp";
          layout_marginBottom = "10dp";
        };
        {
          Button;
          id = "btnHomeOpenLounge";
          text = "Explore Lounge Groups";
          layout_width = "fill";
          layout_height = "46dp";
          backgroundColor = "#00897B";
          textColor = "#FFFFFF";
        };
      };
      {
        LinearLayout;
        orientation = "vertical";
        layout_width = "fill";
        padding = "16dp";
        backgroundColor = "#FFFFFF";
        layout_marginBottom = "14dp";
        elevation = "2dp";
        {
          TextView;
          text = "🌐 Global Public Lobby";
          textSize = "16sp";
          textColor = "#075E54";
          Typeface = Typeface.DEFAULT_BOLD;
        };
        {
          TextView;
          text = "Broadcast and read real-time text and HD voice messages across the global accessible community.";
          textSize = "13sp";
          textColor = "#666666";
          layout_marginTop = "4dp";
          layout_marginBottom = "10dp";
        };
        {
          Button;
          id = "btnHomeOpenPublic";
          text = "Enter Public Lobby";
          layout_width = "fill";
          layout_height = "46dp";
          backgroundColor = "#128C7E";
          textColor = "#FFFFFF";
        };
      };
      {
        LinearLayout;
        orientation = "vertical";
        layout_width = "fill";
        padding = "16dp";
        backgroundColor = "#FFFFFF";
        layout_marginBottom = "14dp";
        elevation = "2dp";
        {
          TextView;
          text = "💬 Active Online 1-on-1 Chats";
          textSize = "16sp";
          textColor = "#075E54";
          Typeface = Typeface.DEFAULT_BOLD;
        };
        {
          TextView;
          text = "Discover who is currently active and initiate private encrypted voice & text chats.";
          textSize = "13sp";
          textColor = "#666666";
          layout_marginTop = "4dp";
          layout_marginBottom = "10dp";
        };
        {
          Button;
          id = "btnHomeOpenPrivate";
          text = "View Online Users";
          layout_width = "fill";
          layout_height = "46dp";
          backgroundColor = "#075E54";
          textColor = "#FFFFFF";
        };
      };
    };
  }
  
  local view = loadlayout(viewLayout)
  if btnHomeOpenLounge then btnHomeOpenLounge.onClick = function() switchTab("lounge") end end
  if btnHomeOpenPublic then btnHomeOpenPublic.onClick = function() switchTab("public") end end
  if btnHomeOpenPrivate then btnHomeOpenPrivate.onClick = function() switchTab("private") end end
  return view
end

-- --------------------------------------------------------------------
-- TAB 2: LOUNGE (COMMUNITY GROUPS) VIEW
-- --------------------------------------------------------------------
function createLoungeTabView()
  local viewLayout = {
    LinearLayout;
    orientation = "vertical";
    layout_width = "fill";
    layout_height = "fill";
    padding = "14dp";
    backgroundColor = "#F4F6F9";
    {
      LinearLayout;
      orientation = "horizontal";
      layout_width = "fill";
      gravity = "center_vertical";
      layout_marginBottom = "10dp";
      {
        TextView;
        text = "🚀 Community Lounge";
        textSize = "20sp";
        textColor = "#075E54";
        Typeface = Typeface.DEFAULT_BOLD;
        layout_weight = "1";
      };
      {
        Button;
        id = "btnRefreshGroups";
        text = "🔄 Refresh";
        textSize = "13sp";
        backgroundColor = "#128C7E";
        textColor = "#FFFFFF";
      };
      {
        Button;
        id = "btnCreateGroupModal";
        text = "➕ Create Group";
        textSize = "13sp";
        backgroundColor = "#075E54";
        textColor = "#FFFFFF";
        layout_marginLeft = "4dp";
      };
    };
    {
      EditText;
      id = "editSearchGroups";
      hint = "🔍 Search groups by name or topic...";
      layout_width = "fill";
      textSize = "15sp";
      padding = "10dp";
      backgroundColor = "#FFFFFF";
      layout_marginBottom = "8dp";
    };
    {
      ListView;
      id = "listLoungeGroups";
      layout_width = "fill";
      layout_weight = "1";
      dividerHeight = "4dp";
    };
  }
  
  local view = loadlayout(viewLayout)
  
  if btnRefreshGroups then
    btnRefreshGroups.onClick = function()
      announce("Refreshing community groups list...")
      fetchGroupsList()
    end
  end
  
  if btnCreateGroupModal then
    btnCreateGroupModal.onClick = function()
      showCreateGroupDialog()
    end
  end
  
  if editSearchGroups then
    editSearchGroups.addTextChangedListener({
      onTextChanged = function(s)
        groupSearchQuery = string.lower(tostring(s))
        updateLoungeGroupsUI()
      end
    })
  end
  
  return view
end

function showCreateGroupDialog()
  local dialogLayout = {
    LinearLayout;
    orientation = "vertical";
    layout_width = "fill";
    padding = "16dp";
    {
      TextView;
      text = "Group Name:";
      textSize = "14sp";
      textColor = "#222222";
    };
    {
      EditText;
      id = "editNewGroupName";
      hint = "e.g. Android Screen Readers";
      layout_width = "fill";
      textSize = "15sp";
      padding = "10dp";
      backgroundColor = "#EEEEEE";
      layout_marginBottom = "10dp";
    };
    {
      TextView;
      text = "Description / Topic:";
      textSize = "14sp";
      textColor = "#222222";
    };
    {
      EditText;
      id = "editNewGroupDesc";
      hint = "What is this group about?";
      layout_width = "fill";
      textSize = "15sp";
      padding = "10dp";
      backgroundColor = "#EEEEEE";
      layout_marginBottom = "10dp";
    };
    {
      CheckBox;
      id = "chkGroupPublic";
      text = "Public Group (Show in Lounge discovery)";
      checked = true;
      textSize = "14sp";
      textColor = "#075E54";
      layout_marginBottom = "6dp";
    };
    {
      CheckBox;
      id = "chkGroupApproval";
      text = "Require Admin Approval to Join";
      checked = false;
      textSize = "14sp";
      textColor = "#075E54";
    };
  }
  
  local dialogView = loadlayout(dialogLayout)
  local builder = AlertDialog.Builder(activity)
  builder.setTitle("Create Community Group")
  builder.setView(dialogView)
  builder.setPositiveButton("Create", DialogInterface.OnClickListener{
    onClick = function(d, w)
      local name = editNewGroupName.getText().toString()
      local desc = editNewGroupDesc.getText().toString()
      local isPublic = chkGroupPublic.isChecked()
      local requireApproval = chkGroupApproval.isChecked()
      
      if name == "" then
        announce("Group creation cancelled: Name cannot be empty.")
        return
      end
      
      local newGroupObj = {
        id = "grp_" .. os.time(),
        name = name,
        desc = desc,
        creator = currentUser.name,
        isPublic = isPublic,
        requireApproval = requireApproval,
        members = { currentUser.name },
        pending = {},
        created_at = os.time()
      }
      
      -- Insert locally immediately for zero-lag display
      table.insert(groupsList, 1, newGroupObj)
      updateLoungeGroupsUI()
      
      postFirebaseData("data/groups", newGroupObj, function() end)
      fetchGitHubFile("data/groups.json", function(ok, currentList)
        local list = currentList or {}
        table.insert(list, 1, newGroupObj)
        commitGitHubFile("data/groups.json", list, "Created group: " .. name, function()
          announce("Group \"" .. name .. "\" created and live!")
        end)
      end)
    end
  })
  builder.setNegativeButton("Cancel", nil)
  builder.show()
end

function fetchGroupsList()
  apiGet("/api/groups", "data/groups.json", function(success, data)
    if success and data and type(data) == "table" then
      local mergedGroups = {}
      local seenKeys = {}
      
      local function addGroupSafe(g)
        if type(g) == "table" then
          local key = string.lower(tostring(g.id or g.name or ""))
          if key ~= "" and not seenKeys[key] then
            seenKeys[key] = true
            table.insert(mergedGroups, g)
          end
        end
      end
      
      -- Add server groups
      for _, g in ipairs(data) do
        addGroupSafe(g)
      end
      
      -- Also preserve any locally created groups
      for _, g in ipairs(groupsList) do
        addGroupSafe(g)
      end
      
      groupsList = mergedGroups
      if activeTab == "lounge" then
        updateLoungeGroupsUI()
      end
    end
  end)
end

function updateLoungeGroupsUI()
  if not listLoungeGroups then return end
  
  local filtered = {}
  for _, g in ipairs(groupsList) do
    if type(g) == "table" then
      local name = g.name or ""
      local desc = g.desc or ""
      local isMember = false
      if type(g.members) == "table" then
        for _, m in ipairs(g.members) do
          if m == currentUser.name then isMember = true break end
        end
      end
      
      local matchesSearch = (groupSearchQuery == "") or (string.find(string.lower(name), groupSearchQuery, 1, true) ~= nil) or (string.find(string.lower(desc), groupSearchQuery, 1, true) ~= nil)
      local isAllowed = (g.isPublic == true) or isMember or (g.creator == currentUser.name) or (g.isPublic == nil)
      
      if isAllowed and matchesSearch then
        table.insert(filtered, g)
      end
    end
  end
  
  local itemLayout = {
    LinearLayout;
    orientation = "vertical";
    layout_width = "fill";
    padding = "14dp";
    backgroundColor = "#FFFFFF";
    {
      LinearLayout;
      orientation = "horizontal";
      layout_width = "fill";
      {
        TextView;
        id = "grpTitle";
        textSize = "16sp";
        textColor = "#075E54";
        Typeface = Typeface.DEFAULT_BOLD;
        layout_weight = "1";
      };
      {
        TextView;
        id = "grpBadge";
        textSize = "12sp";
        textColor = "#2E7D32";
      };
    };
    {
      TextView;
      id = "grpDesc";
      textSize = "14sp";
      textColor = "#555555";
      paddingTop = "4dp";
    };
  }
  
  local data = {}
  for _, g in ipairs(filtered) do
    local memberCount = (type(g.members) == "table") and #g.members or 1
    local badge = (g.creator == currentUser.name) and "👑 Admin (" .. memberCount .. " mem)" or ("👥 " .. memberCount .. " members")
    table.insert(data, {
      grpTitle = g.name or "Group",
      grpBadge = badge,
      grpDesc = (g.desc and g.desc ~= "") and g.desc or "Community Group"
    })
  end
  
  local adapter = LuaAdapter(activity, data, itemLayout)
  listLoungeGroups.setAdapter(adapter)
  
  listLoungeGroups.onItemClick = function(p, v, pos, id)
    local selected = filtered[pos + 1]
    if selected then
      openGroupChatScreen(selected)
    end
  end
end

-- --------------------------------------------------------------------
-- GROUP CHAT ROOM CONTROLLER
-- --------------------------------------------------------------------
function openGroupChatScreen(groupObj)
  activeGroup = groupObj
  activeTab = "group_chat"
  lastGroupMessageCount = 0
  lastRenderedGroupCount = -1
  
  local groupChatLayout = {
    LinearLayout;
    orientation = "vertical";
    layout_width = "fill";
    layout_height = "fill";
    padding = "12dp";
    backgroundColor = "#E5DDD5";
    {
      LinearLayout;
      orientation = "horizontal";
      layout_width = "fill";
      gravity = "center_vertical";
      padding = "10dp";
      backgroundColor = "#075E54";
      {
        Button;
        id = "btnBackToLounge";
        text = "< Lounge";
        textColor = "#FFFFFF";
        backgroundColor = "#075E54";
        ContentDescription = "Back to Lounge groups directory";
      };
      {
        TextView;
        id = "txtGroupChatHeader";
        text = groupObj.name or "Group Chat";
        textSize = "18sp";
        textColor = "#FFFFFF";
        Typeface = Typeface.DEFAULT_BOLD;
        layout_marginLeft = "8dp";
        layout_weight = "1";
      };
      {
        Button;
        id = "btnGroupSettings";
        text = "⚙️ Admin";
        textColor = "#FFFFFF";
        backgroundColor = "#00796B";
        visibility = (groupObj.creator == currentUser.name) and View.VISIBLE or View.GONE;
        ContentDescription = "Group Admin Settings";
      };
    };
    {
      ListView;
      id = "listGroupMessages";
      layout_width = "fill";
      layout_weight = "1";
      layout_marginTop = "8dp";
      layout_marginBottom = "8dp";
      divider = nil;
      dividerHeight = "0dp";
      stackFromBottom = true;
      transcriptMode = ListView.TRANSCRIPT_MODE_ALWAYS_SCROLL;
    };
    {
      LinearLayout;
      orientation = "horizontal";
      layout_width = "fill";
      gravity = "center_vertical";
      padding = "4dp";
      {
        EditText;
        id = "editGroupMessageInput";
        hint = "Message group...";
        layout_weight = "1";
        textSize = "16sp";
        padding = "12dp";
        backgroundColor = "#FFFFFF";
      };
      {
        Button;
        id = "btnSendGroupMessage";
        text = "Send";
        backgroundColor = "#075E54";
        textColor = "#FFFFFF";
        layout_marginLeft = "4dp";
      };
      {
        Button;
        id = "btnRecordGroupVoice";
        text = "🎙️ Voice";
        backgroundColor = "#075E54";
        textColor = "#FFFFFF";
        textSize = "14sp";
        layout_width = "75dp";
        layout_height = "50dp";
        layout_marginLeft = "6dp";
      };
    };
  }

  activity.setContentView(loadlayout(groupChatLayout))
  
  btnBackToLounge.onClick = function()
    activeGroup = nil
    showMainAppContainer()
    switchTab("lounge")
  end
  
  if btnGroupSettings then
    btnGroupSettings.onClick = function()
      showGroupAdminSettingsDialog(groupObj)
    end
  end
  
  setupHoldToRecordVoiceButton(btnRecordGroupVoice, false, groupObj.id, true)
  fetchGroupChatThread(groupObj.id)
  
  btnSendGroupMessage.onClick = function()
    local text = editGroupMessageInput.getText().toString()
    if text == "" then
      announce("Cannot send an empty group message.")
      return
    end
    
    local payload = {
      sender = currentUser.name,
      groupId = groupObj.id,
      text = text
    }
    
    editGroupMessageInput.setText("")
    announce("Posting group message: " .. text)
    
    apiPost("/api/group-messages", payload, function()
      fetchGroupChatThread(groupObj.id)
    end)
  end
end

function showGroupAdminSettingsDialog(groupObj)
  local options = {
    "👥 Add Online Members to Group",
    groupObj.isPublic and "🔒 Set Group to Unlisted (Private)" or "🌐 Set Group to Public",
    groupObj.requireApproval and "🔓 Disable Member Approval" or "🔐 Enable Member Approval",
    "🗑️ Delete Group"
  }
  
  local builder = AlertDialog.Builder(activity)
  builder.setTitle("Group Admin Settings: " .. (groupObj.name or "Group"))
  builder.setItems(options, DialogInterface.OnClickListener{
    onClick = function(d, w)
      if w == 0 then
        showAddMembersDialog(groupObj)
      elseif w == 1 then
        groupObj.isPublic = not groupObj.isPublic
        postFirebaseData("data/groups", groupObj, function() end)
        announce("Group visibility updated to " .. (groupObj.isPublic and "Public" or "Unlisted"))
      elseif w == 2 then
        groupObj.requireApproval = not groupObj.requireApproval
        postFirebaseData("data/groups", groupObj, function() end)
        announce("Join approval updated to " .. (groupObj.requireApproval and "Required" or "Open"))
      elseif w == 3 then
        postFirebaseData("data/groups/" .. groupObj.id, {}, function() end)
        announce("Group deleted.")
        showMainAppContainer()
        switchTab("lounge")
      end
    end
  })
  builder.show()
end

function showAddMembersDialog(groupObj)
  apiGet("/api/online-users?user=" .. currentUser.name, "data/online_users.json", function(success, data)
    local candidateUsers = {}
    local now_ts = os.time()
    local existingMembers = {}
    if type(groupObj.members) == "table" then
      for _, m in ipairs(groupObj.members) do
        existingMembers[tostring(m)] = true
      end
    end
    existingMembers[currentUser.name] = true
    
    if success and data and type(data) == "table" then
      for _, u in ipairs(data) do
        if type(u) == "table" then
          local uname = u.name or u.username
          local lastSeen = tonumber(u.last_seen or 0) or 0
          if uname and (now_ts - lastSeen <= 40) and not existingMembers[uname] then
            table.insert(candidateUsers, uname)
          end
        end
      end
    end
    
    if #candidateUsers == 0 then
      announce("No other online users available to add to this group right now.")
      return
    end
    
    local selectedMap = {}
    local namesArray = candidateUsers
    local checkedArray = {}
    for i = 1, #namesArray do
      table.insert(checkedArray, false)
    end
    
    local builder = AlertDialog.Builder(activity)
    builder.setTitle("Add Online Members to " .. (groupObj.name or "Group"))
    builder.setMultiChoiceItems(namesArray, checkedArray, DialogInterface.OnMultiChoiceClickListener{
      onClick = function(dialog, which, isChecked)
        local uName = namesArray[which + 1]
        selectedMap[uName] = isChecked
      end
    })
    
    builder.setPositiveButton("Add Selected", DialogInterface.OnClickListener{
      onClick = function(dialog, which)
        local addedCount = 0
        if type(groupObj.members) ~= "table" then groupObj.members = { currentUser.name } end
        
        for _, uName in ipairs(namesArray) do
          if selectedMap[uName] == true then
            table.insert(groupObj.members, uName)
            addedCount = addedCount + 1
          end
        end
        
        if addedCount > 0 then
          postFirebaseData("data/groups", groupObj, function() end)
          fetchGitHubFile("data/groups.json", function(ok, currentList)
            local list = currentList or {}
            for i, g in ipairs(list) do
              if g.id == groupObj.id or g.name == groupObj.name then
                list[i] = groupObj
                break
              end
            end
            commitGitHubFile("data/groups.json", list, "Added " .. addedCount .. " members to " .. groupObj.name, function() end)
          end)
          announce("Successfully added " .. addedCount .. " member(s) to " .. (groupObj.name or "Group") .. "!")
        else
          announce("No members selected.")
        end
      end
    })
    builder.setNegativeButton("Cancel", nil)
    builder.show()
  end)
end

function fetchGroupChatThread(groupId)
  local chatPath = getGroupChatFilePath(groupId)
  local endpoint = "/api/group-messages?group=" .. groupId
  
  apiGet(endpoint, chatPath, function(success, data)
    if success and data and type(data) == "table" then
      local sorted = deduplicateAndSortMessages(data)
      local newCount = #sorted
      if newCount > lastGroupMessageCount and lastGroupMessageCount > 0 then
        local latest = sorted[newCount]
        if latest and type(latest) == "table" and latest.sender ~= currentUser.name then
          announce("New message in " .. (activeGroup and activeGroup.name or "group") .. " from " .. (latest.sender or "User") .. ": " .. (latest.text or ""))
        end
      end
      lastGroupMessageCount = newCount
      groupChatHistory[groupId] = sorted
      
      if activeTab == "group_chat" and activeGroup and activeGroup.id == groupId and lastRenderedGroupCount ~= newCount then
        lastRenderedGroupCount = newCount
        updateGroupChatUI(groupId)
      end
    end
  end)
end

function updateGroupChatUI(groupId)
  if not listGroupMessages then return end
  
  local chatItemLayout = {
    LinearLayout;
    orientation = "vertical";
    layout_width = "fill";
    padding = "12dp";
    backgroundColor = "#FFFFFF";
    {
      LinearLayout;
      orientation = "horizontal";
      layout_width = "fill";
      {
        TextView;
        id = "msgSender";
        textSize = "14sp";
        textColor = "#075E54";
        Typeface = Typeface.DEFAULT_BOLD;
        layout_weight = "1";
      };
      {
        TextView;
        id = "msgTime";
        textSize = "11sp";
        textColor = "#888888";
      };
    };
    {
      TextView;
      id = "msgText";
      textSize = "16sp";
      textColor = "#111111";
      paddingTop = "4dp";
    };
  }
  
  local data = {}
  local msgs = groupChatHistory[groupId] or {}
  for _, m in ipairs(msgs) do
    if type(m) == "table" then
      local textStr = m.text or ""
      if m.reaction and m.reaction ~= "" then
        textStr = textStr .. " [" .. m.reaction .. "]"
      end
      table.insert(data, {
        msgSender = m.sender or "User",
        msgTime = m.time or "",
        msgText = textStr
      })
    end
  end
  
  local adapter = LuaAdapter(activity, data, chatItemLayout)
  listGroupMessages.setAdapter(adapter)
  
  listGroupMessages.onItemClick = function(parent, view, position, id)
    local idx = position + 1
    local selectedMsg = msgs[idx]
    if selectedMsg then
      if selectedMsg.isVoice or selectedMsg.audio or selectedMsg.voicePath then
        downloadAndPlayVoiceNote(selectedMsg)
      else
        announce((selectedMsg.sender or "User") .. ": " .. (selectedMsg.text or ""))
      end
    end
  end
  
  listGroupMessages.onItemLongClick = function(parent, view, position, id)
    local idx = position + 1
    local selectedMsg = msgs[idx]
    if selectedMsg then
      showMessageOptionsDialog(selectedMsg, idx, false, groupId, true)
    end
    return true
  end
end

-- --------------------------------------------------------------------
-- TAB 3: PUBLIC LOBBY VIEW
-- --------------------------------------------------------------------
function createPublicTabView()
  lastRenderedPublicCount = -1
  local viewLayout = {
    LinearLayout;
    orientation = "vertical";
    layout_width = "fill";
    layout_height = "fill";
    padding = "12dp";
    backgroundColor = "#E5DDD5";
    {
      LinearLayout;
      orientation = "horizontal";
      layout_width = "fill";
      gravity = "center_vertical";
      padding = "8dp";
      backgroundColor = "#075E54";
      {
        TextView;
        text = "🌐 Global Public Lobby";
        textSize = "18sp";
        textColor = "#FFFFFF";
        Typeface = Typeface.DEFAULT_BOLD;
        layout_weight = "1";
      };
      {
        Button;
        id = "btnSavePublicChatLocal";
        text = "📥 Save";
        textColor = "#FFFFFF";
        backgroundColor = "#128C7E";
      };
    };
    {
      ListView;
      id = "listPublicMessages";
      layout_width = "fill";
      layout_weight = "1";
      layout_marginTop = "8dp";
      layout_marginBottom = "8dp";
      divider = nil;
      dividerHeight = "0dp";
      stackFromBottom = true;
      transcriptMode = ListView.TRANSCRIPT_MODE_ALWAYS_SCROLL;
    };
    {
      LinearLayout;
      orientation = "horizontal";
      layout_width = "fill";
      gravity = "center_vertical";
      padding = "4dp";
      {
        EditText;
        id = "editPublicMessageInput";
        hint = "Type message...";
        layout_weight = "1";
        textSize = "16sp";
        padding = "12dp";
        backgroundColor = "#FFFFFF";
      };
      {
        Button;
        id = "btnSendPublicMessage";
        text = "Post";
        backgroundColor = "#075E54";
        textColor = "#FFFFFF";
        layout_marginLeft = "4dp";
      };
      {
        Button;
        id = "btnRecordPublicVoice";
        text = "🎙️ Voice";
        backgroundColor = "#075E54";
        textColor = "#FFFFFF";
        textSize = "14sp";
        layout_width = "75dp";
        layout_height = "50dp";
        layout_marginLeft = "6dp";
      };
    };
  }
  
  local view = loadlayout(viewLayout)
  
  if btnSavePublicChatLocal then
    btnSavePublicChatLocal.onClick = function()
      saveChatLocally("PublicFeed", "Global", publicFeedMessages)
    end
  end
  
  if btnRecordPublicVoice then
    setupHoldToRecordVoiceButton(btnRecordPublicVoice, true, "")
  end
  
  if btnSendPublicMessage then
    btnSendPublicMessage.onClick = function()
      local text = editPublicMessageInput.getText().toString()
      if text == "" then
        announce("Cannot post an empty public message.")
        return
      end
      
      local payload = {
        sender = currentUser.name,
        text = text
      }
      
      editPublicMessageInput.setText("")
      announce("Posting public message: " .. text)
      
      apiPost("/api/public-feed", payload, function()
        fetchPublicFeedMessages()
      end)
    end
  end
  
  return view
end

function fetchPublicFeedMessages()
  apiGet("/api/public-feed", "data/public_feed.json", function(success, data)
    if success and data and type(data) == "table" then
      local sorted = deduplicateAndSortMessages(data)
      local newCount = #sorted
      if newCount > lastPublicMessageCount and lastPublicMessageCount > 0 then
        local latest = sorted[newCount]
        if latest and type(latest) == "table" and latest.sender ~= currentUser.name then
          announce("New public message from " .. (latest.sender or "User") .. ": " .. (latest.text or ""))
        end
      end
      lastPublicMessageCount = newCount
      publicFeedMessages = sorted
      
      if activeTab == "public" and lastRenderedPublicCount ~= newCount then
        lastRenderedPublicCount = newCount
        updatePublicFeedUI()
      end
    end
  end)
end

function updatePublicFeedUI()
  if not listPublicMessages then return end
  
  local chatItemLayout = {
    LinearLayout;
    orientation = "vertical";
    layout_width = "fill";
    padding = "12dp";
    backgroundColor = "#FFFFFF";
    {
      LinearLayout;
      orientation = "horizontal";
      layout_width = "fill";
      {
        TextView;
        id = "msgSender";
        textSize = "14sp";
        textColor = "#075E54";
        Typeface = Typeface.DEFAULT_BOLD;
        layout_weight = "1";
      };
      {
        TextView;
        id = "msgTime";
        textSize = "11sp";
        textColor = "#888888";
      };
    };
    {
      TextView;
      id = "msgText";
      textSize = "16sp";
      textColor = "#111111";
      paddingTop = "4dp";
    };
  }
  
  local data = {}
  for _, m in ipairs(publicFeedMessages) do
    if type(m) == "table" then
      local textStr = m.text or ""
      if m.reaction and m.reaction ~= "" then
        textStr = textStr .. " [" .. m.reaction .. "]"
      end
      table.insert(data, {
        msgSender = m.sender or "Anonymous",
        msgTime = m.time or "",
        msgText = textStr
      })
    end
  end
  
  local adapter = LuaAdapter(activity, data, chatItemLayout)
  listPublicMessages.setAdapter(adapter)
  
  listPublicMessages.onItemClick = function(parent, view, position, id)
    local idx = position + 1
    local selectedMsg = publicFeedMessages[idx]
    if selectedMsg then
      if selectedMsg.isVoice or selectedMsg.audio or selectedMsg.voicePath then
        downloadAndPlayVoiceNote(selectedMsg)
      else
        announce((selectedMsg.sender or "User") .. ": " .. (selectedMsg.text or ""))
      end
    end
  end
  
  listPublicMessages.onItemLongClick = function(parent, view, position, id)
    local idx = position + 1
    local selectedMsg = publicFeedMessages[idx]
    if selectedMsg then
      showMessageOptionsDialog(selectedMsg, idx, true, "")
    end
    return true
  end
end

-- --------------------------------------------------------------------
-- TAB 4: PRIVATE LOBBY VIEW (ACCESSIBLE VERTICAL LISTVIEW)
-- --------------------------------------------------------------------
function createPrivateTabView()
  lastRenderedUsersSignature = ""
  local viewLayout = {
    LinearLayout;
    orientation = "vertical";
    layout_width = "fill";
    layout_height = "fill";
    padding = "14dp";
    backgroundColor = "#F4F6F9";
    {
      LinearLayout;
      orientation = "horizontal";
      layout_width = "fill";
      gravity = "center_vertical";
      layout_marginBottom = "10dp";
      {
        TextView;
        text = "💬 Active Online Users";
        textSize = "18sp";
        textColor = "#075E54";
        Typeface = Typeface.DEFAULT_BOLD;
        layout_weight = "1";
      };
      {
        Button;
        id = "btnRefreshUsers";
        text = "🔄 Refresh";
        textSize = "13sp";
        backgroundColor = "#075E54";
        textColor = "#FFFFFF";
      };
    };
    {
      ListView;
      id = "listOnlineUsers";
      layout_width = "fill";
      layout_height = "fill";
      dividerHeight = "4dp";
    };
  }
  
  local view = loadlayout(viewLayout)
  
  if btnRefreshUsers then
    btnRefreshUsers.onClick = function()
      announce("Refreshing active online users...")
      lastRenderedUsersSignature = ""
      fetchOnlineUsersList()
    end
  end
  
  return view
end

function fetchOnlineUsersList()
  apiGet("/api/online-users?user=" .. currentUser.name, "data/online_users.json", function(success, data)
    if success and data and type(data) == "table" then
      local filtered = {}
      local seenMap = {}
      local now_ts = os.time()
      
      for _, u in ipairs(data) do
        if type(u) == "table" then
          local name = u.name or u.username
          local lastSeen = tonumber(u.last_seen or 0) or 0
          local isOnline = (now_ts - lastSeen <= 40) and (u.status == "Online" or u.online == true)
          
          if name and name ~= currentUser.name and isOnline and not seenMap[name] then
            seenMap[name] = true
            table.insert(filtered, {
              name = name,
              status = "Online"
            })
          end
        end
      end
      
      onlineUsersList = filtered
      if activeTab == "private" then
        updatePrivateDirectoryUI()
      end
    end
  end)
end

function updatePrivateDirectoryUI()
  if not listOnlineUsers then return end
  
  local currentSig = ""
  for _, u in ipairs(onlineUsersList) do
    currentSig = currentSig .. ";" .. (u.name or "")
  end
  if currentSig == lastRenderedUsersSignature and #onlineUsersList > 0 then
    return
  end
  lastRenderedUsersSignature = currentSig
  
  local itemLayout = {
    LinearLayout;
    orientation = "vertical";
    layout_width = "fill";
    padding = "14dp";
    backgroundColor = "#FFFFFF";
    {
      LinearLayout;
      orientation = "horizontal";
      layout_width = "fill";
      gravity = "center_vertical";
      {
        TextView;
        id = "itemName";
        textSize = "17sp";
        textColor = "#075E54";
        Typeface = Typeface.DEFAULT_BOLD;
        layout_weight = "1";
      };
      {
        TextView;
        id = "itemStatus";
        textSize = "13sp";
        textColor = "#2E7D32";
        Typeface = Typeface.DEFAULT_BOLD;
      };
    };
    {
      TextView;
      text = "Tap to open private 1-on-1 chat room";
      textSize = "12sp";
      textColor = "#777777";
      paddingTop = "4dp";
    };
  }
  
  local data = {}
  for _, u in ipairs(onlineUsersList) do
    if type(u) == "table" then
      table.insert(data, { 
        itemName = u.name or "User", 
        itemStatus = "● Active Now"
      })
    end
  end
  
  local adapter = LuaAdapter(activity, data, itemLayout)
  listOnlineUsers.setAdapter(adapter)
  
  listOnlineUsers.onItemClick = function(parent, view, position, id)
    local selectedUser = onlineUsersList[position + 1].name
    announce("Opening private chat with " .. selectedUser)
    openPrivateChatScreen(selectedUser)
  end
end

function openPrivateChatScreen(targetUsername)
  activeTab = "private_chat"
  activeChatTarget = targetUsername
  lastPrivateMessageCount = 0
  lastRenderedPrivateCount = -1
  
  local chatLayout = {
    LinearLayout;
    orientation = "vertical";
    layout_width = "fill";
    layout_height = "fill";
    padding = "12dp";
    backgroundColor = "#E5DDD5";
    {
      LinearLayout;
      orientation = "horizontal";
      layout_width = "fill";
      gravity = "center_vertical";
      padding = "10dp";
      backgroundColor = "#075E54";
      {
        Button;
        id = "btnBackToPrivateList";
        text = "< Users";
        textColor = "#FFFFFF";
        backgroundColor = "#075E54";
      };
      {
        TextView;
        id = "txtChatTargetHeader";
        text = "Chat: " .. targetUsername;
        textSize = "18sp";
        textColor = "#FFFFFF";
        Typeface = Typeface.DEFAULT_BOLD;
        layout_marginLeft = "8dp";
        layout_weight = "1";
      };
      {
        Button;
        id = "btnSavePrivateChatLocal";
        text = "📥 Save";
        textColor = "#FFFFFF";
        backgroundColor = "#128C7E";
      };
    };
    {
      ListView;
      id = "listChatMessages";
      layout_width = "fill";
      layout_weight = "1";
      layout_marginTop = "8dp";
      layout_marginBottom = "8dp";
      divider = nil;
      dividerHeight = "0dp";
      stackFromBottom = true;
      transcriptMode = ListView.TRANSCRIPT_MODE_ALWAYS_SCROLL;
    };
    {
      LinearLayout;
      orientation = "horizontal";
      layout_width = "fill";
      gravity = "center_vertical";
      padding = "4dp";
      {
        EditText;
        id = "editMessageInput";
        hint = "Type message...";
        layout_weight = "1";
        textSize = "16sp";
        padding = "12dp";
        backgroundColor = "#FFFFFF";
      };
      {
        Button;
        id = "btnSendMessage";
        text = "Send";
        backgroundColor = "#075E54";
        textColor = "#FFFFFF";
        layout_marginLeft = "4dp";
      };
      {
        Button;
        id = "btnRecordPrivateVoice";
        text = "🎙️ Voice";
        backgroundColor = "#075E54";
        textColor = "#FFFFFF";
        textSize = "14sp";
        layout_width = "75dp";
        layout_height = "50dp";
        layout_marginLeft = "6dp";
      };
    };
  }

  activity.setContentView(loadlayout(chatLayout))
  
  btnSavePrivateChatLocal.onClick = function()
    local msgs = privateChatHistory[targetUsername] or {}
    saveChatLocally("PrivateChat", targetUsername, msgs)
  end
  
  setupHoldToRecordVoiceButton(btnRecordPrivateVoice, false, targetUsername)
  fetchPrivateChatThread(targetUsername)
  
  btnSendMessage.onClick = function()
    local text = editMessageInput.getText().toString()
    if text == "" then
      announce("Cannot send empty message.")
      return
    end
    
    local payload = {
      sender = currentUser.name,
      recipient = targetUsername,
      text = text
    }
    
    editMessageInput.setText("")
    announce("Sending private message: " .. text)
    
    apiPost("/api/private-messages", payload, function()
      fetchPrivateChatThread(targetUsername)
    end)
  end
  
  btnBackToPrivateList.onClick = function()
    local chatPath = getChatFilePath(currentUser.name, targetUsername)
    purgeCloudFeed(chatPath)
    purgeEphemeralAudioFiles()
    privateChatHistory[targetUsername] = nil
    activeChatTarget = ""
    showMainAppContainer()
    switchTab("private")
  end
end

function fetchPrivateChatThread(targetUsername)
  local chatPath = getChatFilePath(currentUser.name, targetUsername)
  local endpoint = "/api/private-messages?user=" .. currentUser.name .. "&target=" .. targetUsername
  
  apiGet(endpoint, chatPath, function(success, data)
    if success and data and type(data) == "table" then
      local sorted = deduplicateAndSortMessages(data)
      local newCount = #sorted
      if newCount > lastPrivateMessageCount and lastPrivateMessageCount > 0 then
        local latest = sorted[newCount]
        if latest and type(latest) == "table" and latest.sender == targetUsername then
          announce("New private message from " .. targetUsername .. ": " .. (latest.text or ""))
        end
      end
      lastPrivateMessageCount = newCount
      privateChatHistory[targetUsername] = sorted
      
      if activeTab == "private_chat" and activeChatTarget == targetUsername and lastRenderedPrivateCount ~= newCount then
        lastRenderedPrivateCount = newCount
        updatePrivateChatUI(targetUsername)
      end
    end
  end)
end

function updatePrivateChatUI(targetUsername)
  if not listChatMessages then return end
  
  local chatItemLayout = {
    LinearLayout;
    orientation = "vertical";
    layout_width = "fill";
    padding = "12dp";
    backgroundColor = "#FFFFFF";
    {
      LinearLayout;
      orientation = "horizontal";
      layout_width = "fill";
      {
        TextView;
        id = "msgSender";
        textSize = "14sp";
        textColor = "#075E54";
        Typeface = Typeface.DEFAULT_BOLD;
        layout_weight = "1";
      };
      {
        TextView;
        id = "msgTime";
        textSize = "11sp";
        textColor = "#888888";
      };
    };
    {
      TextView;
      id = "msgText";
      textSize = "16sp";
      textColor = "#111111";
      paddingTop = "4dp";
    };
  }
  
  local data = {}
  local msgs = privateChatHistory[targetUsername] or {}
  for _, m in ipairs(msgs) do
    if type(m) == "table" then
      local senderLabel = (m.sender == currentUser.name) and "Me" or (m.sender or targetUsername)
      local textStr = m.text or ""
      if m.reaction and m.reaction ~= "" then
        textStr = textStr .. " [" .. m.reaction .. "]"
      end
      table.insert(data, {
        msgSender = senderLabel,
        msgTime = m.time or "",
        msgText = textStr
      })
    end
  end
  
  local adapter = LuaAdapter(activity, data, chatItemLayout)
  listChatMessages.setAdapter(adapter)
  
  listChatMessages.onItemClick = function(parent, view, position, id)
    local idx = position + 1
    local selectedMsg = msgs[idx]
    if selectedMsg then
      if selectedMsg.isVoice or selectedMsg.audio or selectedMsg.voicePath then
        downloadAndPlayVoiceNote(selectedMsg)
      else
        announce((selectedMsg.sender or "User") .. ": " .. (selectedMsg.text or ""))
      end
    end
  end
  
  listChatMessages.onItemLongClick = function(parent, view, position, id)
    local idx = position + 1
    local selectedMsg = msgs[idx]
    if selectedMsg then
      showMessageOptionsDialog(selectedMsg, idx, false, targetUsername)
    end
    return true
  end
end

-- --------------------------------------------------------------------
-- TAB 5: YOU / ME (PROFILE & APP SETTINGS) VIEW
-- --------------------------------------------------------------------
function createYouTabView()
  local viewLayout = {
    ScrollView;
    layout_width = "fill";
    layout_height = "fill";
    padding = "16dp";
    backgroundColor = "#F4F6F9";
    {
      LinearLayout;
      orientation = "vertical";
      layout_width = "fill";
      layout_height = "wrap";
      {
        TextView;
        text = "👤 Your Profile & Settings";
        textSize = "22sp";
        textColor = "#075E54";
        Typeface = Typeface.DEFAULT_BOLD;
        layout_marginBottom = "14dp";
      };
      {
        LinearLayout;
        orientation = "vertical";
        layout_width = "fill";
        padding = "16dp";
        backgroundColor = "#FFFFFF";
        layout_marginBottom = "14dp";
        elevation = "2dp";
        {
          TextView;
          text = "Profile Management";
          textSize = "16sp";
          textColor = "#075E54";
          Typeface = Typeface.DEFAULT_BOLD;
          layout_marginBottom = "8dp";
        };
        {
          TextView;
          text = "Username: " .. currentUser.name;
          textSize = "15sp";
          textColor = "#222222";
          Typeface = Typeface.DEFAULT_BOLD;
          layout_marginBottom = "6dp";
        };
        {
          TextView;
          text = "Custom Bio / Status:";
          textSize = "13sp";
          textColor = "#666666";
        };
        {
          EditText;
          id = "editUserBio";
          hint = "Set your bio / status...";
          layout_width = "fill";
          textSize = "15sp";
          padding = "10dp";
          backgroundColor = "#EEEEEE";
          text = currentUser.bio or "";
          layout_marginBottom = "10dp";
        };
        {
          Button;
          id = "btnSaveBio";
          text = "💾 Save Bio & Profile";
          layout_width = "fill";
          layout_height = "45dp";
          backgroundColor = "#00796B";
          textColor = "#FFFFFF";
        };
      };
      {
        LinearLayout;
        orientation = "vertical";
        layout_width = "fill";
        padding = "16dp";
        backgroundColor = "#FFFFFF";
        layout_marginBottom = "14dp";
        elevation = "2dp";
        {
          TextView;
          text = "Storage & App Maintenance";
          textSize = "16sp";
          textColor = "#075E54";
          Typeface = Typeface.DEFAULT_BOLD;
          layout_marginBottom = "8dp";
        };
        {
          Button;
          id = "btnClearVoiceCache";
          text = "🗑️ Clean Cached Voice Notes";
          layout_width = "fill";
          layout_height = "48dp";
          backgroundColor = "#607D8B";
          textColor = "#FFFFFF";
          layout_marginBottom = "10dp";
        };
        {
          Button;
          id = "btnCheckAppUpdate";
          text = "🔄 Check for Updates (v" .. APP_VERSION .. ")";
          layout_width = "fill";
          layout_height = "48dp";
          backgroundColor = "#455A64";
          textColor = "#FFFFFF";
          layout_marginBottom = "10dp";
        };
        {
          Button;
          id = "btnLogoutAndForget";
          text = "🚪 Disconnect / Remove Saved Account";
          layout_width = "fill";
          layout_height = "48dp";
          backgroundColor = "#D32F2F";
          textColor = "#FFFFFF";
        };
      };
    };
  }
  
  local view = loadlayout(viewLayout)
  
  if btnSaveBio then
    btnSaveBio.onClick = function()
      local bioText = editUserBio.getText().toString()
      currentUser.bio = bioText
      announce("Profile bio updated successfully!")
    end
  end
  
  if btnClearVoiceCache then
    btnClearVoiceCache.onClick = function()
      purgeEphemeralAudioFiles()
      announce("Temporary cached voice notes cleared from storage.")
    end
  end
  
  if btnCheckAppUpdate then
    btnCheckAppUpdate.onClick = function()
      checkForRemoteUpdates(true)
    end
  end
  
  if btnLogoutAndForget then
    btnLogoutAndForget.onClick = function()
      purgeEphemeralAudioFiles()
      clearSavedCredentials()
      currentUser.name = ""
      currentUser.online = false
      isPolling = false
      publicFeedMessages = {}
      privateChatHistory = {}
      groupChatHistory = {}
      announce("Disconnected and saved account removed from this device.")
      showLoginScreen()
    end
  end
  
  return view
end

-- --------------------------------------------------------------------
-- BACKGROUND POLLING LOOP
-- --------------------------------------------------------------------
function updateOnlinePresence()
  apiPost("/api/heartbeat", { username = currentUser.name }, function() end)
end

function startPollingLoop()
  if isPolling then return end
  isPolling = true
  
  local function poll()
    if not currentUser.online or not isPolling then return end
    
    updateOnlinePresence()
    
    if activeTab == "public" then
      fetchPublicFeedMessages()
    elseif activeTab == "lounge" then
      fetchGroupsList()
    elseif activeTab == "group_chat" and activeGroup then
      fetchGroupChatThread(activeGroup.id)
    elseif activeTab == "private" then
      fetchOnlineUsersList()
    elseif activeTab == "private_chat" and activeChatTarget ~= "" then
      fetchPrivateChatThread(activeChatTarget)
    end
    
    Handler().postDelayed(Runnable{ run = poll }, 4000)
  end
  
  poll()
end

-- --------------------------------------------------------------------
-- INITIAL ENTRY POINT
-- --------------------------------------------------------------------
showLoginScreen()