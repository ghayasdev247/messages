-- ====================================================================
-- ACCESSIBLE ANONYMOUS MESSENGER FOR JIESHUO / COMMENTARY SCREEN READER
-- Developed in AndroLua+
-- Version: 2.5.0 (Build Code: 35)
-- Features: Group Join Requests, Direct Public Join, Admin Approval Inbox,
--           Live Interactive Updates, Global Group Controls & 5-Tab Bar
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
local APP_VERSION = "3.2.0"
local APP_VERSION_CODE = 45

local VERSION_MANIFEST_URL = "https://raw.githubusercontent.com/ghayasdev247/messages/main/data/version.json"
local LUA_UPDATE_URL = "https://raw.githubusercontent.com/ghayasdev247/messages/main/main.lua"
local XPK_UPDATE_URL = "https://raw.githubusercontent.com/ghayasdev247/messages/main/Chatify%20Accessible%20Messenger%20for%20the%20Blind_Updated.xpk"

-- Primary Live Firebase Realtime Database Endpoint
local FIREBASE_URL = "https://messages-server-f2a99-default-rtdb.asia-southeast1.firebasedatabase.app"

-- Active 24/7 Global Cloudflare Serverless Backend
local BACKEND_URL = "https://messages.vistudio247.workers.dev"

local GITHUB_OWNER = "ghayasdev247"
local GITHUB_REPO = "messages"
local GITHUB_BRANCH = "main"

local currentUser = { name = "", online = false, githubToken = "", bio = "Accessible Messenger User" }
local activeTab = "home" -- "home", "lounge", "public", "private", "you"
local activeChatTarget = ""
local activeGroup = nil
local isPolling = false

local mutedGroups = {} -- groupId -> boolean

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
  local u1_lower = string.lower(u1:gsub("^%s+", ""):gsub("%s+$", ""))
  local u2_lower = string.lower(u2:gsub("^%s+", ""):gsub("%s+$", ""))
  if u1_lower < u2_lower then
    return "data/chats/" .. u1_lower .. "_" .. u2_lower .. ".json"
  else
    return "data/chats/" .. u2_lower .. "_" .. u1_lower .. ".json"
  end
end

function getGroupChatFilePath(groupId)
  return "data/groups/" .. groupId .. "_messages.json"
end

-- --------------------------------------------------------------------
-- BULLETPROOF JSON ENGINE (NATIVE ANDROID ORG.JSON + CJSON + PURE-LUA)
-- --------------------------------------------------------------------
local jsonModule = nil
pcall(function() jsonModule = require("cjson") end)

function decodeJSON(str)
  if not str or str == "" or str == "null" then return nil end
  
  -- 1. Native Android org.json (100% reliable, zero syntax errors on multiline/quotes)
  local ok, res = pcall(function()
    import "org.json.JSONTokener"
    import "org.json.JSONObject"
    import "org.json.JSONArray"
    
    local tokener = JSONTokener(str)
    local javaVal = tokener.nextValue()
    
    local function parseJavaJSON(val)
      if val == nil or val == JSONObject.NULL then
        return nil
      elseif luajava.instanceof(val, JSONObject) then
        local t = {}
        local keys = val.keys()
        while keys.hasNext() do
          local k = tostring(keys.next())
          t[k] = parseJavaJSON(val.get(k))
        end
        return t
      elseif luajava.instanceof(val, JSONArray) then
        local t = {}
        local len = val.length()
        for i = 0, len - 1 do
          table.insert(t, parseJavaJSON(val.get(i)))
        end
        return t
      else
        return val
      end
    end
    
    return parseJavaJSON(javaVal)
  end)
  if ok and res ~= nil then return res end

  -- 2. cjson module if available
  if jsonModule and jsonModule.decode then
    local cOk, cRes = pcall(jsonModule.decode, str)
    if cOk and cRes ~= nil then return cRes end
  end

  return nil
end

function encodeJSON(val)
  if val == nil then return "null" end
  if jsonModule and jsonModule.encode then
    local ok, res = pcall(jsonModule.encode, val)
    if ok and res then return res end
  end
  
  local function serialize(v)
    local t = type(v)
    if t == "nil" then
      return "null"
    elseif t == "boolean" then
      return v and "true" or "false"
    elseif t == "number" then
      return tostring(v)
    elseif t == "string" then
      local s = v:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
      return '"' .. s .. '"'
    elseif t == "table" then
      local isArray = true
      local count = 0
      for k, _ in pairs(v) do
        count = count + 1
        if type(k) ~= "number" or k ~= count then
          isArray = false
          break
        end
      end
      if isArray then
        local items = {}
        for _, item in ipairs(v) do
          table.insert(items, serialize(item))
        end
        return "[" .. table.concat(items, ",") .. "]"
      else
        local items = {}
        for k, item in pairs(v) do
          local kStr = '"' .. tostring(k):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
          table.insert(items, kStr .. ":" .. serialize(item))
        end
        return "{" .. table.concat(items, ",") .. "}"
      end
    else
      return '"' .. tostring(v) .. '"'
    end
  end
  
  return serialize(val)
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
-- MESSAGE TEXT SANITIZER & DEDUPLICATION ENGINE
-- --------------------------------------------------------------------
function cleanMessageText(text, isVoice)
  if isVoice or (text and string.find(text, "Voice")) then
    return "[Voice Note] - Tap to play"
  end
  if not text or text == "" then return "" end
  
  local clean = text:gsub("馃帳", ""):gsub("馃懇", ""):gsub("馃", ""):gsub("[\128-\255]+Voice", "Voice")
  if clean == "" or string.find(clean, "Voice Message") or string.find(clean, "Voice Note") then
    return "[Voice Note] - Tap to play"
  end
  return clean
end

function deduplicateAndSortMessages(msgList)
  if type(msgList) ~= "table" then return {} end
  local cleanList = {}
  local seenSignatures = {}
  
  for _, m in ipairs(msgList) do
    if type(m) == "table" then
      local sender = string.lower(tostring(m.sender or "")):gsub("^%s+", ""):gsub("%s+$", "")
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
        local text = cleanMessageText(m.text, (m.isVoice == true) or (m.audio and m.audio ~= ""))
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
-- AUTO UPDATE ENGINE WITH LIVE PROGRESS
-- --------------------------------------------------------------------
function checkForRemoteUpdates(manualCheck)
  if manualCheck then
    announce("Checking for updates...")
  end
  
  local checkUrl = VERSION_MANIFEST_URL .. "?t=" .. os.time()
  Http.get(checkUrl, function(code, content)
    if code == 200 then
      local manifest = decodeJSON(content)
      if manifest and manifest.version_code and (tonumber(manifest.version_code) or 1) > APP_VERSION_CODE then
        showUpdateAvailableDialog(manifest)
        return
      end
    end
    
    Http.get(BACKEND_URL .. "/api/version", function(lCode, lContent)
      if lCode == 200 then
        local manifest = decodeJSON(lContent)
        if manifest and manifest.version_code and (tonumber(manifest.version_code) or 1) > APP_VERSION_CODE then
          showUpdateAvailableDialog(manifest)
          return
        end
      end
      
      if manualCheck then
        announce("You are using the latest version of Accessible Messenger (v" .. APP_VERSION .. ").")
      end
    end)
  end)
end

function showUpdateAvailableDialog(manifest)
  local newVer = manifest.version or tostring(manifest.version_code)
  local changelog = manifest.changelog or "Bug fixes and performance improvements."
  local downloadUrl = manifest.download_url or LUA_UPDATE_URL
  
  local builder = AlertDialog.Builder(activity)
  builder.setTitle("⚡ Update Available: Version " .. newVer)
  builder.setMessage("A new update is available!\n\nChangelog:\n" .. changelog .. "\n\nDo you want to update now?")
  builder.setPositiveButton("Update Now (Yes)", DialogInterface.OnClickListener{
    onClick = function(dialog, which)
      showDownloadProgressScreen(newVer, downloadUrl)
    end
  })
  builder.setNegativeButton("Later (No)", DialogInterface.OnClickListener{
    onClick = function(dialog, which)
      announce("Update postponed.")
      if activeTab == "splash" then
        proceedAfterSplash()
      end
    end
  })
  builder.setCancelable(false)
  builder.show()
  announce("Update available for Version " .. newVer .. ". Tap Update Now to proceed.")
end

function showDownloadProgressScreen(versionStr, downloadUrl)
  local downloadLayout = {
    LinearLayout;
    orientation = "vertical";
    layout_width = "fill";
    layout_height = "fill";
    gravity = "center";
    padding = "24dp";
    backgroundColor = "#F4F6F9";
    {
      TextView;
      text = "⬇️ Updating Accessible Messenger";
      textSize = "22sp";
      textColor = "#075E54";
      Typeface = Typeface.DEFAULT_BOLD;
      gravity = "center";
    };
    {
      TextView;
      id = "txtDownloadStatus";
      text = "Downloading update v" .. versionStr .. " in background...\nPlease wait.";
      textSize = "15sp";
      textColor = "#555555";
      gravity = "center";
      layout_marginTop = "14dp";
      layout_marginBottom = "24dp";
    };
    {
      ProgressBar;
      id = "downloadProgressBar";
      layout_width = "fill";
      layout_height = "wrap";
      indeterminate = true;
    };
    {
      Button;
      id = "btnContinueAfterUpdate";
      text = "Continue to Messenger";
      layout_width = "fill";
      layout_height = "48dp";
      layout_marginTop = "24dp";
      backgroundColor = "#075E54";
      textColor = "#FFFFFF";
      visibility = View.GONE;
    };
  }

  activity.setContentView(loadlayout(downloadLayout))
  announce("Downloading update Version " .. versionStr .. " in background. Please wait...")

  Http.get(downloadUrl .. "?t=" .. os.time(), function(uCode, uContent)
    if uCode == 200 and uContent and uContent ~= "" then
      saveUpdateFile(versionStr, uContent)
      if txtDownloadStatus then
        txtDownloadStatus.setText("✅ Update Finished!\nVersion " .. versionStr .. " updated directly in Jieshuo plugin.\nPlease restart the tool to apply the new update.")
      end
      if btnContinueAfterUpdate then
        btnContinueAfterUpdate.setVisibility(View.VISIBLE)
        btnContinueAfterUpdate.onClick = function()
          proceedAfterSplash()
        end
      end
      announce("Update Finished! Version " .. versionStr .. " saved to plugin directory. Please restart tool.")
    else
      announce("Update download failed. Continuing to messenger.")
      proceedAfterSplash()
    end
  end)
end

function saveUpdateFile(versionStr, uContent)
  local targetPaths = {}
  local seen = {}

  local function addPath(p)
    if p and p ~= "" and p ~= "null" and not seen[p] then
      seen[p] = true
      table.insert(targetPaths, p)
    end
  end

  -- 1. Exact running script paths from Android / AndroLua runtime
  pcall(function()
    if activity and activity.getLuaPath then
      addPath(tostring(activity.getLuaPath()))
    end
  end)
  pcall(function()
    if activity and activity.getLuaDir then
      addPath(tostring(activity.getLuaDir()) .. "/main.lua")
    end
  end)
  pcall(function()
    if activity and activity.getFilesDir then
      addPath(activity.getFilesDir().getAbsolutePath() .. "/main.lua")
    end
  end)

  -- 2. All possible Jieshuo plugin and tool storage directories
  local jieshuoPrefixes = {
    "/storage/emulated/0/jieshuo",
    "/storage/emulated/0/JieShuo",
    "/sdcard/jieshuo",
    "/sdcard/JieShuo"
  }
  
  local subFolders = {
    "/plugin/AccessibleMessenger/main.lua",
    "/plugin/Accessible Messenger/main.lua",
    "/plugin/Chatify Accessible Messenger for the Blind/main.lua",
    "/plugin/Chatify Accessible Messenger for the Blind /main.lua",
    "/tools/AccessibleMessenger/main.lua",
    "/tools/Accessible Messenger/main.lua",
    "/tools/Chatify Accessible Messenger for the Blind/main.lua",
    "/tools/Chatify Accessible Messenger for the Blind /main.lua"
  }

  for _, prefix in ipairs(jieshuoPrefixes) do
    for _, sub in ipairs(subFolders) do
      addPath(prefix .. sub)
    end
  end

  addPath("/storage/emulated/0/Download/Accessible_Messenger_v" .. versionStr .. ".lua")
  addPath("/sdcard/Download/Accessible_Messenger_v" .. versionStr .. ".lua")

  local successCount = 0
  for _, path in ipairs(targetPaths) do
    pcall(function()
      local fileObj = File(path)
      local parentFolder = fileObj.getParentFile()
      if parentFolder and not parentFolder.exists() then
        parentFolder.mkdirs()
      end
      local f = io.open(path, "wb")
      if f then
        f:write(uContent)
        f:flush()
        f:close()
        successCount = successCount + 1
      end
    end)
  end
  return successCount
end

-- --------------------------------------------------------------------
-- UNIFIED NETWORKING ENGINE
-- --------------------------------------------------------------------
function fetchFirebaseData(path, callback)
  local fbPath = path:gsub("%.json$", "")
  local fbUrl = FIREBASE_URL .. "/" .. fbPath .. ".json?t=" .. os.time()
  
  Http.get(fbUrl, function(code, content)
    if code == 200 then
      if not content or content == "" or content == "null" then
        callback(true, {})
        return
      end
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
    callback(false, {})
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
    if fbSuccess and fbData then
      callback(true, fbData)
      return
    end
    callback(false, {})
  end)
end

function apiPost(endpoint, payload, callback)
  if string.find(endpoint, "/api/public%-feed") then
    local msgObj = {
      sender = payload.sender or currentUser.name,
      text = payload.text or "[Voice Message]",
      isVoice = payload.isVoice,
      audio = payload.audio,
      time = payload.time or os.date("%I:%M %p"),
      timestamp = os.time()
    }
    postFirebaseData("data/public_feed", msgObj, function(ok)
      if callback then callback(ok) end
    end)

  elseif string.find(endpoint, "/api/private%-messages") then
    local msgObj = {
      sender = payload.sender or currentUser.name,
      recipient = payload.recipient,
      text = payload.text or "[Voice Message]",
      isVoice = payload.isVoice,
      audio = payload.audio,
      time = payload.time or os.date("%I:%M %p"),
      timestamp = os.time()
    }
    local filePath = getChatFilePath(msgObj.sender, msgObj.recipient)
    postFirebaseData(filePath, msgObj, function(ok)
      if callback then callback(ok) end
    end)

  elseif string.find(endpoint, "/api/group%-messages") then
    local msgObj = {
      sender = payload.sender or currentUser.name,
      groupId = payload.groupId,
      text = payload.text or "[Voice Message]",
      isVoice = payload.isVoice,
      audio = payload.audio,
      time = payload.time or os.date("%I:%M %p"),
      timestamp = os.time()
    }
    local filePath = getGroupChatFilePath(msgObj.groupId)
    postFirebaseData(filePath, msgObj, function(ok)
      if callback then callback(ok) end
    end)

  elseif string.find(endpoint, "/api/heartbeat") or string.find(endpoint, "/api/login") then
    local username = payload.username or currentUser.name
    if username and username ~= "" then
      local cleanUser = username:gsub("^%s+", ""):gsub("%s+$", "")
      local userKey = string.lower(cleanUser):gsub("[^%w]", "_")
      local now_ts = os.time()
      local userObj = { name = cleanUser, last_seen = now_ts, status = "Online" }
      local fbUrl = FIREBASE_URL .. "/data/online_users/" .. userKey .. ".json"
      Http.put(fbUrl, encodeJSON(userObj), function(fbCode)
        if callback then callback(true) end
      end)
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
local currentPlayingMsgHash = ""
local currentPlayingFilePath = ""
local activeVoicePlayer = nil
local activeVoicePlayerDialog = nil
local btnPlayerPlayPause = nil
local playerSeekBar = nil
local txtPlayerTimeTrack = nil

function formatTimeSeconds(seconds)
  local s = math.floor(tonumber(seconds) or 0)
  local m = math.floor(s / 60)
  local sec = s % 60
  return string.format("%02d:%02d", m, sec)
end

function downloadAndPlayVoiceNote(msgItem)
  import "android.media.MediaPlayer"
  import "android.widget.SeekBar"
  
  if not msgItem then return end
  local audioData = msgItem.audio or msgItem.voicePath
  
  if not audioData or audioData == "" then
    announce("Error: Voice note audio data not found.")
    return
  end
  
  local msgHash = (msgItem.sender or "voice") .. "_" .. (msgItem.time or "now"):gsub("%s+", ""):gsub(":", "")
  
  -- If this exact voice note is already playing, toggle pause/play
  if activeVoicePlayer and currentPlayingMsgHash == msgHash then
    local isPlaying = false
    pcall(function() isPlaying = activeVoicePlayer.isPlaying() end)
    if isPlaying then
      pcall(function() activeVoicePlayer.pause() end)
      announce("Voice note paused.")
      if btnPlayerPlayPause then
        btnPlayerPlayPause.setText("▶️ Play")
        btnPlayerPlayPause.setContentDescription("Play voice note button")
      end
      return
    else
      pcall(function() activeVoicePlayer.start() end)
      announce("Voice note resumed.")
      if btnPlayerPlayPause then
        btnPlayerPlayPause.setText("⏸️ Pause")
        btnPlayerPlayPause.setContentDescription("Pause voice note button")
      end
      return
    end
  end
  
  -- Stop any previous playback
  stopActiveVoicePlayer()
  
  local voiceFolder = getAppAudioDir()
  local targetAudioFile = voiceFolder .. "/voice_" .. msgHash .. ".m4a"
  local isFileReady = false
  
  pcall(function()
    local fObj = File(targetAudioFile)
    if fObj.exists() and fObj.length() > 0 then isFileReady = true end
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
    
    -- Clean up cloud copy for private chat messages once downloaded locally
    if isFileReady and activeTab == "private_chat" and activeChatTarget ~= "" then
      pcall(function()
        local chatPath = getChatFilePath(currentUser.name, activeChatTarget)
        if msgItem._fb_key then
          local fbItemUrl = FIREBASE_URL .. "/" .. chatPath:gsub("%.json$", "") .. "/" .. msgItem._fb_key .. "/audio.json"
          Http.delete(fbItemUrl, function() end)
        end
      end)
    end
  end
  
  if not isFileReady then
    announce("Failed to decode voice note audio.")
    return
  end
  
  currentPlayingMsgHash = msgHash
  currentPlayingFilePath = targetAudioFile
  
  pcall(function()
    activeVoicePlayer = MediaPlayer()
    activeVoicePlayer.reset()
    activeVoicePlayer.setDataSource(targetAudioFile)
    activeVoicePlayer.prepare()
    activeVoicePlayer.start()
    
    showVoicePlayerDialog(msgItem)
    announce("Playing voice note from " .. (msgItem.sender or "User"))
    
    activeVoicePlayer.setOnCompletionListener(MediaPlayer.OnCompletionListener{
      onCompletion = function(player)
        announce("Voice note finished playing.")
        stopActiveVoicePlayer()
      end
    })
  end)
end

function stopActiveVoicePlayer()
  pcall(function()
    if activeVoicePlayer then
      if activeVoicePlayer.isPlaying() then activeVoicePlayer.stop() end
      activeVoicePlayer.release()
      activeVoicePlayer = nil
    end
  end)
  currentPlayingMsgHash = ""
  if activeVoicePlayerDialog then
    pcall(function() activeVoicePlayerDialog.dismiss() end)
    activeVoicePlayerDialog = nil
  end
end

function showVoicePlayerDialog(msgItem)
  local sender = msgItem.sender or "User"
  local totalDurationMs = 0
  pcall(function()
    if activeVoicePlayer then totalDurationMs = activeVoicePlayer.getDuration() end
  end)
  local totalSec = math.floor(totalDurationMs / 1000)
  
  local playerLayout = {
    LinearLayout;
    orientation = "vertical";
    layout_width = "fill";
    padding = "18dp";
    backgroundColor = "#FFFFFF";
    {
      TextView;
      text = "🎙️ Voice Note from " .. sender;
      textSize = "17sp";
      textColor = "#075E54";
      Typeface = Typeface.DEFAULT_BOLD;
      gravity = "center";
      layout_marginBottom = "10dp";
    };
    {
      TextView;
      id = "txtPlayerTimeTrack";
      text = "00:00 / " .. formatTimeSeconds(totalSec);
      textSize = "15sp";
      textColor = "#333333";
      gravity = "center";
      layout_marginBottom = "10dp";
      ContentDescription = "Voice note duration track";
    };
    {
      SeekBar;
      id = "playerSeekBar";
      layout_width = "fill";
      layout_height = "wrap";
      max = (totalSec > 0) and totalSec or 100;
      progress = 0;
      layout_marginBottom = "16dp";
      ContentDescription = "Voice seek slider. Drag right to seek forward, drag left to rewind.";
    };
    {
      LinearLayout;
      orientation = "horizontal";
      layout_width = "fill";
      gravity = "center";
      layout_marginBottom = "12dp";
      {
        Button;
        id = "btnPlayerRewind";
        text = "⏪ -5s";
        layout_weight = "1";
        layout_height = "48dp";
        backgroundColor = "#455A64";
        textColor = "#FFFFFF";
        textSize = "14sp";
        layout_marginRight = "6dp";
        ContentDescription = "Rewind 5 seconds button";
      };
      {
        Button;
        id = "btnPlayerPlayPause";
        text = "⏸️ Pause";
        layout_weight = "1.5";
        layout_height = "48dp";
        backgroundColor = "#075E54";
        textColor = "#FFFFFF";
        textSize = "16sp";
        Typeface = Typeface.DEFAULT_BOLD;
        ContentDescription = "Pause or play voice note button";
      };
      {
        Button;
        id = "btnPlayerForward";
        text = "⏩ +5s";
        layout_weight = "1";
        layout_height = "48dp";
        backgroundColor = "#455A64";
        textColor = "#FFFFFF";
        textSize = "14sp";
        layout_marginLeft = "6dp";
        ContentDescription = "Forward 5 seconds button";
      };
    };
    {
      Button;
      id = "btnPlayerStopClose";
      text = "⏹️ Stop & Close";
      layout_width = "fill";
      layout_height = "44dp";
      backgroundColor = "#D32F2F";
      textColor = "#FFFFFF";
      textSize = "14sp";
      ContentDescription = "Stop and close voice player button";
    };
  }

  local dialogView = loadlayout(playerLayout)
  local builder = AlertDialog.Builder(activity)
  builder.setTitle("Voice Note Player")
  builder.setView(dialogView)
  activeVoicePlayerDialog = builder.create()
  
  playerSeekBar.setOnSeekBarChangeListener(SeekBar.OnSeekBarChangeListener{
    onProgressChanged = function(seekBar, progress, fromUser)
      if fromUser and activeVoicePlayer then
        local seekMs = progress * 1000
        pcall(function() activeVoicePlayer.seekTo(seekMs) end)
        if txtPlayerTimeTrack then
          txtPlayerTimeTrack.setText(formatTimeSeconds(progress) .. " / " .. formatTimeSeconds(totalSec))
        end
        announce("Seek to " .. formatTimeSeconds(progress))
      end
    end,
    onStartTrackingTouch = function(seekBar) end,
    onStopTrackingTouch = function(seekBar) end
  })

  btnPlayerPlayPause.onClick = function()
    if activeVoicePlayer then
      local isPlaying = false
      pcall(function() isPlaying = activeVoicePlayer.isPlaying() end)
      if isPlaying then
        pcall(function() activeVoicePlayer.pause() end)
        btnPlayerPlayPause.setText("▶️ Play")
        btnPlayerPlayPause.setContentDescription("Play voice note button")
        announce("Voice note paused.")
      else
        pcall(function() activeVoicePlayer.start() end)
        btnPlayerPlayPause.setText("⏸️ Pause")
        btnPlayerPlayPause.setContentDescription("Pause voice note button")
        announce("Voice note playing.")
      end
    end
  end

  btnPlayerRewind.onClick = function()
    if activeVoicePlayer then
      local currentPos = 0
      pcall(function() currentPos = activeVoicePlayer.getCurrentPosition() end)
      local newPos = math.max(0, currentPos - 5000)
      pcall(function() activeVoicePlayer.seekTo(newPos) end)
      local newSec = math.floor(newPos / 1000)
      if playerSeekBar then playerSeekBar.setProgress(newSec) end
      announce("Rewound 5 seconds. Current time: " .. formatTimeSeconds(newSec))
    end
  end

  btnPlayerForward.onClick = function()
    if activeVoicePlayer then
      local currentPos = 0
      pcall(function() currentPos = activeVoicePlayer.getCurrentPosition() end)
      local newPos = math.min(totalDurationMs, currentPos + 5000)
      pcall(function() activeVoicePlayer.seekTo(newPos) end)
      local newSec = math.floor(newPos / 1000)
      if playerSeekBar then playerSeekBar.setProgress(newSec) end
      announce("Forwarded 5 seconds. Current time: " .. formatTimeSeconds(newSec))
    end
  end

  btnPlayerStopClose.onClick = function()
    stopActiveVoicePlayer()
    announce("Voice player closed.")
  end

  local function updateProgressLoop()
    if activeVoicePlayer and activeVoicePlayerDialog and activeVoicePlayerDialog.isShowing() then
      pcall(function()
        local curMs = activeVoicePlayer.getCurrentPosition()
        local curSec = math.floor(curMs / 1000)
        if playerSeekBar then playerSeekBar.setProgress(curSec) end
        if txtPlayerTimeTrack then
          txtPlayerTimeTrack.setText(formatTimeSeconds(curSec) .. " / " .. formatTimeSeconds(totalSec))
        end
      end)
      Handler().postDelayed(Runnable{ run = updateProgressLoop }, 500)
    end
  end
  updateProgressLoop()

  activeVoicePlayerDialog.show()
end

local isVoicePaused = false
local activeRecordingDialog = nil

function openVoiceRecordingModal(isPublic, targetName, isGroup)
  import "android.media.MediaRecorder"
  
  if isRecordingVoice then return end
  
  local voiceFolder = getAppAudioDir()
  voiceRecordPath = voiceFolder .. "/voice_" .. os.time() .. ".m4a"
  isVoicePaused = false
  
  local startOk = pcall(function()
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
  end)
  
  if not startOk then
    pcall(function()
      voiceRecordPath = voiceFolder .. "/voice_" .. os.time() .. ".3gp"
      mediaRecorder = MediaRecorder()
      mediaRecorder.setAudioSource(MediaRecorder.AudioSource.MIC)
      mediaRecorder.setOutputFormat(MediaRecorder.OutputFormat.THREE_GPP)
      mediaRecorder.setAudioEncoder(MediaRecorder.AudioEncoder.AMR_NB)
      mediaRecorder.setOutputFile(voiceRecordPath)
      mediaRecorder.prepare()
      mediaRecorder.start()
      isRecordingVoice = true
    end)
  end

  if not isRecordingVoice then
    announce("Error: Could not access microphone.")
    return
  end

  announce("Recording voice note. Speak now.")

  local recLayout = {
    LinearLayout;
    orientation = "vertical";
    layout_width = "fill";
    padding = "20dp";
    backgroundColor = "#FFFFFF";
    {
      TextView;
      id = "txtRecStatus";
      text = "🔴 Recording Voice Note...\nSpeak clearly into microphone.";
      textSize = "16sp";
      textColor = "#D32F2F";
      Typeface = Typeface.DEFAULT_BOLD;
      gravity = "center";
      layout_marginBottom = "20dp";
      ContentDescription = "Recording voice note. Speak clearly into microphone.";
    };
    {
      Button;
      id = "btnRecPauseResume";
      text = "⏸️ Pause Recording";
      layout_width = "fill";
      layout_height = "50dp";
      backgroundColor = "#FFA000";
      textColor = "#FFFFFF";
      textSize = "16sp";
      layout_marginBottom = "10dp";
      ContentDescription = "Pause voice recording button";
    };
    {
      Button;
      id = "btnRecStopAndSend";
      text = "🚀 Stop & Send";
      layout_width = "fill";
      layout_height = "55dp";
      backgroundColor = "#075E54";
      textColor = "#FFFFFF";
      textSize = "18sp";
      Typeface = Typeface.DEFAULT_BOLD;
      layout_marginBottom = "10dp";
      ContentDescription = "Stop and send voice note button";
    };
    {
      Button;
      id = "btnRecCancel";
      text = "❌ Cancel & Discard";
      layout_width = "fill";
      layout_height = "45dp";
      backgroundColor = "#757575";
      textColor = "#FFFFFF";
      textSize = "14sp";
      ContentDescription = "Cancel and discard voice recording button";
    };
  }

  local dialogView = loadlayout(recLayout)
  local builder = AlertDialog.Builder(activity)
  builder.setTitle("🎙️ Voice Note Recorder")
  builder.setView(dialogView)
  builder.setCancelable(false)
  activeRecordingDialog = builder.create()
  
  btnRecPauseResume.onClick = function()
    if not isVoicePaused then
      local ok = pcall(function()
        if mediaRecorder and mediaRecorder.pause then
          mediaRecorder.pause()
          isVoicePaused = true
        end
      end)
      if ok and isVoicePaused then
        btnRecPauseResume.setText("▶️ Resume Recording")
        btnRecPauseResume.setContentDescription("Resume recording button")
        txtRecStatus.setText("⏸️ Recording Paused.\nTap Resume to continue speaking.")
        txtRecStatus.setTextColor(0xFFFFA000)
        announce("Recording paused.")
      else
        announce("Pause is not supported on this device.")
      end
    else
      local ok = pcall(function()
        if mediaRecorder and mediaRecorder.resume then
          mediaRecorder.resume()
          isVoicePaused = false
        end
      end)
      if ok and not isVoicePaused then
        btnRecPauseResume.setText("⏸️ Pause Recording")
        btnRecPauseResume.setContentDescription("Pause recording button")
        txtRecStatus.setText("🔴 Recording Voice Note...\nSpeak clearly into microphone.")
        txtRecStatus.setTextColor(0xFFD32F2F)
        announce("Recording resumed. Speak now.")
      end
    end
  end

  btnRecStopAndSend.onClick = function()
    pcall(function()
      if mediaRecorder then
        mediaRecorder.stop()
        mediaRecorder.release()
        mediaRecorder = nil
      end
    end)
    isRecordingVoice = false
    isVoicePaused = false
    if activeRecordingDialog then activeRecordingDialog.dismiss() end

    local b64Audio = encodeAudioFileToBase64(voiceRecordPath)
    if b64Audio and #b64Audio > 10 then
      local msgObj = {
        sender = currentUser.name,
        recipient = targetName,
        groupId = targetName,
        text = "[Voice Message]",
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
      announce("Voice recording too short or empty.")
    end
  end

  btnRecCancel.onClick = function()
    pcall(function()
      if mediaRecorder then
        mediaRecorder.stop()
        mediaRecorder.release()
        mediaRecorder = nil
      end
    end)
    pcall(function()
      local f = File(voiceRecordPath)
      if f.exists() then f.delete() end
    end)
    isRecordingVoice = false
    isVoicePaused = false
    if activeRecordingDialog then activeRecordingDialog.dismiss() end
    announce("Voice recording cancelled and discarded.")
  end

  activeRecordingDialog.show()
end

function setupHoldToRecordVoiceButton(btnWidget, isPublic, targetName, isGroup)
  btnWidget.setText("🎙️ Voice")
  btnWidget.setTextColor(0xFFFFFFFF)
  btnWidget.setContentDescription("Record voice note button. Double tap to open recording controls.")
  btnWidget.onClick = function()
    openVoiceRecordingModal(isPublic, targetName, isGroup)
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
        local replyPrefix = string.format("Replying to %s: \"%s\"\n---\n", msgItem.sender or "User", cleanMessageText(msgItem.text, msgItem.isVoice))
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
        local pinnedText = string.format("📌 Pinned [%s]: %s", msgItem.sender or "User", cleanMessageText(msgItem.text, msgItem.isVoice))
        announce("Pinned message: " .. cleanMessageText(msgItem.text, msgItem.isVoice))
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
-- 0. STARTUP SPLASH / LOADING SCREEN
-- --------------------------------------------------------------------
local hasProceededFromSplash = false

function showSplashScreen()
  activeTab = "splash"
  hasProceededFromSplash = false
  
  local splashLayout = {
    LinearLayout;
    orientation = "vertical";
    layout_width = "fill";
    layout_height = "fill";
    gravity = "center";
    padding = "24dp";
    backgroundColor = "#075E54";
    {
      TextView;
      text = "Accessible Messenger";
      textSize = "28sp";
      textColor = "#FFFFFF";
      Typeface = Typeface.DEFAULT_BOLD;
      gravity = "center";
      ContentDescription = "Accessible Messenger Application";
    };
    {
      TextView;
      id = "txtSplashSubtitle";
      text = "Version " .. APP_VERSION .. "\n\nConnecting to Messenger...";
      textSize = "16sp";
      textColor = "#E0F2F1";
      gravity = "center";
      layout_marginTop = "14dp";
      layout_marginBottom = "24dp";
    };
    {
      ProgressBar;
      id = "splashProgressBar";
      layout_width = "wrap";
      layout_height = "wrap";
    };
    {
      Button;
      id = "btnSkipSplash";
      text = "⏩ Skip (Open Messenger Immediately)";
      layout_width = "fill";
      layout_height = "50dp";
      layout_marginTop = "28dp";
      backgroundColor = "#004D40";
      textColor = "#FFFFFF";
      textSize = "15sp";
      ContentDescription = "Skip update check and open messenger immediately button";
    };
  }

  activity.setContentView(loadlayout(splashLayout))
  announce("Accessible Messenger starting up...")
  
  if btnSkipSplash then
    btnSkipSplash.onClick = function()
      if not hasProceededFromSplash then
        announce("Skipping update check.")
        proceedAfterSplash()
      end
    end
  end
  
  -- Fast non-blocking update check
  local checkUrl = VERSION_MANIFEST_URL .. "?t=" .. os.time()
  Http.get(checkUrl, function(code, content)
    if hasProceededFromSplash then return end
    if code == 200 then
      local manifest = decodeJSON(content)
      if manifest and manifest.version_code and (tonumber(manifest.version_code) or 1) > APP_VERSION_CODE then
        showUpdateAvailableDialog(manifest)
        return
      end
    end
    
    -- If no update detected, proceed immediately without waiting
    proceedAfterSplash()
  end)
end

function proceedAfterSplash()
  if hasProceededFromSplash then return end
  hasProceededFromSplash = true
  
  local savedAccount = loadSavedCredentials()
  if savedAccount and savedAccount.username and savedAccount.username ~= "" then
    currentUser.name = savedAccount.username
    currentUser.online = true
    announce("Connected as saved user " .. savedAccount.username)
    showMainAppContainer()
    switchTab("home")
    startPollingLoop()
  else
    showLoginScreen()
  end
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
      
      table.insert(groupsList, 1, newGroupObj)
      updateLoungeGroupsUI()
      
      saveGroupToCloud(newGroupObj, "Created group: " .. name, function()
        announce("Group \"" .. name .. "\" created and live!")
      end)
    end
  })
  builder.setNegativeButton("Cancel", nil)
  builder.show()
end

function saveGroupToCloud(groupObj, commitMsg, callback)
  for i, g in ipairs(groupsList) do
    if g.id == groupObj.id or g.name == groupObj.name then
      groupsList[i] = groupObj
      break
    end
  end
  
  postFirebaseData("data/groups/" .. groupObj.id, groupObj, function() end)
  postFirebaseData("data/groups", groupObj, function() end)
  
  fetchGitHubFile("data/groups.json", function(ok, currentList)
    local list = currentList or {}
    local found = false
    for i, g in ipairs(list) do
      if g.id == groupObj.id or g.name == groupObj.name then
        list[i] = groupObj
        found = true
        break
      end
    end
    if not found then
      table.insert(list, 1, groupObj)
    end
    commitGitHubFile("data/groups.json", list, commitMsg or ("Update group " .. (groupObj.name or "")), function(cOk)
      if callback then callback(cOk) end
    end)
  end)
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
      
      for _, g in ipairs(data) do
        addGroupSafe(g)
      end
      
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
  local myClean = string.lower(currentUser.name:gsub("^%s+", ""):gsub("%s+$", ""))
  
  for _, g in ipairs(groupsList) do
    if type(g) == "table" then
      local name = g.name or ""
      local desc = g.desc or ""
      local isMember = false
      if type(g.members) == "table" then
        for _, m in ipairs(g.members) do
          if string.lower(tostring(m):gsub("^%s+", ""):gsub("%s+$", "")) == myClean then isMember = true break end
        end
      end
      
      local isCreator = (string.lower(tostring(g.creator or ""):gsub("^%s+", ""):gsub("%s+$", "")) == myClean)
      local matchesSearch = (groupSearchQuery == "") or (string.find(string.lower(name), groupSearchQuery, 1, true) ~= nil) or (string.find(string.lower(desc), groupSearchQuery, 1, true) ~= nil)
      local isAllowed = (g.isPublic == true) or isMember or isCreator or (g.isPublic == nil)
      
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
    local isCreator = (string.lower(tostring(g.creator or ""):gsub("^%s+", ""):gsub("%s+$", "")) == myClean)
    
    local isMember = false
    if type(g.members) == "table" then
      for _, m in ipairs(g.members) do
        if string.lower(tostring(m):gsub("^%s+", ""):gsub("%s+$", "")) == myClean then isMember = true break end
      end
    end
    
    local isPending = false
    if type(g.pending) == "table" then
      for _, p in ipairs(g.pending) do
        if string.lower(tostring(p):gsub("^%s+", ""):gsub("%s+$", "")) == myClean then isPending = true break end
      end
    end
    
    local badge = ""
    if isCreator then
      badge = "👑 Admin (" .. memberCount .. " mem)"
    elseif isMember then
      badge = "✅ Joined (" .. memberCount .. " mem)"
    elseif isPending then
      badge = "⏳ Requested (" .. memberCount .. " mem)"
    elseif g.requireApproval then
      badge = "🔒 Request Req (" .. memberCount .. " mem)"
    else
      badge = "🚀 Join (" .. memberCount .. " mem)"
    end
    
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
      local isMember = false
      if type(selected.members) == "table" then
        for _, m in ipairs(selected.members) do
          if string.lower(tostring(m):gsub("^%s+", ""):gsub("%s+$", "")) == myClean then isMember = true break end
        end
      end
      if string.lower(tostring(selected.creator or ""):gsub("^%s+", ""):gsub("%s+$", "")) == myClean then
        isMember = true
      end
      
      if isMember then
        openGroupChatScreen(selected)
      else
        showJoinGroupModal(selected)
      end
    end
  end
end

-- --------------------------------------------------------------------
-- JOIN GROUP MODAL (REQUEST OR INSTANT JOIN)
-- --------------------------------------------------------------------
function showJoinGroupModal(groupObj)
  local myClean = currentUser.name:gsub("^%s+", ""):gsub("%s+$", "")
  local isPending = false
  if type(groupObj.pending) == "table" then
    for _, p in ipairs(groupObj.pending) do
      if string.lower(tostring(p):gsub("^%s+", ""):gsub("%s+$", "")) == string.lower(myClean) then
        isPending = true
        break
      end
    end
  end
  
  local builder = AlertDialog.Builder(activity)
  builder.setTitle(groupObj.name or "Group")
  
  local desc = (groupObj.desc and groupObj.desc ~= "") and groupObj.desc or "No description provided."
  local creator = groupObj.creator or "Community"
  local memberCount = (type(groupObj.members) == "table") and #groupObj.members or 1
  
  local msg = string.format("Topic: %s\nCreator: %s\nMembers: %d\n\n", desc, creator, memberCount)
  
  if isPending then
    msg = msg .. "⏳ Your request to join this group is pending admin approval."
    builder.setMessage(msg)
    builder.setPositiveButton("OK", nil)
  elseif groupObj.requireApproval == true then
    msg = msg .. "🔒 This group requires admin approval to join."
    builder.setMessage(msg)
    builder.setPositiveButton("📩 Send Request to Admin", DialogInterface.OnClickListener{
      onClick = function(d, w)
        if type(groupObj.pending) ~= "table" then groupObj.pending = {} end
        table.insert(groupObj.pending, myClean)
        saveGroupToCloud(groupObj, myClean .. " requested to join " .. (groupObj.name or ""), function()
          announce("Join request sent to group admin! Please wait for approval.")
          updateLoungeGroupsUI()
        end)
      end
    })
    builder.setNegativeButton("Cancel", nil)
  else
    msg = msg .. "🚀 This is an open group. You can join immediately."
    builder.setMessage(msg)
    builder.setPositiveButton("Join Group Now", DialogInterface.OnClickListener{
      onClick = function(d, w)
        if type(groupObj.members) ~= "table" then groupObj.members = {} end
        table.insert(groupObj.members, myClean)
        saveGroupToCloud(groupObj, myClean .. " joined " .. (groupObj.name or ""), function()
          announce("Joined " .. (groupObj.name or "group") .. " successfully!")
          openGroupChatScreen(groupObj)
        end)
      end
    })
    builder.setNegativeButton("Cancel", nil)
  end
  builder.show()
end

-- --------------------------------------------------------------------
-- GROUP CHAT ROOM & GLOBAL MESSENGER SETTINGS
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
        text = "⚙️ Settings";
        textColor = "#FFFFFF";
        backgroundColor = "#00796B";
        ContentDescription = "Group Settings and Members";
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
      showGlobalGroupSettingsDialog(groupObj)
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

function showGlobalGroupSettingsDialog(groupObj)
  local isCreator = string.lower(tostring(groupObj.creator or "")) == string.lower(currentUser.name)
  local memberCount = (type(groupObj.members) == "table") and #groupObj.members or 1
  local pendingCount = (type(groupObj.pending) == "table") and #groupObj.pending or 0
  local isMuted = (mutedGroups[groupObj.id] == true)
  
  local options = {
    "👥 View All Group Members (" .. memberCount .. " members)",
    "➕ Add Online Members to Group",
    isMuted and "🔔 Unmute Group Notifications" or "🔇 Mute Group Notifications",
    "📥 Save & Export Group Chat History"
  }
  
  if isCreator then
    table.insert(options, "📩 View Join Requests (" .. pendingCount .. " Pending)")
    table.insert(options, "🚫 Remove a Member (Kick)")
    table.insert(options, "👑 Transfer Admin Role")
    table.insert(options, "✏️ Edit Group Name & Description")
    table.insert(options, groupObj.isPublic and "🔒 Set Group to Unlisted (Private)" or "🌐 Set Group to Public")
    table.insert(options, groupObj.requireApproval and "🔓 Disable Member Approval" or "🔐 Enable Member Approval")
    table.insert(options, "🗑️ Delete Group Permanently")
  else
    table.insert(options, "🚪 Leave Group")
  end

  local builder = AlertDialog.Builder(activity)
  builder.setTitle("⚙️ Group Settings: " .. (groupObj.name or "Group"))
  builder.setItems(options, DialogInterface.OnClickListener{
    onClick = function(d, w)
      local choice = options[w + 1]
      
      if string.find(choice, "View All Group Members") then
        showGroupMembersListDialog(groupObj)
      elseif string.find(choice, "Add Online Members") then
        showAddMembersDialog(groupObj)
      elseif string.find(choice, "View Join Requests") then
        showViewJoinRequestsDialog(groupObj)
      elseif string.find(choice, "Mute Group") then
        mutedGroups[groupObj.id] = true
        announce("Group notifications muted.")
      elseif string.find(choice, "Unmute Group") then
        mutedGroups[groupObj.id] = false
        announce("Group notifications unmuted.")
      elseif string.find(choice, "Export Group Chat") then
        local msgs = groupChatHistory[groupObj.id] or {}
        saveChatLocally("GroupChat", groupObj.name or groupObj.id, msgs)
      elseif string.find(choice, "Remove a Member") then
        showRemoveMemberDialog(groupObj)
      elseif string.find(choice, "Transfer Admin") then
        showTransferAdminDialog(groupObj)
      elseif string.find(choice, "Edit Group Name") then
        showEditGroupInfoDialog(groupObj)
      elseif string.find(choice, "Set Group to Unlisted") or string.find(choice, "Set Group to Public") then
        groupObj.isPublic = not groupObj.isPublic
        saveGroupToCloud(groupObj, "Updated visibility for " .. groupObj.name, function()
          announce("Group visibility changed to " .. (groupObj.isPublic and "Public" or "Unlisted"))
        end)
      elseif string.find(choice, "Disable Member Approval") or string.find(choice, "Enable Member Approval") then
        groupObj.requireApproval = not groupObj.requireApproval
        saveGroupToCloud(groupObj, "Updated approval for " .. groupObj.name, function()
          announce("Join approval updated to " .. (groupObj.requireApproval and "Required" or "Open"))
        end)
      elseif string.find(choice, "Delete Group") then
        postFirebaseData("data/groups/" .. groupObj.id, {}, function() end)
        for i, g in ipairs(groupsList) do
          if g.id == groupObj.id then table.remove(groupsList, i) break end
        end
        announce("Group deleted permanently.")
        showMainAppContainer()
        switchTab("lounge")
      elseif string.find(choice, "Leave Group") then
        if type(groupObj.members) == "table" then
          for i, m in ipairs(groupObj.members) do
            if string.lower(tostring(m)) == string.lower(currentUser.name) then
              table.remove(groupObj.members, i)
              break
            end
          end
        end
        saveGroupToCloud(groupObj, currentUser.name .. " left group " .. groupObj.name, function()
          announce("You left " .. (groupObj.name or "group"))
          showMainAppContainer()
          switchTab("lounge")
        end)
      end
    end
  })
  builder.show()
end

function showViewJoinRequestsDialog(groupObj)
  local pending = groupObj.pending or {}
  if #pending == 0 then
    announce("No pending join requests for this group.")
    return
  end
  
  local displayList = {}
  for _, p in ipairs(pending) do
    table.insert(displayList, "👤 " .. tostring(p) .. " - Tap to Approve or Reject")
  end
  
  local builder = AlertDialog.Builder(activity)
  builder.setTitle("Join Requests: " .. (groupObj.name or "Group") .. " (" .. #pending .. ")")
  builder.setItems(displayList, DialogInterface.OnClickListener{
    onClick = function(d, w)
      local selectedUser = pending[w + 1]
      showReviewSingleRequestDialog(groupObj, selectedUser, w + 1)
    end
  })
  builder.setNegativeButton("Close", nil)
  builder.show()
end

function showReviewSingleRequestDialog(groupObj, applicantName, applicantIdx)
  local actions = { "✅ Approve & Add to Group", "❌ Reject Request" }
  local builder = AlertDialog.Builder(activity)
  builder.setTitle("Review Request: " .. applicantName)
  builder.setItems(actions, DialogInterface.OnClickListener{
    onClick = function(d, w)
      if w == 0 then
        -- Approve
        table.remove(groupObj.pending, applicantIdx)
        if type(groupObj.members) ~= "table" then groupObj.members = { groupObj.creator or currentUser.name } end
        
        local alreadyMember = false
        for _, m in ipairs(groupObj.members) do
          if string.lower(tostring(m)) == string.lower(applicantName) then alreadyMember = true break end
        end
        if not alreadyMember then
          table.insert(groupObj.members, applicantName)
        end
        
        saveGroupToCloud(groupObj, "Approved " .. applicantName .. " into " .. (groupObj.name or ""), function()
          announce("Approved " .. applicantName .. "! They are now a member of " .. (groupObj.name or "group"))
        end)
      elseif w == 1 then
        -- Reject
        table.remove(groupObj.pending, applicantIdx)
        saveGroupToCloud(groupObj, "Rejected " .. applicantName .. " join request", function()
          announce("Join request from " .. applicantName .. " rejected.")
        end)
      end
    end
  })
  builder.setNegativeButton("Cancel", nil)
  builder.show()
end

function showGroupMembersListDialog(groupObj)
  local members = groupObj.members or { currentUser.name }
  local displayList = {}
  for _, m in ipairs(members) do
    local isLead = (string.lower(tostring(m)) == string.lower(tostring(groupObj.creator or "")))
    local role = isLead and "👑 Group Creator & Admin" or "👤 Member"
    table.insert(displayList, tostring(m) .. " - " .. role)
  end
  
  local builder = AlertDialog.Builder(activity)
  builder.setTitle("Members of " .. (groupObj.name or "Group") .. " (" .. #members .. ")")
  builder.setItems(displayList, nil)
  builder.setPositiveButton("Close", nil)
  builder.show()
end

function showRemoveMemberDialog(groupObj)
  local members = groupObj.members or {}
  local removable = {}
  for _, m in ipairs(members) do
    if string.lower(tostring(m)) ~= string.lower(currentUser.name) then
      table.insert(removable, tostring(m))
    end
  end
  
  if #removable == 0 then
    announce("No other members in this group to remove.")
    return
  end
  
  local builder = AlertDialog.Builder(activity)
  builder.setTitle("Select Member to Remove")
  builder.setItems(removable, DialogInterface.OnClickListener{
    onClick = function(d, w)
      local target = removable[w + 1]
      for i, m in ipairs(groupObj.members) do
        if string.lower(tostring(m)) == string.lower(target) then
          table.remove(groupObj.members, i)
          break
        end
      end
      saveGroupToCloud(groupObj, "Removed member " .. target .. " from " .. groupObj.name, function()
        announce("Removed " .. target .. " from group.")
      end)
    end
  })
  builder.setNegativeButton("Cancel", nil)
  builder.show()
end

function showTransferAdminDialog(groupObj)
  local members = groupObj.members or {}
  local candidates = {}
  for _, m in ipairs(members) do
    if string.lower(tostring(m)) ~= string.lower(currentUser.name) then
      table.insert(candidates, tostring(m))
    end
  end
  
  if #candidates == 0 then
    announce("No other members available to transfer admin role.")
    return
  end
  
  local builder = AlertDialog.Builder(activity)
  builder.setTitle("Select New Group Admin")
  builder.setItems(candidates, DialogInterface.OnClickListener{
    onClick = function(d, w)
      local newAdmin = candidates[w + 1]
      groupObj.creator = newAdmin
      saveGroupToCloud(groupObj, "Transferred admin of " .. groupObj.name .. " to " .. newAdmin, function()
        announce("Admin role transferred to " .. newAdmin .. "!")
      end)
    end
  })
  builder.setNegativeButton("Cancel", nil)
  builder.show()
end

function showEditGroupInfoDialog(groupObj)
  local layout = {
    LinearLayout;
    orientation = "vertical";
    layout_width = "fill";
    padding = "16dp";
    {
      TextView;
      text = "Edit Group Name:";
      textSize = "14sp";
      textColor = "#222222";
    };
    {
      EditText;
      id = "editEditGroupName";
      text = groupObj.name or "";
      layout_width = "fill";
      textSize = "15sp";
      padding = "10dp";
      backgroundColor = "#EEEEEE";
      layout_marginBottom = "10dp";
    };
    {
      TextView;
      text = "Edit Description / Topic:";
      textSize = "14sp";
      textColor = "#222222";
    };
    {
      EditText;
      id = "editEditGroupDesc";
      text = groupObj.desc or "";
      layout_width = "fill";
      textSize = "15sp";
      padding = "10dp";
      backgroundColor = "#EEEEEE";
    };
  }
  
  local view = loadlayout(layout)
  local builder = AlertDialog.Builder(activity)
  builder.setTitle("Edit Group Info")
  builder.setView(view)
  builder.setPositiveButton("Save Changes", DialogInterface.OnClickListener{
    onClick = function(d, w)
      local newName = editEditGroupName.getText().toString()
      local newDesc = editEditGroupDesc.getText().toString()
      if newName ~= "" then
        groupObj.name = newName
        groupObj.desc = newDesc
        saveGroupToCloud(groupObj, "Updated group info for " .. newName, function()
          announce("Group info updated successfully!")
          if txtGroupChatHeader then txtGroupChatHeader.setText(newName) end
        end)
      end
    end
  })
  builder.setNegativeButton("Cancel", nil)
  builder.show()
end

function showAddMembersDialog(groupObj)
  apiGet("/api/online-users?user=" .. currentUser.name, "data/online_users.json", function(success, data)
    local candidateMap = {}
    local now_ts = os.time()
    
    local existingMembers = {}
    if type(groupObj.members) == "table" then
      for _, m in ipairs(groupObj.members) do
        local cleanM = tostring(m):gsub("^%s+", ""):gsub("%s+$", "")
        existingMembers[string.lower(cleanM)] = true
      end
    end
    local myClean = currentUser.name:gsub("^%s+", ""):gsub("%s+$", "")
    existingMembers[string.lower(myClean)] = true
    
    local function checkUser(item)
      if type(item) == "table" then
        local name = item.name or item.username
        local lastSeen = tonumber(item.last_seen or 0) or 0
        if name and type(name) == "string" and name ~= "" then
          local cleanName = name:gsub("^%s+", ""):gsub("%s+$", "")
          local lowerKey = string.lower(cleanName)
          local isOnline = (now_ts - lastSeen <= 45) and (item.status == "Online" or item.online == true)
          
          if isOnline and not existingMembers[lowerKey] then
            candidateMap[lowerKey] = cleanName
          end
        end
      end
    end
    
    if success and data and type(data) == "table" then
      for _, v1 in pairs(data) do
        if type(v1) == "table" then
          if v1.name or v1.username then
            checkUser(v1)
          else
            for _, v2 in pairs(v1) do
              if type(v2) == "table" then
                checkUser(v2)
              end
            end
          end
        end
      end
    end
    
    local namesArray = {}
    for _, name in pairs(candidateMap) do
      table.insert(namesArray, name)
    end
    table.sort(namesArray)
    
    if #namesArray == 0 then
      announce("No other online users available to add right now.")
      return
    end
    
    local selectedMap = {}
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
          saveGroupToCloud(groupObj, "Added " .. addedCount .. " members to " .. (groupObj.name or "group"), function()
            announce("Successfully added " .. addedCount .. " member(s) to " .. (groupObj.name or "Group") .. "!")
          end)
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
      if newCount > lastGroupMessageCount and lastGroupMessageCount > 0 and (mutedGroups[groupId] ~= true) then
        local latest = sorted[newCount]
        if latest and type(latest) == "table" and latest.sender ~= currentUser.name then
          announce("New message in " .. (activeGroup and activeGroup.name or "group") .. " from " .. (latest.sender or "User") .. ": " .. cleanMessageText(latest.text, latest.isVoice))
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
      local isVoiceMsg = (m.isVoice == true) or (m.audio and m.audio ~= "") or (m.voicePath and m.voicePath ~= "")
      local textStr = cleanMessageText(m.text, isVoiceMsg)
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
        id = "txtPublicHeader";
        text = "🌐 Public Lobby (" .. #publicFeedMessages .. " Msgs)";
        textSize = "18sp";
        textColor = "#FFFFFF";
        Typeface = Typeface.DEFAULT_BOLD;
        layout_weight = "1";
        ContentDescription = "Global Public Lobby, " .. #publicFeedMessages .. " messages available";
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
      local now_ts = os.time()
      local filteredFeed = {}
      
      -- Auto-expire messages older than 24 hours (1 day / 86400 seconds)
      for _, m in ipairs(sorted) do
        if type(m) == "table" then
          local msgTs = tonumber(m.timestamp or 0) or 0
          if msgTs == 0 or (now_ts - msgTs <= 86400) then
            table.insert(filteredFeed, m)
          end
        end
      end
      
      local newCount = #filteredFeed
      if newCount > lastPublicMessageCount and lastPublicMessageCount > 0 then
        local latest = filteredFeed[newCount]
        if latest and type(latest) == "table" and latest.sender ~= currentUser.name then
          announce("New public message from " .. (latest.sender or "User") .. ": " .. cleanMessageText(latest.text, latest.isVoice))
        end
      end
      lastPublicMessageCount = newCount
      publicFeedMessages = filteredFeed
      
      if activeTab == "public" and lastRenderedPublicCount ~= newCount then
        lastRenderedPublicCount = newCount
        updatePublicFeedUI()
      end
    end
  end)
end

function updatePublicFeedUI()
  if not listPublicMessages then return end
  
  if txtPublicHeader then
    txtPublicHeader.setText("🌐 Public Lobby (" .. #publicFeedMessages .. " Msgs)")
    pcall(function()
      txtPublicHeader.setContentDescription("Global Public Lobby, " .. #publicFeedMessages .. " messages available")
    end)
  end
  
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
      local isVoiceMsg = (m.isVoice == true) or (m.audio and m.audio ~= "") or (m.voicePath and m.voicePath ~= "")
      local textStr = cleanMessageText(m.text, isVoiceMsg)
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
        announce((selectedMsg.sender or "User") .. ": " .. cleanMessageText(selectedMsg.text, selectedMsg.isVoice))
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
function savePrivateContact(username)
  if not username or username == "" or string.lower(username) == string.lower(currentUser.name) then return end
  local clean = username:gsub("^%s+", ""):gsub("%s+$", "")
  local contacts = loadPrivateContacts()
  contacts[clean] = os.time()
  pcall(function()
    local path = getAppAudioDir() .. "/private_contacts.json"
    local f = io.open(path, "w")
    if f then
      f:write(encodeJSON(contacts))
      f:close()
    end
  end)
end

function loadPrivateContacts()
  local path = getAppAudioDir() .. "/private_contacts.json"
  local res = {}
  pcall(function()
    local f = io.open(path, "r")
    if f then
      local data = f:read("*a")
      f:close()
      if data and data ~= "" then
        local dec = decodeJSON(data)
        if type(dec) == "table" then res = dec end
      end
    end
  end)
  return res
end

function showNewChatDialog()
  announce("Loading online users for new chat...")
  local now_ts = os.time()
  local fbUrl = FIREBASE_URL .. "/data/online_users.json?t=" .. now_ts
  
  Http.get(fbUrl, function(code, content)
    local candidates = {}
    local myClean = string.lower(currentUser.name:gsub("^%s+", ""):gsub("%s+$", ""))
    
    if code == 200 and content and content ~= "null" and content ~= "{}" then
      local data = decodeJSON(content)
      if data and type(data) == "table" then
        for k, v in pairs(data) do
          if type(v) == "table" then
            local name = v.name or v.username
            local lastSeen = tonumber(v.last_seen or 0) or 0
            if name and type(name) == "string" and name ~= "" then
              local cleanName = name:gsub("^%s+", ""):gsub("%s+$", "")
              local lowerName = string.lower(cleanName)
              local isOnline = (now_ts - lastSeen <= 60) and (v.status == "Online" or v.online == true)
              if isOnline and lowerName ~= myClean then
                table.insert(candidates, cleanName)
              end
            end
          end
        end
      end
    end
    
    table.sort(candidates)
    
    if #candidates == 0 then
      announce("No other users are currently online. Try again later.")
      return
    end
    
    local displayItems = {}
    for _, name in ipairs(candidates) do
      table.insert(displayItems, "👤 " .. name .. " - Tap to Message")
    end
    
    local builder = AlertDialog.Builder(activity)
    builder.setTitle("➕ New Chat (" .. #candidates .. " Online)")
    builder.setItems(displayItems, DialogInterface.OnClickListener{
      onClick = function(d, w)
        local chosenUser = candidates[w + 1]
        savePrivateContact(chosenUser)
        openPrivateChatScreen(chosenUser)
      end
    })
    builder.setNegativeButton("Cancel", nil)
    builder.show()
  end)
end

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
        text = "💬 Private Lobby";
        textSize = "18sp";
        textColor = "#075E54";
        Typeface = Typeface.DEFAULT_BOLD;
        layout_weight = "1";
      };
      {
        Button;
        id = "btnNewPrivateChat";
        text = "➕ New Chat";
        textSize = "13sp";
        backgroundColor = "#00796B";
        textColor = "#FFFFFF";
        layout_marginRight = "6dp";
        ContentDescription = "Start new private chat with online users button";
      };
      {
        Button;
        id = "btnRefreshUsers";
        text = "🔄 Refresh";
        textSize = "13sp";
        backgroundColor = "#075E54";
        textColor = "#FFFFFF";
        ContentDescription = "Refresh private chats button";
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
  
  if btnNewPrivateChat then
    btnNewPrivateChat.onClick = function()
      showNewChatDialog()
    end
  end
  
  if btnRefreshUsers then
    btnRefreshUsers.onClick = function()
      announce("Refreshing private chats...")
      lastRenderedUsersSignature = ""
      fetchOnlineUsersList()
    end
  end
  
  return view
end

function fetchOnlineUsersList()
  local now_ts = os.time()
  local fbUrl = FIREBASE_URL .. "/data/online_users.json?t=" .. now_ts
  
  Http.get(fbUrl, function(code, content)
    if code == 200 and content and content ~= "null" and content ~= "{}" then
      local data = decodeJSON(content)
      if data and type(data) == "table" then
        local result = {}
        local myClean = string.lower(currentUser.name:gsub("^%s+", ""):gsub("%s+$", ""))
        
        for k, v in pairs(data) do
          if type(v) == "table" then
            local name = v.name or v.username
            local lastSeen = tonumber(v.last_seen or 0) or 0
            if name and type(name) == "string" and name ~= "" then
              local cleanName = name:gsub("^%s+", ""):gsub("%s+$", "")
              local lowerName = string.lower(cleanName)
              local isOnline = (now_ts - lastSeen <= 60) and (v.status == "Online" or v.online == true)
              if isOnline and lowerName ~= myClean then
                table.insert(result, {
                  name = cleanName,
                  status = "Online",
                  last_seen = lastSeen
                })
              end
            end
          end
        end
        
        table.sort(result, function(a, b) return a.name < b.name end)
        onlineUsersList = result
        if activeTab == "private" then
          updatePrivateDirectoryUI()
        end
        return
      end
    end
    
    onlineUsersList = {}
    if activeTab == "private" then
      updatePrivateDirectoryUI()
    end
  end)
end

function updatePrivateDirectoryUI()
  if not listOnlineUsers then return end
  
  -- Merge active online users with saved contact history
  local savedContacts = loadPrivateContacts()
  local mergedMap = {}
  
  for _, u in ipairs(onlineUsersList) do
    if type(u) == "table" and u.name then
      mergedMap[u.name] = { name = u.name, isOnline = true, status = "● Active Now" }
    end
  end
  
  for contactName, _ in pairs(savedContacts) do
    if not mergedMap[contactName] then
      mergedMap[contactName] = { name = contactName, isOnline = false, status = "○ Offline" }
    end
  end
  
  local displayList = {}
  for _, entry in pairs(mergedMap) do
    table.insert(displayList, entry)
  end
  
  table.sort(displayList, function(a, b)
    if a.isOnline ~= b.isOnline then
      return a.isOnline -- Online users first
    end
    return a.name < b.name
  end)
  
  local currentSig = ""
  for _, u in ipairs(displayList) do
    currentSig = currentSig .. ";" .. (u.name or "") .. ":" .. (u.status or "")
  end
  if currentSig == lastRenderedUsersSignature and #displayList > 0 then
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
  for _, u in ipairs(displayList) do
    table.insert(data, { 
      itemName = u.name, 
      itemStatus = u.status
    })
  end
  
  local adapter = LuaAdapter(activity, data, itemLayout)
  listOnlineUsers.setAdapter(adapter)
  
  listOnlineUsers.onItemClick = function(parent, view, position, id)
    local selectedUser = displayList[position + 1].name
    savePrivateContact(selectedUser)
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
          announce("New private message from " .. targetUsername .. ": " .. cleanMessageText(latest.text, latest.isVoice))
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
      local isVoiceMsg = (m.isVoice == true) or (m.audio and m.audio ~= "") or (m.voicePath and m.voicePath ~= "")
      local senderLabel = (string.lower(m.sender) == string.lower(currentUser.name)) and "Me" or (m.sender or targetUsername)
      local textStr = cleanMessageText(m.text, isVoiceMsg)
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
        announce((selectedMsg.sender or "User") .. ": " .. cleanMessageText(selectedMsg.text, selectedMsg.isVoice))
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
          id = "btnRegularLogout";
          text = "🚪 Log Out / Switch Account";
          layout_width = "fill";
          layout_height = "48dp";
          backgroundColor = "#E65100";
          textColor = "#FFFFFF";
          layout_marginBottom = "10dp";
          ContentDescription = "Log Out and switch account button. Double tap to return to login screen.";
        };
        {
          Button;
          id = "btnLogoutAndForget";
          text = "🗑️ Log Out & Wipe Saved Account";
          layout_width = "fill";
          layout_height = "48dp";
          backgroundColor = "#D32F2F";
          textColor = "#FFFFFF";
          ContentDescription = "Log Out and wipe saved credentials button. Double tap to remove account.";
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
  
  if btnRegularLogout then
    btnRegularLogout.onClick = function()
      setPresenceOffline()
      purgeEphemeralAudioFiles()
      currentUser.name = ""
      currentUser.online = false
      isPolling = false
      publicFeedMessages = {}
      privateChatHistory = {}
      groupChatHistory = {}
      announce("Logged out. Returned to login screen.")
      showLoginScreen()
    end
  end
  
  if btnLogoutAndForget then
    btnLogoutAndForget.onClick = function()
      setPresenceOffline()
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
-- BACKGROUND POLLING LOOP (SMART DATA-SAVING ENGINE)
-- --------------------------------------------------------------------
local lastHeartbeatTimestamp = 0

function updateOnlinePresence()
  if not currentUser.online or not currentUser.name or currentUser.name == "" then return end
  pcall(function()
    local cleanUser = currentUser.name:gsub("^%s+", ""):gsub("%s+$", "")
    local userKey = string.lower(cleanUser):gsub("[^%w]", "_")
    local userObj = { name = cleanUser, last_seen = os.time(), status = "Online" }
    local fbUrl = FIREBASE_URL .. "/data/online_users/" .. userKey .. ".json"
    Http.put(fbUrl, encodeJSON(userObj), function() end)
  end)
end

function setPresenceOffline()
  pcall(function()
    if currentUser.name and currentUser.name ~= "" then
      local cleanUser = currentUser.name:gsub("^%s+", ""):gsub("%s+$", "")
      local userKey = string.lower(cleanUser):gsub("[^%w]", "_")
      local fbUrl = FIREBASE_URL .. "/data/online_users/" .. userKey .. ".json"
      Http.delete(fbUrl, function() end)
    end
  end)
end

function startPollingLoop()
  if isPolling then return end
  isPolling = true
  lastHeartbeatTimestamp = 0
  
  local function poll()
    if not currentUser.online or not isPolling then return end
    
    local now_ts = os.time()
    
    -- Send heartbeat only once every 35 seconds (90% reduction in data usage!)
    if now_ts - lastHeartbeatTimestamp >= 35 then
      lastHeartbeatTimestamp = now_ts
      updateOnlinePresence()
    end
    
    -- Smart Data-Saving: Poll ONLY the tab the user is actively viewing!
    if activeTab == "public" then
      fetchPublicFeedMessages()
    elseif activeTab == "group_chat" and activeGroup then
      fetchGroupChatThread(activeGroup.id)
    elseif activeTab == "private_chat" and activeChatTarget ~= "" then
      fetchPrivateChatThread(activeChatTarget)
    elseif activeTab == "private" then
      fetchOnlineUsersList()
    elseif activeTab == "lounge" then
      fetchGroupsList()
    end
    -- On "home", "you", "login", "splash": NO background polling! Saves 100% data!
    
    Handler().postDelayed(Runnable{ run = poll }, 5000)
  end
  
  poll()
end

-- --------------------------------------------------------------------
-- INITIAL ENTRY POINT: STARTUP SPLASH SCREEN & AUTO-UPDATE TEST
-- --------------------------------------------------------------------
showSplashScreen()