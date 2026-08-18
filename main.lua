-- ====================================================================
-- ACCESSIBLE ANONYMOUS MESSENGER FOR JIESHUO / COMMENTARY SCREEN READER
-- Developed in AndroLua+
-- Version: 1.0.7 (Build Code: 8)
-- Features: Public Feed, Deterministic Private Chats, Card UI, Mobile Downloads Updates
-- Networking: Local Wi-Fi REST API with Automatic GitHub Serverless Fallback
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
local APP_VERSION = "1.0.7"
local APP_VERSION_CODE = 8

local VERSION_MANIFEST_URL = "https://raw.githubusercontent.com/ghayasdev247/messages/main/data/version.json"
local LUA_UPDATE_URL = "https://raw.githubusercontent.com/ghayasdev247/messages/main/main.lua"
local XPK_UPDATE_URL = "https://raw.githubusercontent.com/ghayasdev247/messages/main/Chatify%20Accessible%20Messenger%20for%20the%20Blind_Updated.xpk"

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

-- Data Stores
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
-- STORAGE & REMOTE UPDATE ENGINE (Saved to Mobile Downloads folder)
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
  local savedSuccess = false
  
  pcall(function()
    local file = io.open(savePath, "w")
    if file then
      file:write(uContent)
      file:close()
      savedSuccess = true
    end
  end)
  
  if not savedSuccess then
    savePath = activity.getFilesDir().getAbsolutePath() .. "/" .. fileName
    pcall(function()
      local file = io.open(savePath, "w")
      if file then
        file:write(uContent)
        file:close()
      end
    end)
  end
  
  announce("The update is successful. Re-import the plugin to continue. Saved to Download folder: " .. fileName)
end

-- --------------------------------------------------------------------
-- UNIFIED NETWORKING ENGINE (Local API + GitHub Fallback)
-- --------------------------------------------------------------------
function apiGet(endpoint, githubFilePath, callback)
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
end

function apiPost(endpoint, payload, callback)
  local payloadStr = encodeJSON(payload)
  local headers = {}
  headers["Content-Type"] = "application/json"

  Http.post(BACKEND_URL .. endpoint, payloadStr, nil, nil, headers, function(code, content)
    if code == 200 or code == 201 then
      if callback then callback(true) end
    else
      Http.post(BACKEND_URL .. endpoint, payloadStr, function(c2, cnt2)
        if c2 == 200 or c2 == 201 then
          if callback then callback(true) end
        else
          -- GITHUB SERVERLESS FALLBACK FOR OFFLINE / REMOTE CONNECTIONS
          if string.find(endpoint, "/api/public%-feed") then
            local msgObj = {
              sender = payload.sender or currentUser.name,
              text = payload.text,
              time = payload.time or os.date("%I:%M %p")
            }
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
              time = payload.time or os.date("%I:%M %p")
            }
            local filePath = getChatFilePath(msgObj.sender, msgObj.recipient)
            fetchGitHubFile(filePath, function(ok, currentThread)
              local threadToSave = currentThread or {}
              table.insert(threadToSave, msgObj)
              commitGitHubFile(filePath, threadToSave, "Private message to " .. msgObj.recipient, callback)
            end)

          elseif string.find(endpoint, "/api/heartbeat") or string.find(endpoint, "/api/login") then
            local username = payload.username or currentUser.name
            if username and username ~= "" then
              fetchGitHubFile("data/online_users.json", function(ok, userList)
                local list = userList or {}
                local found = false
                local now_ts = os.time()
                for _, u in ipairs(list) do
                  if u.name == username then
                    u.last_seen = now_ts
                    u.status = "Online"
                    found = true
                    break
                  end
                end
                if not found then
                  table.insert(list, { name = username, last_seen = now_ts, status = "Online" })
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
      end)
    end
  end)
end

-- --------------------------------------------------------------------
-- 1. LOGIN / IDENTITY SCREEN LAYOUT
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
    textSize = "24sp";
    textColor = "#1565C0";
    layout_gravity = "center";
    padding = "10dp";
    ContentDescription = "Accessible Messenger Application Header";
  };
  {
    TextView;
    text = "Anonymous Login (v" .. APP_VERSION .. ")";
    textSize = "15sp";
    textColor = "#555555";
    layout_gravity = "center";
    layout_marginBottom = "20dp";
    ContentDescription = "Subtitle: Anonymous Login version " .. APP_VERSION;
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
    padding = "12dp";
    backgroundColor = "#FFFFFF";
    ContentDescription = "Username edit box. Type your desired alias here.";
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
    padding = "12dp";
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
    backgroundColor = "#1565C0";
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
    layout_marginTop = "12dp";
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
    textColor = "#1565C0";
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
    backgroundColor = "#0288D1";
    textColor = "#FFFFFF";
    textSize = "18sp";
    ContentDescription = "Public Feed button. Double tap to view or send public messages.";
  };
  {
    Button;
    id = "btnOpenPrivateChats";
    text = "💬 Private Chats & Online Users";
    layout_width = "fill";
    layout_height = "65dp";
    layout_marginBottom = "15dp";
    backgroundColor = "#2E7D32";
    textColor = "#FFFFFF";
    textSize = "18sp";
    ContentDescription = "Private Chats button. Double tap to view online users and chat privately.";
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
-- 3. PUBLIC FEED SCREEN LAYOUT
-- --------------------------------------------------------------------
local publicFeedLayout = {
  LinearLayout;
  orientation = "vertical";
  layout_width = "fill";
  layout_height = "fill";
  padding = "12dp";
  backgroundColor = "#EBF2F7";
  {
    LinearLayout;
    orientation = "horizontal";
    layout_width = "fill";
    gravity = "center_vertical";
    padding = "10dp";
    backgroundColor = "#0288D1";
    {
      Button;
      id = "btnPublicToHome";
      text = "< Home";
      textColor = "#FFFFFF";
      backgroundColor = "#0288D1";
      ContentDescription = "Back to home dashboard button";
    };
    {
      TextView;
      text = "Public Feed";
      textSize = "20sp";
      textColor = "#FFFFFF";
      layout_marginLeft = "15dp";
      layout_weight = "1";
      ContentDescription = "Public Feed room.";
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
    {
      EditText;
      id = "editPublicMessageInput";
      hint = "Type public message...";
      layout_weight = "1";
      textSize = "16sp";
      padding = "12dp";
      backgroundColor = "#FFFFFF";
      ContentDescription = "Public message text field. Type message to post publicly.";
    };
    {
      Button;
      id = "btnSendPublicMessage";
      text = "Post";
      backgroundColor = "#0288D1";
      textColor = "#FFFFFF";
      layout_marginLeft = "8dp";
      ContentDescription = "Post public message button. Double tap to publish.";
    };
  };
}

-- --------------------------------------------------------------------
-- 4. PRIVATE CHATS DIRECTORY LAYOUT
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
      text = "Private Conversations";
      textSize = "18sp";
      textColor = "#111111";
      layout_marginLeft = "10dp";
      layout_weight = "1";
      ContentDescription = "Private Conversations directory. Select an online user to chat with.";
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
-- 5. PRIVATE CHAT ROOM LAYOUT
-- --------------------------------------------------------------------
local chatLayout = {
  LinearLayout;
  orientation = "vertical";
  layout_width = "fill";
  layout_height = "fill";
  padding = "12dp";
  backgroundColor = "#EBF2F7";
  {
    LinearLayout;
    orientation = "horizontal";
    layout_width = "fill";
    gravity = "center_vertical";
    padding = "10dp";
    backgroundColor = "#37474F";
    {
      Button;
      id = "btnBackToPrivateList";
      text = "< Directory";
      textColor = "#FFFFFF";
      backgroundColor = "#37474F";
      ContentDescription = "Back to private chats directory";
    };
    {
      TextView;
      id = "txtChatTargetHeader";
      text = "Private Chat";
      textSize = "18sp";
      textColor = "#FFFFFF";
      layout_marginLeft = "15dp";
      layout_weight = "1";
      ContentDescription = "Currently chatting in private room.";
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
    {
      EditText;
      id = "editMessageInput";
      hint = "Type private message...";
      layout_weight = "1";
      textSize = "16sp";
      padding = "12dp";
      backgroundColor = "#FFFFFF";
      ContentDescription = "Private message text field. Type your message here.";
    };
    {
      Button;
      id = "btnSendMessage";
      text = "Send";
      backgroundColor = "#2E7D32";
      textColor = "#FFFFFF";
      layout_marginLeft = "8dp";
      ContentDescription = "Send private message button. Double tap to send.";
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
    announce("Opening Private Chats Directory")
    showPrivateDirectoryScreen()
  end
  
  btnCheckUpdateHome.onClick = function()
    checkForRemoteUpdates(true)
  end
  
  btnLogout.onClick = function()
    currentUser.name = ""
    currentUser.online = false
    isPolling = false
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
    if success and data then
      local newCount = #data
      if newCount > lastPublicMessageCount and lastPublicMessageCount > 0 then
        local latest = data[newCount]
        if latest and latest.sender ~= currentUser.name then
          announce("New public message from " .. latest.sender .. ": " .. latest.text)
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
  -- Fixed layout for LuaAdapter inside ListView (No layout_marginBottom on root view to prevent AbsListView setMargins crash)
  local chatItemLayout = {
    LinearLayout;
    orientation = "vertical";
    layout_width = "fill";
    padding = "10dp";
    backgroundColor = "#FFFFFF";
    {
      LinearLayout;
      orientation = "horizontal";
      layout_width = "fill";
      {
        TextView;
        id = "msgSender";
        textSize = "13sp";
        textColor = "#0288D1";
        textStyle = "bold";
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
      layout_marginTop = "4dp";
    };
  }
  
  local data = {}
  for _, m in ipairs(publicFeedMessages) do
    table.insert(data, {
      msgSender = m.sender,
      msgTime = m.time or "",
      msgText = m.text
    })
  end
  
  local adapter = LuaAdapter(activity, data, chatItemLayout)
  listPublicMessages.setAdapter(adapter)
end

-- --------------------------------------------------------------------
-- PRIVATE CHATS DIRECTORY CONTROLLER
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
    announce("Refreshing online users directory...")
    fetchOnlineUsersList()
  end
end

function fetchOnlineUsersList()
  apiGet("/api/online-users?user=" .. currentUser.name, "data/online_users.json", function(success, data)
    if success and data then
      local filtered = {}
      for _, u in ipairs(data) do
        local name = u.name or u.username
        if name and name ~= currentUser.name then
          local statusText = u.status or (u.online and "Online" or "Offline")
          table.insert(filtered, {
            name = name,
            status = statusText
          })
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
  for _, u in ipairs(onlineUsersList) do
    table.insert(data, { 
      itemName = u.name, 
      itemStatus = "● " .. u.status 
    })
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
  
  txtChatTargetHeader.setText("Private: " .. targetUsername)
  txtChatTargetHeader.setContentDescription("Currently in private chat with " .. targetUsername)
  
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
    announce("Returning to private chats directory")
    showPrivateDirectoryScreen()
  end
end

function fetchPrivateChatThread(targetUsername)
  local chatPath = getChatFilePath(currentUser.name, targetUsername)
  local endpoint = "/api/private-messages?user=" .. currentUser.name .. "&target=" .. targetUsername
  
  apiGet(endpoint, chatPath, function(success, data)
    if success and data then
      local newCount = #data
      if newCount > lastPrivateMessageCount and lastPrivateMessageCount > 0 then
        local latest = data[newCount]
        if latest and latest.sender == targetUsername then
          announce("New private message from " .. targetUsername .. ": " .. latest.text)
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
  -- Fixed layout for LuaAdapter inside ListView (No layout_marginBottom on root view to prevent AbsListView setMargins crash)
  local chatItemLayout = {
    LinearLayout;
    orientation = "vertical";
    layout_width = "fill";
    padding = "10dp";
    backgroundColor = "#FFFFFF";
    {
      LinearLayout;
      orientation = "horizontal";
      layout_width = "fill";
      {
        TextView;
        id = "msgSender";
        textSize = "12sp";
        textColor = "#757575";
        textStyle = "bold";
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
      layout_marginTop = "4dp";
    };
  }
  
  local data = {}
  local msgs = privateChatHistory[targetUsername] or {}
  for _, m in ipairs(msgs) do
    local senderLabel = (m.sender == currentUser.name) and "Me" or m.sender
    table.insert(data, {
      msgSender = senderLabel,
      msgTime = m.time or "",
      msgText = m.text
    })
  end
  
  local adapter = LuaAdapter(activity, data, chatItemLayout)
  listChatMessages.setAdapter(adapter)
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