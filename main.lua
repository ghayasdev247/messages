-- ====================================================================
-- ACCESSIBLE ANONYMOUS MESSENGER FOR JIESHUO / COMMENTARY SCREEN READER
-- Developed in AndroLua+
-- Version: 1.3.0 (Build Code: 16)
-- Features: WhatsApp Hold-to-Record Voice Button, Single-Tap Audio Playback,
--           Long-Press Context Menu, Ephemeral Storage & Firebase Sync
-- ====================================================================

require "import"
import "android.app.*"
import "android.os.*"
import "android.widget.*"
import "android.view.*"
import "android.graphics.*"
import "android.text.InputType"
import "android.content.Context"

-- --------------------------------------------------------------------
-- CONFIGURATION & GLOBAL STATE
-- --------------------------------------------------------------------
local APP_VERSION = "1.3.0"
local APP_VERSION_CODE = 16

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

local currentUser = { name = "", online = false, githubToken = "" }
local activeScreen = "login" -- "login", "dashboard", "public_feed", "private_directory", "private_chat"
local activeChatTarget = ""
local isPolling = false

local lastPublicMessageCount = 0
local lastPrivateMessageCount = 0
local lastRenderedPublicCount = -1
local lastRenderedPrivateCount = -1
local lastHeartbeatTime = 0

-- Audio Recording Global State
local mediaRecorder = nil
local isRecordingVoice = false
local voiceRecordPath = ""

-- Data Stores (Strictly Ephemeral by Default)
local publicFeedMessages = {}
local onlineUsersList = {}
local privateChatHistory = {}

-- --------------------------------------------------------------------
-- DETERMINISTIC PATH GENERATOR
-- --------------------------------------------------------------------
function getChatFilePath(u1, u2)
  local u1_lower = string.lower(u1)
  local u2_lower = string.lower(u2)
  if u1_lower < u2_lower then
    return "data/chats/" .. u1 .. "_" .. u2 .. ".json"
  else
    return "data/chats/" .. u2 .. "_" .. u1 .. ".json"
  end
end

-- --------------------------------------------------------------------
-- JSON & BASE64 UTILITIES
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

function base64Encode(data)
  return ((data:gsub('.', function(x) 
    local r,b='',x:byte()
    for i=8,1,-1 do r=r..(b%2^i-b%2^(i-1)>0 and '1' or '0') end
    return r
  end)..'0000'):gsub('%d%d%d?%d?%d?', function(x)
    if (#x < 6) then return '' end
    local c=0
    for i=1,6 do c=c+(x:sub(i,i)=='1' and 2^(6-i) or 0) end
    return b64chars:sub(c+1,c+1)
  end)..({ '', '==', '=' })[#data%3+1])
end

function base64Decode(data)
  data = string.gsub(data, '[^'..b64chars..'=]', '')
  return (data:gsub('=', ''):gsub('.', function(x)
    if (x == '=') then return '' end
    local r,f='',(b64chars:find(x)-1)
    for i=6,1,-1 do r=r..(f%2^i-f%2^(i-1)>0 and '1' or '0') end
    return r
  end):gsub('%d%d%d?%d?%d?', function(x)
    if (#x ~= 8) then return '' end
    local c=0
    for i=1,8 do c=c+(x:sub(i,i)=='1' and 2^(8-i) or 0) end
    return string.char(c)
  end))
end

function announce(text)
  pcall(function()
    Toast.makeText(activity, text, Toast.LENGTH_SHORT).show()
    activity.getWindow().getDecorView().announceForAccessibility(text)
  end)
end

-- --------------------------------------------------------------------
-- LOCAL CHAT EXPORTER (Save to Mobile Downloads Folder)
-- --------------------------------------------------------------------
function saveChatLocally(chatType, targetName, messagesList)
  local downloadDir = "/sdcard/Download/Accessible_Messenger_Chats"
  pcall(function()
    import "android.os.Environment"
    local baseDownload = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS).getAbsolutePath()
    downloadDir = baseDownload .. "/Accessible_Messenger_Chats"
  end)
  
  pcall(function()
    local File = luajava.bindClass("java.io.File")
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
        local rawData = base64Decode(resp.content:gsub("\n", ""))
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
          for _, v in pairs(fbData) do
            if type(v) == "table" then
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
        if res and (res.success or res.messages or res.users) then
          callback(true, res.messages or res.users or res)
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
      time = payload.time or os.date("%I:%M %p")
    }
    postFirebaseData("data/public_feed", msgObj, function(fbOk) end)
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
      time = payload.time or os.date("%I:%M %p")
    }
    local filePath = getChatFilePath(msgObj.sender, msgObj.recipient)
    postFirebaseData(filePath, msgObj, function(fbOk) end)
    Http.post(BACKEND_URL .. endpoint, payloadStr, nil, nil, headers, function() end)
    fetchGitHubFile(filePath, function(ok, currentThread)
      local threadToSave = currentThread or {}
      table.insert(threadToSave, msgObj)
      commitGitHubFile(filePath, threadToSave, "Private message to " .. msgObj.recipient, callback)
    end)

  elseif string.find(endpoint, "/api/heartbeat") or string.find(endpoint, "/api/login") then
    local username = payload.username or currentUser.name
    if username and username ~= "" then
      local now_ts = os.time()
      local userObj = { name = username, last_seen = now_ts, status = "Online" }
      postFirebaseData("data/online_users", userObj, function() end)
      Http.post(BACKEND_URL .. endpoint, payloadStr, nil, nil, headers, function() end)
      fetchGitHubFile("data/online_users.json", function(ok, userList)
        local list = userList or {}
        local found = false
        for _, u in ipairs(list) do
          if u.name == username then
            u.last_seen = now_ts
            u.status = "Online"
            found = true
            break
          end
        end
        if not found then
          table.insert(list, userObj)
        end
        commitGitHubFile("data/online_users.json", list, "Presence: " .. username, callback)
      end)
    else
      if callback then callback(false) end
    end
  else
    if callback then callback(false) end
  end
end

-- --------------------------------------------------------------------
-- VOICE NOTE ENGINE & AUDIO PLAYBACK (Single Tap & Base64 Decoder)
-- --------------------------------------------------------------------
function playVoiceNote(audioSource)
  import "android.media.MediaPlayer"
  if not audioSource or audioSource == "" then
    announce("No voice audio file found.")
    return
  end
  
  pcall(function()
    local playPath = audioSource
    -- Handle Base64 encoded audio strings or data URIs
    if string.sub(audioSource, 1, 5) == "data:" or string.len(audioSource) > 200 then
      local cleanB64 = audioSource:gsub("^data:audio/[%w%+]+;base64,", "")
      local decoded = base64Decode(cleanB64)
      playPath = activity.getCacheDir().getAbsolutePath() .. "/temp_voice_play.3gp"
      local f = io.open(playPath, "wb")
      if f then
        f:write(decoded)
        f:close()
      end
    end
    
    local mp = MediaPlayer()
    mp.setDataSource(playPath)
    mp.prepare()
    mp.start()
    announce("Playing voice note...")
  end)
end

function setupHoldToRecordVoiceButton(btnWidget, isPublic, targetName)
  import "android.view.MotionEvent"
  import "android.media.MediaRecorder"
  
  btnWidget.setOnTouchListener(View.OnTouchListener{
    onTouch = function(view, event)
      local action = event.getAction()
      if action == MotionEvent.ACTION_DOWN then
        pcall(function()
          local downloadDir = "/sdcard/Download"
          voiceRecordPath = downloadDir .. "/voice_" .. os.time() .. ".3gp"
          mediaRecorder = MediaRecorder()
          mediaRecorder.setAudioSource(MediaRecorder.AudioSource.MIC)
          mediaRecorder.setOutputFormat(MediaRecorder.OutputFormat.THREE_GPP)
          mediaRecorder.setAudioEncoder(MediaRecorder.AudioEncoder.AMR_NB)
          mediaRecorder.setOutputFile(voiceRecordPath)
          mediaRecorder.prepare()
          mediaRecorder.start()
          isRecordingVoice = true
          announce("Recording voice note. Release button to send.")
        end)
        return true
      elseif action == MotionEvent.ACTION_UP or action == MotionEvent.ACTION_CANCEL then
        if isRecordingVoice then
          pcall(function()
            if mediaRecorder then
              mediaRecorder.stop()
              mediaRecorder.release()
              mediaRecorder = nil
            end
            isRecordingVoice = false
            
            local b64Audio = ""
            local f = io.open(voiceRecordPath, "rb")
            if f then
              local bytes = f:read("*a")
              f:close()
              b64Audio = base64Encode(bytes)
            end
            
            local msgObj = {
              sender = currentUser.name,
              recipient = targetName,
              text = "🎤 Voice Message 🔊",
              isVoice = true,
              audio = b64Audio,
              voicePath = voiceRecordPath,
              time = os.date("%I:%M %p")
            }
            
            if isPublic then
              apiPost("/api/public-feed", msgObj, function() fetchPublicFeedMessages() end)
            else
              apiPost("/api/private-messages", msgObj, function() fetchPrivateChatThread(targetName) end)
            end
            announce("Voice message sent!")
          end)
        end
        return true
      end
      return false
    end
  })
end

-- --------------------------------------------------------------------
-- LONG-PRESS-ONLY MESSAGE OPTIONS MODAL
-- --------------------------------------------------------------------
function showMessageOptionsDialog(msgItem, msgIndex, isPublic, targetName)
  local options = { "❤️ React with Emoji", "↩️ Reply to Message", "📌 Pin Message", "🗑️ Delete Message" }

  local builder = AlertDialog.Builder(activity)
  builder.setTitle("Message Options")
  builder.setItems(options, function(dialog, which)
    local selectedOption = options[which + 1]
    
    if string.find(selectedOption, "React") then
      showEmojiReactionDialog(msgItem, msgIndex, isPublic, targetName)
    elseif string.find(selectedOption, "Reply") then
      local replyPrefix = string.format("Replying to %s: \"%s\"\n---\n", msgItem.sender or "User", msgItem.text or "")
      if isPublic then
        editPublicMessageInput.setText(replyPrefix)
        editPublicMessageInput.setSelection(#replyPrefix)
      else
        editMessageInput.setText(replyPrefix)
        editMessageInput.setSelection(#replyPrefix)
      end
      announce("Replying to message from " .. (msgItem.sender or "User"))
    elseif string.find(selectedOption, "Pin") then
      local pinnedText = string.format("📌 Pinned [%s]: %s", msgItem.sender or "User", msgItem.text or "")
      announce("Pinned message: " .. (msgItem.text or ""))
      Toast.makeText(activity, pinnedText, Toast.LENGTH_LONG).show()
    elseif string.find(selectedOption, "Delete") then
      if isPublic then
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
  end)
  builder.show()
end

function showEmojiReactionDialog(msgItem, msgIndex, isPublic, targetName)
  local emojis = { "👍 Like", "❤️ Love", "😂 Laugh", "😮 Wow", "😢 Sad", "🔥 Fire" }
  local emojiCodes = { "👍", "❤️", "😂", "😮", "😢", "🔥" }
  
  local builder = AlertDialog.Builder(activity)
  builder.setTitle("Choose Reaction")
  builder.setItems(emojis, function(dialog, which)
    local chosenEmoji = emojiCodes[which + 1]
    msgItem.reaction = chosenEmoji
    if isPublic then
      updatePublicFeedUI()
    else
      updatePrivateChatUI(targetName)
    end
    announce("Reacted with " .. emojis[which + 1] .. " to message")
  end)
  builder.show()
end

-- --------------------------------------------------------------------
-- 1. WHATSAPP & MESSENGER STYLED LOGIN SCREEN
-- --------------------------------------------------------------------
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
    layout_marginBottom = "25dp";
    ContentDescription = "Subtitle: Anonymous Cloud Login version " .. APP_VERSION;
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
    ContentDescription = "Username edit box. Type your desired alias here.";
  };
  {
    TextView;
    text = "Step 2: Enter Password";
    textSize = "15sp";
    textColor = "#222222";
    layout_marginTop = "14dp";
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
    ContentDescription = "Password edit box. Type your password here.";
  };
  {
    Button;
    id = "btnLogin";
    text = "Connect to Messenger";
    layout_width = "fill";
    layout_height = "55dp";
    layout_marginTop = "25dp";
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
    layout_marginTop = "14dp";
    backgroundColor = "#455A64";
    textColor = "#FFFFFF";
    textSize = "14sp";
    ContentDescription = "Check for Auto Updates button. Double tap to check for updates.";
  };
}

-- --------------------------------------------------------------------
-- 2. HOMEPAGE / DASHBOARD LAYOUT
-- --------------------------------------------------------------------
local dashboardLayout = {
  LinearLayout;
  orientation = "vertical";
  layout_width = "fill";
  layout_height = "fill";
  padding = "20dp";
  backgroundColor = "#FFFFFF";
  {
    TextView;
    id = "txtDashboardHeader";
    text = "Messenger Main Home";
    textSize = "24sp";
    textColor = "#075E54";
    layout_gravity = "center";
    layout_marginBottom = "5dp";
    ContentDescription = "Messenger Main Home Screen Header";
  };
  {
    TextView;
    id = "txtLoggedAs";
    text = "Status: Connected (v" .. APP_VERSION .. ")";
    textSize = "15sp";
    textColor = "#2E7D32";
    layout_gravity = "center";
    layout_marginBottom = "25dp";
    ContentDescription = "Status indicator: Connected.";
  };
  {
    Button;
    id = "btnOpenPublicFeed";
    text = "🌐 Public Feed";
    layout_width = "fill";
    layout_height = "65dp";
    layout_marginBottom = "15dp";
    backgroundColor = "#128C7E";
    textColor = "#FFFFFF";
    textSize = "18sp";
    ContentDescription = "Public Feed button. Double tap to view or send public messages.";
  };
  {
    Button;
    id = "btnOpenPrivateChats";
    text = "💬 Private Chats (Online Users Only)";
    layout_width = "fill";
    layout_height = "65dp";
    layout_marginBottom = "15dp";
    backgroundColor = "#075E54";
    textColor = "#FFFFFF";
    textSize = "18sp";
    ContentDescription = "Private Chats button. Double tap to view currently active online users.";
  };
  {
    Button;
    id = "btnCheckUpdateHome";
    text = "🔄 Check for Updates";
    layout_width = "fill";
    layout_height = "50dp";
    layout_marginBottom = "15dp";
    backgroundColor = "#455A64";
    textColor = "#FFFFFF";
    textSize = "15sp";
    ContentDescription = "Check for Updates button. Double tap to check for updates.";
  };
  {
    Button;
    id = "btnLogout";
    text = "Disconnect / Logout";
    layout_width = "fill";
    layout_height = "50dp";
    backgroundColor = "#D32F2F";
    textColor = "#FFFFFF";
    textSize = "16sp";
    ContentDescription = "Disconnect button. Double tap to log out.";
  };
}

-- --------------------------------------------------------------------
-- 3. PUBLIC FEED SCREEN LAYOUT (WHATSAPP HOLD-TO-RECORD BUTTON)
-- --------------------------------------------------------------------
local publicFeedLayout = {
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
      id = "btnPublicToHome";
      text = "< Home";
      textColor = "#FFFFFF";
      backgroundColor = "#075E54";
      ContentDescription = "Back to home dashboard button";
    };
    {
      TextView;
      text = "Public Feed";
      textSize = "18sp";
      textColor = "#FFFFFF";
      layout_marginLeft = "8dp";
      layout_weight = "1";
      ContentDescription = "Public Feed room.";
    };
    {
      Button;
      id = "btnSavePublicChatLocal";
      text = "📥 Save";
      textColor = "#FFFFFF";
      backgroundColor = "#128C7E";
      ContentDescription = "Save Public Chat Locally button";
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
      ContentDescription = "Public message text field.";
    };
    {
      Button;
      id = "btnSendPublicMessage";
      text = "Post";
      backgroundColor = "#075E54";
      textColor = "#FFFFFF";
      layout_marginLeft = "4dp";
      ContentDescription = "Post public message button";
    };
    {
      Button;
      id = "btnRecordPublicVoice";
      text = "🎙️";
      backgroundColor = "#075E54";
      textColor = "#FFFFFF";
      textSize = "20sp";
      layout_width = "50dp";
      layout_height = "50dp";
      layout_marginLeft = "6dp";
      ContentDescription = "Hold to record voice note, release to send";
    };
  };
}

-- --------------------------------------------------------------------
-- 4. PRIVATE CHATS DIRECTORY LAYOUT (ONLINE USERS ONLY)
-- --------------------------------------------------------------------
local privateDirectoryLayout = {
  LinearLayout;
  orientation = "vertical";
  layout_width = "fill";
  layout_height = "fill";
  padding = "16dp";
  backgroundColor = "#FFFFFF";
  {
    LinearLayout;
    orientation = "horizontal";
    layout_width = "fill";
    gravity = "center_vertical";
    layout_marginBottom = "10dp";
    {
      Button;
      id = "btnPrivateToHome";
      text = "< Home";
      ContentDescription = "Back to main homepage";
    };
    {
      TextView;
      text = "Active Online Users";
      textSize = "18sp";
      textColor = "#075E54";
      layout_marginLeft = "10dp";
      layout_weight = "1";
      ContentDescription = "Currently Active Online Users directory.";
    };
    {
      Button;
      id = "btnRefreshUsers";
      text = "Refresh";
      ContentDescription = "Refresh online users directory button";
    };
  };
  {
    ListView;
    id = "listOnlineUsers";
    layout_width = "fill";
    layout_height = "fill";
    dividerHeight = "2dp";
  };
}

-- --------------------------------------------------------------------
-- 5. PRIVATE CHAT ROOM LAYOUT (WHATSAPP LOWER RIGHT VOICE BUTTON)
-- --------------------------------------------------------------------
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
      text = "< Directory";
      textColor = "#FFFFFF";
      backgroundColor = "#075E54";
      ContentDescription = "Back to private chats directory";
    };
    {
      TextView;
      id = "txtChatTargetHeader";
      text = "Private Chat";
      textSize = "18sp";
      textColor = "#FFFFFF";
      layout_marginLeft = "8dp";
      layout_weight = "1";
      ContentDescription = "Currently chatting in private room.";
    };
    {
      Button;
      id = "btnSavePrivateChatLocal";
      text = "📥 Save";
      textColor = "#FFFFFF";
      backgroundColor = "#128C7E";
      ContentDescription = "Save Private Chat Locally button";
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
      ContentDescription = "Private message text field.";
    };
    {
      Button;
      id = "btnSendMessage";
      text = "Send";
      backgroundColor = "#075E54";
      textColor = "#FFFFFF";
      layout_marginLeft = "4dp";
      ContentDescription = "Send private message button";
    };
    {
      Button;
      id = "btnRecordPrivateVoice";
      text = "🎙️";
      backgroundColor = "#075E54";
      textColor = "#FFFFFF";
      textSize = "20sp";
      layout_width = "50dp";
      layout_height = "50dp";
      layout_marginLeft = "6dp";
      ContentDescription = "Hold to record voice note, release to send";
    };
  };
}

-- --------------------------------------------------------------------
-- SCREEN CONTROLLERS
-- --------------------------------------------------------------------

function showLoginScreen()
  activeScreen = "login"
  isPolling = false
  activity.setContentView(loadlayout(loginLayout))
  
  btnCheckUpdate.onClick = function()
    checkForRemoteUpdates(true)
  end
  
  btnLogin.onClick = function()
    local name = editUsername.getText().toString()
    local pass = editPassword.getText().toString()
    
    if name == "" or pass == "" then
      announce("Error: Please enter both a username and password.")
      return
    end
    
    announce("Connecting to messenger...")
    
    apiPost("/api/login", { username = name, password = pass }, function(success)
      currentUser.name = name
      currentUser.online = true
      announce("Connected as " .. name .. ". Welcome to Homepage.")
      showDashboardScreen()
      startPollingLoop()
    end)
  end
end

function showDashboardScreen()
  activeScreen = "dashboard"
  activity.setContentView(loadlayout(dashboardLayout))
  
  txtLoggedAs.setText("Logged in as: " .. currentUser.name .. " (v" .. APP_VERSION .. ")")
  txtLoggedAs.setContentDescription("Logged in as " .. currentUser.name)
  
  btnOpenPublicFeed.onClick = function()
    announce("Opening Public Feed")
    showPublicFeedScreen()
  end
  
  btnOpenPrivateChats.onClick = function()
    announce("Opening Active Online Users Directory")
    showPrivateDirectoryScreen()
  end
  
  btnCheckUpdateHome.onClick = function()
    checkForRemoteUpdates(true)
  end
  
  btnLogout.onClick = function()
    -- Strict Ephemeral Reset: Clear memory feeds on logout
    currentUser.name = ""
    currentUser.online = false
    isPolling = false
    publicFeedMessages = {}
    privateChatHistory = {}
    announce("Disconnected from messenger.")
    showLoginScreen()
  end
end

-- --------------------------------------------------------------------
-- PUBLIC FEED CONTROLLER
-- --------------------------------------------------------------------
function showPublicFeedScreen()
  activeScreen = "public_feed"
  lastRenderedPublicCount = -1
  activity.setContentView(loadlayout(publicFeedLayout))
  
  btnPublicToHome.onClick = function()
    announce("Returning to Home Dashboard")
    showDashboardScreen()
  end
  
  btnSavePublicChatLocal.onClick = function()
    saveChatLocally("PublicFeed", "Global", publicFeedMessages)
  end
  
  setupHoldToRecordVoiceButton(btnRecordPublicVoice, true, "")
  
  fetchPublicFeedMessages()
  
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
    
    apiPost("/api/public-feed", payload, function(success)
      fetchPublicFeedMessages()
    end)
  end
end

function fetchPublicFeedMessages()
  apiGet("/api/public-feed", "data/public_feed.json", function(success, data)
    if success and data and type(data) == "table" then
      local newCount = #data
      if newCount > lastPublicMessageCount and lastPublicMessageCount > 0 then
        local latest = data[newCount]
        if latest and type(latest) == "table" and latest.sender ~= currentUser.name then
          announce("New public message from " .. (latest.sender or "User") .. ": " .. (latest.text or ""))
        end
      end
      lastPublicMessageCount = newCount
      publicFeedMessages = data
      
      if activeScreen == "public_feed" and lastRenderedPublicCount ~= newCount then
        lastRenderedPublicCount = newCount
        updatePublicFeedUI()
      end
    end
  end)
end

function updatePublicFeedUI()
  -- Jieshuo Max 100% Safe Card UI (No textStyle or layout_margin attributes)
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
  if type(publicFeedMessages) == "table" then
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
  end
  
  local adapter = LuaAdapter(activity, data, chatItemLayout)
  listPublicMessages.setAdapter(adapter)
  
  -- SINGLE TAP: Immediate Voice Note Audio Playback / Speech Read
  listPublicMessages.onItemClick = function(parent, view, position, id)
    local idx = position + 1
    local selectedMsg = publicFeedMessages[idx]
    if selectedMsg then
      if selectedMsg.isVoice or selectedMsg.audio or selectedMsg.voicePath then
        playVoiceNote(selectedMsg.audio or selectedMsg.voicePath)
      else
        announce((selectedMsg.sender or "User") .. ": " .. (selectedMsg.text or ""))
      end
    end
  end
  
  -- LONG PRESS ONLY: Open Context Options Modal (React, Reply, Pin, Delete)
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
-- PRIVATE CHATS DIRECTORY CONTROLLER (ONLINE USERS ONLY)
-- --------------------------------------------------------------------
function showPrivateDirectoryScreen()
  activeScreen = "private_directory"
  activity.setContentView(loadlayout(privateDirectoryLayout))
  
  btnPrivateToHome.onClick = function()
    announce("Returning to Home Dashboard")
    showDashboardScreen()
  end
  
  fetchOnlineUsersList()
  
  btnRefreshUsers.onClick = function()
    announce("Refreshing active online users directory...")
    fetchOnlineUsersList()
  end
end

function fetchOnlineUsersList()
  apiGet("/api/online-users?user=" .. currentUser.name, "data/online_users.json", function(success, data)
    if success and data and type(data) == "table" then
      local filtered = {}
      local now_ts = os.time()
      for _, u in ipairs(data) do
        if type(u) == "table" then
          local name = u.name or u.username
          local lastSeen = tonumber(u.last_seen or 0) or 0
          local isOnline = u.status == "Online" or u.online == true or (now_ts - lastSeen <= 70)
          
          -- STRICT FILTER: Show ONLY currently active online users (Hide offline users)
          if name and name ~= currentUser.name and isOnline then
            table.insert(filtered, {
              name = name,
              status = "Online"
            })
          end
        end
      end
      onlineUsersList = filtered
      if activeScreen == "private_directory" then
        updatePrivateDirectoryUI()
      end
    end
  end)
end

function updatePrivateDirectoryUI()
  local itemLayout = {
    LinearLayout;
    orientation = "horizontal";
    layout_width = "fill";
    padding = "16dp";
    gravity = "center_vertical";
    {
      TextView;
      id = "itemName";
      textSize = "18sp";
      textColor = "#000000";
      layout_weight = "1";
    };
    {
      TextView;
      id = "itemStatus";
      textSize = "14sp";
      textColor = "#388E3C";
    };
  }
  
  local data = {}
  if type(onlineUsersList) == "table" then
    for _, u in ipairs(onlineUsersList) do
      if type(u) == "table" then
        table.insert(data, { 
          itemName = u.name or "User", 
          itemStatus = "● Online"
        })
      end
    end
  end
  
  local adapter = LuaAdapter(activity, data, itemLayout)
  listOnlineUsers.setAdapter(adapter)
  
  listOnlineUsers.onItemClick = function(parent, view, position, id)
    local selectedUser = onlineUsersList[position + 1].name
    announce("Opening private chat with " .. selectedUser)
    showPrivateChatScreen(selectedUser)
  end
end

-- --------------------------------------------------------------------
-- PRIVATE CHAT ROOM CONTROLLER
-- --------------------------------------------------------------------
function showPrivateChatScreen(targetUsername)
  activeScreen = "private_chat"
  activeChatTarget = targetUsername
  lastPrivateMessageCount = 0
  lastRenderedPrivateCount = -1
  activity.setContentView(loadlayout(chatLayout))
  
  txtChatTargetHeader.setText("Chat: " .. targetUsername)
  txtChatTargetHeader.setContentDescription("Currently chatting in private room with " .. targetUsername)
  
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
    
    apiPost("/api/private-messages", payload, function(success)
      fetchPrivateChatThread(targetUsername)
    end)
  end
  
  btnBackToPrivateList.onClick = function()
    activeChatTarget = ""
    announce("Returning to active online users directory")
    showPrivateDirectoryScreen()
  end
end

function fetchPrivateChatThread(targetUsername)
  local chatPath = getChatFilePath(currentUser.name, targetUsername)
  local endpoint = "/api/private-messages?user=" .. currentUser.name .. "&target=" .. targetUsername
  
  apiGet(endpoint, chatPath, function(success, data)
    if success and data and type(data) == "table" then
      local newCount = #data
      if newCount > lastPrivateMessageCount and lastPrivateMessageCount > 0 then
        local latest = data[newCount]
        if latest and type(latest) == "table" and latest.sender == targetUsername then
          announce("New private message from " .. targetUsername .. ": " .. (latest.text or ""))
        end
      end
      lastPrivateMessageCount = newCount
      privateChatHistory[targetUsername] = data
      
      if activeScreen == "private_chat" and activeChatTarget == targetUsername and lastRenderedPrivateCount ~= newCount then
        lastRenderedPrivateCount = newCount
        updatePrivateChatUI(targetUsername)
      end
    end
  end)
end

function updatePrivateChatUI(targetUsername)
  -- Jieshuo Max 100% Safe Card UI (No textStyle or layout_margin attributes)
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
        textSize = "13sp";
        textColor = "#075E54";
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
  if type(msgs) == "table" then
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
  end
  
  local adapter = LuaAdapter(activity, data, chatItemLayout)
  listChatMessages.setAdapter(adapter)
  
  -- SINGLE TAP: Immediate Voice Note Audio Playback / Speech Read
  listChatMessages.onItemClick = function(parent, view, position, id)
    local idx = position + 1
    local selectedMsg = msgs[idx]
    if selectedMsg then
      if selectedMsg.isVoice or selectedMsg.audio or selectedMsg.voicePath then
        playVoiceNote(selectedMsg.audio or selectedMsg.voicePath)
      else
        announce((selectedMsg.sender or "User") .. ": " .. (selectedMsg.text or ""))
      end
    end
  end
  
  -- LONG PRESS ONLY: Open Context Options Modal (React, Reply, Pin, Delete)
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
    
    if activeScreen == "public_feed" then
      fetchPublicFeedMessages()
    elseif activeScreen == "private_directory" then
      fetchOnlineUsersList()
    elseif activeScreen == "private_chat" and activeChatTarget ~= "" then
      fetchPrivateChatThread(activeChatTarget)
    end
    
    Handler().postDelayed(Runnable{ run = poll }, 2500)
  end
  
  poll()
end

-- --------------------------------------------------------------------
-- INITIAL ENTRY POINT
-- --------------------------------------------------------------------
showLoginScreen()