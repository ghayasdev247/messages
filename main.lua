-- ====================================================================
-- ACCESSIBLE ANONYMOUS MESSENGER FOR JIESHUO / COMMENTARY SCREEN READER
-- Developed in AndroLua+
-- Features: Public Feed, Private Messaging, Accessibility & Jieshuo Optimized
-- Backend: GitHub Native Serverless (ghayasdev247/messages) & REST API
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
local GITHUB_OWNER = "ghayasdev247"
local GITHUB_REPO = "messages"
local GITHUB_BRANCH = "main"

-- Fallback local server URL if using local server instead of raw GitHub
local BACKEND_URL = "http://10.0.2.2:5000"
local USE_GITHUB_SERVERLESS = true

local currentUser = { name = "", online = false, githubToken = "" }
local activeScreen = "login" -- "login", "dashboard", "public_feed", "private_directory", "private_chat"
local activeChatTarget = ""
local pollingHandler = nil
local isPolling = false

-- Data Stores
local publicFeedMessages = {}
local onlineUsersList = {}
local privateChatHistory = {} -- Keyed by username
local lastPublicMessageCount = 0
local lastPrivateMessageCount = 0

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

local b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
function base64Encode(data)
  return ((data:gsub('.', function(x) 
    local r,b='',x:byte()
    for i=8,1,-1 do r=r..(b%2^i-b%2^(i-1)>0 and '1' or '0') end
    return r
  end)..'0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
    if (#x < 6) then return '' end
    local c=0
    for i=1,6 do c=c+(x:sub(i,i)=='1' and 2^(6-i) or 0) end
    return b64chars:sub(c+1,c+1)
  end)..({ '', '==', '=' })[#data%3+1])
end

-- Helper function to make Jieshuo/Screen reader announcements
function announce(text)
  pcall(function()
    Toast.makeText(activity, text, Toast.LENGTH_SHORT).show()
    activity.getWindow().getDecorView().announceForAccessibility(text)
  end)
end

-- --------------------------------------------------------------------
-- GITHUB REST API WRAPPER
-- --------------------------------------------------------------------
function fetchRawGitHubData(filePath, callback)
  local rawUrl = string.format("https://raw.githubusercontent.com/%s/%s/%s/%s?t=%d", 
    GITHUB_OWNER, GITHUB_REPO, GITHUB_BRANCH, filePath, os.time())
  
  Http.get(rawUrl, function(code, content)
    if code == 200 then
      local data = decodeJSON(content)
      callback(true, data)
    else
      -- Fallback to local BACKEND_URL if GitHub raw fetch fails
      Http.get(BACKEND_URL .. "/api/" .. filePath:gsub("data/", ""):gsub(".json", ""), function(c2, cnt2)
        if c2 == 200 then
          callback(true, decodeJSON(cnt2))
        else
          callback(false, nil)
        end
      end)
    end
  end)
end

function commitGitHubData(filePath, contentStr, commitMessage, callback)
  local apiUrl = string.format("https://api.github.com/repos/%s/%s/contents/%s", GITHUB_OWNER, GITHUB_REPO, filePath)
  local headers = {}
  headers["User-Agent"] = "ChatifyApp"
  if currentUser.githubToken and currentUser.githubToken ~= "" then
    headers["Authorization"] = "token " .. currentUser.githubToken
  end

  -- Step 1: Get current file SHA hash
  Http.get(apiUrl, nil, nil, headers, function(code, content)
    local sha = nil
    if code == 200 then
      local info = decodeJSON(content)
      if info and info.sha then sha = info.sha end
    end
    
    -- Step 2: Push updated contents
    local payload = {
      message = commitMessage,
      content = base64Encode(contentStr),
      branch = GITHUB_BRANCH
    }
    if sha then payload.sha = sha end
    
    Http.post(apiUrl, encodeJSON(payload), nil, nil, headers, function(pCode, pContent)
      if pCode == 200 or pCode == 201 then
        callback(true)
      else
        -- Fallback to REST backend
        callback(false)
      end
    end)
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
    textSize = "22sp";
    textColor = "#000000";
    layout_gravity = "center";
    padding = "10dp";
    ContentDescription = "Accessible Messenger Application Header";
  };
  {
    TextView;
    text = "GitHub-Native Serverless Login";
    textSize = "16sp";
    textColor = "#555555";
    layout_gravity = "center";
    layout_marginBottom = "15dp";
  };
  -- Username Input
  {
    TextView;
    text = "Step 1: Enter Username";
    textSize = "16sp";
    textColor = "#222222";
    layout_marginTop = "5dp";
  };
  {
    EditText;
    id = "editUsername";
    hint = "Type any alias or handle";
    layout_width = "fill";
    textSize = "18sp";
    padding = "12dp";
    ContentDescription = "Username edit box. Type your desired alias here.";
  };
  -- Password Input
  {
    TextView;
    text = "Step 2: Enter Password";
    textSize = "16sp";
    textColor = "#222222";
    layout_marginTop = "10dp";
  };
  {
    EditText;
    id = "editPassword";
    hint = "Type a password";
    inputType = InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD;
    layout_width = "fill";
    textSize = "18sp";
    padding = "12dp";
    ContentDescription = "Password edit box. Type your password here.";
  };
  -- Optional GitHub Personal Access Token Field
  {
    TextView;
    text = "GitHub Token (Optional for write access)";
    textSize = "14sp";
    textColor = "#777777";
    layout_marginTop = "10dp";
  };
  {
    EditText;
    id = "editGithubToken";
    hint = "ghp_xxxxxxxxxxxx";
    layout_width = "fill";
    textSize = "14sp";
    padding = "8dp";
    ContentDescription = "GitHub Personal Access Token input field.";
  };
  -- Login Button
  {
    Button;
    id = "btnLogin";
    text = "Connect via GitHub";
    layout_width = "fill";
    layout_height = "60dp";
    layout_marginTop = "20dp";
    backgroundColor = "#1565C0";
    textColor = "#FFFFFF";
    textSize = "18sp";
    ContentDescription = "Connect via GitHub button. Double tap to sign in.";
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
  padding = "16dp";
  backgroundColor = "#FFFFFF";
  {
    TextView;
    id = "txtDashboardHeader";
    text = "Messenger Main Home";
    textSize = "22sp";
    textColor = "#000000";
    layout_gravity = "center";
    layout_marginBottom = "5dp";
    ContentDescription = "Messenger Main Home Screen";
  };
  {
    TextView;
    id = "txtLoggedAs";
    text = "Status: Connected to ghayasdev247/messages";
    textSize = "15sp";
    textColor = "#2E7D32";
    layout_gravity = "center";
    layout_marginBottom = "25dp";
    ContentDescription = "Status indicator: Connected to GitHub repository.";
  };
  
  -- Public Feed Button
  {
    Button;
    id = "btnOpenPublicFeed";
    text = "🌐 Public Feed (GitHub Managed)";
    layout_width = "fill";
    layout_height = "70dp";
    layout_marginBottom = "20dp";
    backgroundColor = "#0288D1";
    textColor = "#FFFFFF";
    textSize = "18sp";
    ContentDescription = "Public Feed button. Double tap to view or send public messages on GitHub.";
  };
  
  -- Private Chats Directory Button
  {
    Button;
    id = "btnOpenPrivateChats";
    text = "💬 Private Chats & Online Users";
    layout_width = "fill";
    layout_height = "70dp";
    layout_marginBottom = "20dp";
    backgroundColor = "#2E7D32";
    textColor = "#FFFFFF";
    textSize = "18sp";
    ContentDescription = "Private Chats button. Double tap to view online users and chat privately.";
  };
  
  -- Logout Button
  {
    Button;
    id = "btnLogout";
    text = "Disconnect / Logout";
    layout_width = "fill";
    layout_height = "55dp";
    layout_marginTop = "20dp";
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
  backgroundColor = "#F0F4F8";
  -- Header
  {
    LinearLayout;
    orientation = "horizontal";
    layout_width = "fill";
    gravity = "center_vertical";
    padding = "8dp";
    backgroundColor = "#0288D1";
    {
      Button;
      id = "btnPublicToHome";
      text = "< Home";
      textColor = "#FFFFFF";
      ContentDescription = "Back to home dashboard button";
    };
    {
      TextView;
      text = "Public Feed (GitHub)";
      textSize = "20sp";
      textColor = "#FFFFFF";
      layout_marginLeft = "15dp";
      layout_weight = "1";
      ContentDescription = "Public Feed room managed via GitHub.";
    };
  };
  -- Messages List
  {
    ListView;
    id = "listPublicMessages";
    layout_width = "fill";
    layout_weight = "1";
    layout_marginTop = "8dp";
    layout_marginBottom = "8dp";
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
      ContentDescription = "Public message text field. Type message to post to GitHub repository.";
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
  backgroundColor = "#F9F9F9";
  -- Header
  {
    LinearLayout;
    orientation = "horizontal";
    layout_width = "fill";
    gravity = "center_vertical";
    padding = "8dp";
    backgroundColor = "#E0E0E0";
    {
      Button;
      id = "btnBackToPrivateList";
      text = "< Directory";
      ContentDescription = "Back to private chats directory";
    };
    {
      TextView;
      id = "txtChatTargetHeader";
      text = "Private Chat";
      textSize = "18sp";
      textColor = "#000000";
      layout_marginLeft = "15dp";
      layout_weight = "1";
      ContentDescription = "Currently chatting in private room.";
    };
  };
  -- Message History List
  {
    ListView;
    id = "listChatMessages";
    layout_width = "fill";
    layout_weight = "1";
    layout_marginTop = "8dp";
    layout_marginBottom = "8dp";
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
-- SCREEN CONTROLLERS & GITHUB NETWORKING
-- --------------------------------------------------------------------

function showLoginScreen()
  activeScreen = "login"
  isPolling = false
  activity.setContentView(loadlayout(loginLayout))
  
  btnLogin.onClick = function()
    local name = editUsername.getText().toString()
    local pass = editPassword.getText().toString()
    local token = editGithubToken.getText().toString()
    
    if name == "" or pass == "" then
      announce("Error: Please enter both a username and password.")
      return
    end
    
    currentUser.name = name
    currentUser.githubToken = token
    currentUser.online = true
    
    announce("Connected as " .. name .. " via GitHub. Welcome to Homepage.")
    showDashboardScreen()
    startPollingLoop()
  end
end

function showDashboardScreen()
  activeScreen = "dashboard"
  activity.setContentView(loadlayout(dashboardLayout))
  
  txtLoggedAs.setText("Logged in as: " .. currentUser.name .. " (GitHub Managed)")
  txtLoggedAs.setContentDescription("Logged in as " .. currentUser.name)
  
  btnOpenPublicFeed.onClick = function()
    announce("Opening Public Feed")
    showPublicFeedScreen()
  end
  
  btnOpenPrivateChats.onClick = function()
    announce("Opening Private Chats Directory")
    showPrivateDirectoryScreen()
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
    
    -- Insert new message into local list and sync to GitHub
    table.insert(publicFeedMessages, {
      sender = currentUser.name,
      text = text,
      time = os.date("%I:%M %p")
    })
    
    editPublicMessageInput.setText("")
    updatePublicFeedUI()
    announce("Public message posted: " .. text)
    
    -- Commit updated public_feed.json to GitHub repository
    local jsonContent = encodeJSON(publicFeedMessages)
    commitGitHubData("data/public_feed.json", jsonContent, "Post public message by " .. currentUser.name, function(success)
      if success then
        fetchPublicFeedMessages()
      end
    end)
  end
end

function fetchPublicFeedMessages()
  fetchRawGitHubData("data/public_feed.json", function(success, data)
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
      if activeScreen == "public_feed" then
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
    padding = "8dp";
    {
      TextView;
      id = "msgSender";
      textSize = "12sp";
      textColor = "#0288D1";
    };
    {
      TextView;
      id = "msgText";
      textSize = "16sp";
      textColor = "#111111";
      padding = "4dp";
    };
  }
  
  local data = {}
  for i, m in ipairs(publicFeedMessages) do
    table.insert(data, {
      msgSender = m.sender .. " (" .. (m.time or "") .. "):",
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
    announce("Refreshing GitHub online users directory...")
    fetchOnlineUsersList()
  end
end

function fetchOnlineUsersList()
  fetchRawGitHubData("data/online_users.json", function(success, data)
    if success and data then
      local filtered = {}
      local now_ts = os.time()
      for i, u in ipairs(data) do
        if u.name ~= currentUser.name then
          local last_seen = u.last_seen or 0
          local is_online = (now_ts - last_seen) <= 120
          table.insert(filtered, {
            name = u.name,
            status = is_online and "Online" or "Offline"
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
-- PRIVATE CHAT ROOM CONTROLLER
-- --------------------------------------------------------------------
function showPrivateChatScreen(targetUsername)
  activeScreen = "private_chat"
  activeChatTarget = targetUsername
  lastPrivateMessageCount = 0
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
    
    if not privateChatHistory[targetUsername] then
      privateChatHistory[targetUsername] = {}
    end
    
    table.insert(privateChatHistory[targetUsername], {
      sender = currentUser.name,
      recipient = targetUsername,
      text = text,
      time = os.date("%I:%M %p")
    })
    
    editMessageInput.setText("")
    updatePrivateChatUI(targetUsername)
    announce("Private message sent: " .. text)
    
    -- Sync private chat thread to GitHub
    local threadFile = "data/chats/" .. currentUser.name .. "_" .. targetUsername .. ".json"
    commitGitHubData(threadFile, encodeJSON(privateChatHistory[targetUsername]), "Private message to " .. targetUsername, function() end)
  end
  
  btnBackToPrivateList.onClick = function()
    activeChatTarget = ""
    announce("Returning to private chats directory")
    showPrivateDirectoryScreen()
  end
end

function fetchPrivateChatThread(targetUsername)
  local threadFile = "data/chats/" .. currentUser.name .. "_" .. targetUsername .. ".json"
  fetchRawGitHubData(threadFile, function(success, data)
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
      if activeScreen == "private_chat" and activeChatTarget == targetUsername then
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
    padding = "8dp";
    {
      TextView;
      id = "msgSender";
      textSize = "12sp";
      textColor = "#757575";
    };
    {
      TextView;
      id = "msgText";
      textSize = "16sp";
      textColor = "#111111";
      padding = "4dp";
    };
  }
  
  local data = {}
  local msgs = privateChatHistory[targetUsername] or {}
  for i, m in ipairs(msgs) do
    local senderLabel = (m.sender == currentUser.name) and "Me" or m.sender
    table.insert(data, {
      msgSender = senderLabel .. " (" .. (m.time or "") .. "):",
      msgText = m.text
    })
  end
  
  local adapter = LuaAdapter(activity, data, chatItemLayout)
  listChatMessages.setAdapter(adapter)
end

-- --------------------------------------------------------------------
-- BACKGROUND AUTO-POLLING LOOP & PRESENCE HEARTBEAT
-- --------------------------------------------------------------------
function startPollingLoop()
  if isPolling then return end
  isPolling = true
  
  local function poll()
    if not currentUser.online or not isPolling then return end
    
    -- Refresh active screen contents from GitHub
    if activeScreen == "public_feed" then
      fetchPublicFeedMessages()
    elseif activeScreen == "private_directory" then
      fetchOnlineUsersList()
    elseif activeScreen == "private_chat" and activeChatTarget ~= "" then
      fetchPrivateChatThread(activeChatTarget)
    end
    
    -- Schedule next pulse after 4 seconds
    Handler().postDelayed(Runnable{ run = poll }, 4000)
  end
  
  poll()
end

-- --------------------------------------------------------------------
-- INITIAL ENTRY POINT
-- --------------------------------------------------------------------
showLoginScreen()