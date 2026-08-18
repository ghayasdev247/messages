-- ====================================================================
-- ACCESSIBLE ANONYMOUS MESSENGER FOR JIESHUO / COMMENTARY SCREEN READER
-- Developed in AndroLua+
-- Features: Stable Screen Reader Focus, Public Feed, Private Messaging, Modern UI Layout
-- Backend: Unified Cross-Device Real-Time Sync & Dual Network Auto-Updates (Local Wi-Fi + GitHub)
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
local APP_VERSION = "1.0.1"
local APP_VERSION_CODE = 2

local VERSION_MANIFEST_URL = "https://raw.githubusercontent.com/ghayasdev247/messages/main/data/version.json"
local LUA_UPDATE_URL = "https://raw.githubusercontent.com/ghayasdev247/messages/main/main.lua"

-- Local PC Wi-Fi Server IP
local BACKEND_URL = "http://10.190.183.148:5000"

local GITHUB_OWNER = "ghayasdev247"
local GITHUB_REPO = "messages"
local GITHUB_BRANCH = "main"

local currentUser = { name = "", online = false, githubToken = "" }
local activeScreen = "login" -- "login", "dashboard", "public_feed", "private_directory", "private_chat"
local activeChatTarget = ""
local pollingHandler = nil
local isPolling = false

local lastPublicMessageCount = 0
local lastPrivateMessageCount = 0
local lastRenderedPublicCount = -1
local lastRenderedPrivateCount = -1
local lastHeartbeatTime = 0

-- Data Stores
local publicFeedMessages = {}
local onlineUsersList = {}
local privateChatHistory = {} -- Keyed by target username

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
-- JSON UTILITIES
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

function encodeJSON(tbl)
  if jsonModule and jsonModule.encode then
    local ok, res = pcall(jsonModule.encode, tbl)
    if ok then return res end
  end
  local parts = {}
  for k, v in pairs(tbl) do
    if type(v) == "string" then
      table.insert(parts, string.format("%q:%q", tostring(k), tostring(v)))
    elseif type(v) == "number" or type(v) == "boolean" then
      table.insert(parts, string.format("%q:%s", tostring(k), tostring(v)))
    end
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

-- Helper function for Screen Reader Announcements (Jieshuo)
function announce(text)
  pcall(function()
    Toast.makeText(activity, text, Toast.LENGTH_SHORT).show()
    activity.getWindow().getDecorView().announceForAccessibility(text)
  end)
end

-- --------------------------------------------------------------------
-- DUAL NETWORK AUTO-UPDATE ENGINE (Local Wi-Fi + GitHub Remote)
-- --------------------------------------------------------------------
function checkForRemoteUpdates(manualCheck)
  if manualCheck then
    announce("Checking for updates on Local Wi-Fi Network & GitHub...")
  end
  
  Http.get(BACKEND_URL .. "/api/version", function(lCode, lContent)
    if lCode == 200 then
      local manifest = decodeJSON(lContent)
      if manifest and manifest.version_code then
        local remoteCode = tonumber(manifest.version_code) or 1
        if remoteCode > APP_VERSION_CODE then
          local versionStr = manifest.version or tostring(remoteCode)
          announce("New update found on Local Network: Version " .. versionStr .. ". Downloading update...")
          
          Http.get(BACKEND_URL .. "/api/download-lua", function(uCode, uContent)
            if uCode == 200 and uContent and uContent ~= "" then
              applyDownloadedUpdate(versionStr, uContent)
              return
            end
          end)
          return
        end
      end
    end
    
    local checkUrl = VERSION_MANIFEST_URL .. "?t=" .. os.time()
    Http.get(checkUrl, function(code, content)
      if code == 200 then
        local manifest = decodeJSON(content)
        if manifest and manifest.version_code then
          local remoteCode = tonumber(manifest.version_code) or 1
          if remoteCode > APP_VERSION_CODE then
            local versionStr = manifest.version or tostring(remoteCode)
            announce("New update found on GitHub: Version " .. versionStr .. ". Downloading update...")
            
            local updateUrl = (manifest.download_url or LUA_UPDATE_URL) .. "?t=" .. os.time()
            Http.get(updateUrl, function(uCode, uContent)
              if uCode == 200 and uContent and uContent ~= "" then
                applyDownloadedUpdate(versionStr, uContent)
              else
                announce("Failed to download update script from GitHub.")
              end
            end)
            return
          end
        end
      end
      
      if manualCheck then
        announce("You are using the latest version of Accessible Messenger (v" .. APP_VERSION .. ").")
      end
    end)
  end)
end

function applyDownloadedUpdate(versionStr, uContent)
  pcall(function()
    local savePath = activity.getFilesDir().getAbsolutePath() .. "/main.lua"
    local file = io.open(savePath, "w")
    if file then
      file:write(uContent)
      file:close()
    end
  end)
  
  announce("Update v" .. versionStr .. " downloaded successfully! Hot reloading application...")
  
  pcall(function()
    local func, err = loadstring(uContent)
    if func then
      func()
    end
  end)
end

-- --------------------------------------------------------------------
-- UNIFIED NETWORKING ENGINE
-- --------------------------------------------------------------------
function apiGet(endpoint, githubFilePath, callback)
  Http.get(BACKEND_URL .. endpoint, function(code, content)
    if code == 200 then
      local res = decodeJSON(content)
      if res and res.success then
        callback(true, res.messages or res.users)
        return
      end
    end
    
    local apiUrl = string.format("https://raw.githubusercontent.com/%s/%s/%s/%s?t=%d", 
      GITHUB_OWNER, GITHUB_REPO, GITHUB_BRANCH, githubFilePath, os.time())
    Http.get(apiUrl, function(c2, cnt2)
      if c2 == 200 then
        callback(true, decodeJSON(cnt2))
      else
        callback(false, nil)
      end
    end)
  end)
end

function apiPost(endpoint, payload, callback)
  local payloadStr = encodeJSON(payload)
  Http.post(BACKEND_URL .. endpoint, payloadStr, function(code, content)
    if code == 200 or code == 201 then
      callback(true)
    else
      callback(false)
    end
  end)
end

-- --------------------------------------------------------------------
-- 1. LOGIN / IDENTITY SCREEN LAYOUT (Modern Design & Accessible)
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
  -- Username Input
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
  -- Password Input
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
  -- Server Address Field
  {
    TextView;
    text = "Server Address";
    textSize = "14sp";
    textColor = "#777777";
    layout_marginTop = "12dp";
    ContentDescription = "Server Address label";
  };
  {
    EditText;
    id = "editServerUrl";
    text = BACKEND_URL;
    hint = "http://10.190.183.148:5000";
    layout_width = "fill";
    textSize = "14sp";
    padding = "10dp";
    backgroundColor = "#FFFFFF";
    ContentDescription = "Server URL edit box. Pre-configured with PC Wi-Fi server address.";
  };
  -- Login Button
  {
    Button;
    id = "btnLogin";
    text = "Connect to Messenger";
    layout_width = "fill";
    layout_height = "55dp";
    layout_marginTop = "20dp";
    backgroundColor = "#1565C0";
    textColor = "#FFFFFF";
    textSize = "18sp";
    ContentDescription = "Connect to Messenger button. Double tap to sign in.";
  };
  -- Check for Remote Updates Button
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
    ContentDescription = "Check for Auto Updates button. Double tap to check Local Network and GitHub for updates.";
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
  
  -- Public Feed Button
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
  
  -- Private Chats Directory Button
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
  
  -- Check Updates Button on Home
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
    ContentDescription = "Check for Updates button. Double tap to check Local Network and GitHub for updates.";
  };

  -- Logout Button
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
  -- Header Bar
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
  -- Messages List (Stable Focus Configuration)
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
  -- Public Input Bar
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
-- 4. PRIVATE CHATS / USER DIRECTORY LAYOUT
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
  -- Header
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
  -- Message History List (Stable Focus Configuration)
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
  -- Input Bar
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
-- SCREEN CONTROLLERS & STABLE FOCUS UI UPDATES
-- --------------------------------------------------------------------

function showLoginScreen()
  activeScreen = "login"
  isPolling = false
  activity.setContentView(loadlayout(loginLayout))
  
  checkForRemoteUpdates(false)
  
  btnCheckUpdate.onClick = function()
    checkForRemoteUpdates(true)
  end
  
  btnLogin.onClick = function()
    local name = editUsername.getText().toString()
    local pass = editPassword.getText().toString()
    local customUrl = editServerUrl.getText().toString()
    
    if customUrl ~= "" then
      BACKEND_URL = customUrl
    end
    
    if name == "" or pass == "" then
      announce("Error: Please enter both a username and password.")
      return
    end
    
    announce("Connecting to server...")
    
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
-- PUBLIC FEED CONTROLLER (Focus Stability Fix)
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
      
      -- Focus Stability Fix: ONLY update adapter when count changes!
      if activeScreen == "public_feed" and lastRenderedPublicCount ~= newCount then
        lastRenderedPublicCount = newCount
        updatePublicFeedUI()
      end
    end
  end)
end

function updatePublicFeedUI()
  local chatItemLayout = {
    LinearLayout;
    orientation = "vertical";
    layout_width = "fill";
    padding = "10dp";
    layout_marginBottom = "8dp";
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
  for i, m in ipairs(publicFeedMessages) do
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
      for i, u in ipairs(data) do
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
  for i, u in ipairs(onlineUsersList) do
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
-- PRIVATE CHAT ROOM CONTROLLER (Focus Stability Fix)
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
      
      -- Focus Stability Fix: ONLY update adapter when count changes!
      if activeScreen == "private_chat" and activeChatTarget == targetUsername and lastRenderedPrivateCount ~= newCount then
        lastRenderedPrivateCount = newCount
        updatePrivateChatUI(targetUsername)
      end
    end
  end)
end

function updatePrivateChatUI(targetUsername)
  local chatItemLayout = {
    LinearLayout;
    orientation = "vertical";
    layout_width = "fill";
    padding = "10dp";
    layout_marginBottom = "8dp";
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
  for i, m in ipairs(msgs) do
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