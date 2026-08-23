local logger = require("logger")
local AudioPlayer = {}

local function shell_quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function u16(data, offset)
    local a, b = data:byte(offset, offset + 1)
    return a + b * 256
end

local function u32(data, offset)
    local a, b, c, d = data:byte(offset, offset + 3)
    return a + b * 256 + c * 65536 + d * 16777216
end

local function put_u32(value)
    local b1 = value % 256
    local b2 = math.floor(value / 256) % 256
    local b3 = math.floor(value / 65536) % 256
    local b4 = math.floor(value / 16777216) % 256
    return string.char(b1, b2, b3, b4)
end

local function find_command(name)
    local pipe = io.popen("command -v " .. name .. " 2>/dev/null", "r")
    if not pipe then return nil end
    local path = pipe:read("*l")
    pipe:close()
    if path and path ~= "" then return path end
    return nil
end

function AudioPlayer.new(path)
    local gst_launch = find_command("gst-launch-1.0")
    local gst_inspect = find_command("gst-inspect-1.0")
    local self = {
        path = path,
        clip_path = nil,
        pid = nil,
        paused = false,
        command = nil,
        command_name = nil,
        is_mtk = false,
    }
    if gst_launch and gst_inspect then
        local probe = io.popen(shell_quote(gst_inspect) .. " mtkbtmwrpcaudiosink 2>/dev/null", "r")
        local output = probe and probe:read("*a") or ""
        if probe then probe:close() end
        if output:find("mtkbtmwrpcaudiosink", 1, true) then
            self.command = gst_launch
            self.command_name = "mtk-gstreamer"
            self.is_mtk = true
        end
    end
    if not self.command then
        self.command = find_command("aplay")
        self.command_name = "aplay"
    end
    if not self.command then
        self.command = find_command("tinyplay")
        self.command_name = "tinyplay"
    end
    self.gst_launch = gst_launch
    logger.info("bwrawvideo: audio backend", self.command_name or "none")
    return setmetatable(self, { __index = AudioPlayer })
end

function AudioPlayer:is_available()
    return self.command ~= nil
end

-- Berechnet die tatsächliche Abspieldauer der WAV-Datei in Sekunden aus dem
-- Header (Datenbytes geteilt durch die Byte-Rate = Samplerate * Blockalign).
function AudioPlayer:get_duration_seconds()
    local input = io.open(self.path, "rb")
    if not input then return nil, "WAV-Datei nicht gefunden: " .. self.path end
    local header = input:read(44)
    input:close()
    if not header or #header ~= 44 or header:sub(1, 4) ~= "RIFF" or header:sub(9, 12) ~= "WAVE" then
        return nil, "Ungültiger WAV-Header."
    end
    local sample_rate = u32(header, 25)
    local block_align = u16(header, 33)
    local data_bytes = u32(header, 41)
    if sample_rate < 1 or block_align < 1 or data_bytes < 1 then
        return nil, "Ungültige WAV-Parameter."
    end
    return data_bytes / (sample_rate * block_align)
end

function AudioPlayer:get_error()
    if self.command then return nil end
    return "Kein unterstützter WAV-Audiopfad gefunden: auf dem Libra Colour wird "
        .. "gst-launch-1.0 mit mtkbtmwrpcaudiosink, alternativ aplay oder tinyplay benötigt."
end

function AudioPlayer:_make_clip(start_seconds)
    start_seconds = math.max(0, start_seconds or 0)
    if start_seconds == 0 then return self.path end
    local input = io.open(self.path, "rb")
    if not input then return nil end
    local header = input:read(44)
    if not header or #header ~= 44 or header:sub(1, 4) ~= "RIFF" or header:sub(9, 12) ~= "WAVE" then
        input:close()
        return nil
    end
    local sample_rate = u32(header, 25)
    local block_align = u16(header, 33)
    local data_bytes = u32(header, 41)
    if sample_rate < 1 or block_align < 1 then
        input:close()
        return nil
    end
    local requested_offset = math.floor(start_seconds * sample_rate) * block_align
    local offset = math.min(data_bytes, requested_offset)
    input:seek("set", 44 + offset)
    local remaining = data_bytes - offset
    local output_path = os.tmpname()
    local output = io.open(output_path, "wb")
    if not output then input:close(); return nil end
    local prefix = header:sub(1, 4) .. put_u32(36 + remaining) .. header:sub(9, 40) .. put_u32(remaining)
    output:write(prefix)
    while remaining > 0 do
        local chunk = input:read(math.min(65536, remaining))
        if not chunk or #chunk == 0 then break end
        output:write(chunk)
        remaining = remaining - #chunk
    end
    output:close()
    input:close()
    return output_path
end

function AudioPlayer:start_from(seconds)
    if not self.command then return nil, self:get_error() end
    local probe = io.open(self.path, "rb")
    if not probe then return nil, "WAV-Datei nicht gefunden: " .. self.path end
    probe:close()
    self:stop()
    self.clip_path = self:_make_clip(seconds or 0)
    if not self.clip_path then
        return nil, "Die WAV-Datei konnte nicht gelesen oder für die Spulposition vorbereitet werden."
    end
    local command
    if self.command_name == "mtk-gstreamer" then
        local raw_stream = "tail -c +45 " .. shell_quote(self.clip_path)
        local pipeline = raw_stream .. " | exec " .. shell_quote(self.command)
            .. " fdsrc fd=0 ! audio/x-raw,format=S16LE,rate=44100,channels=2"
            .. " ! audioconvert ! audioresample ! mtkbtmwrpcaudiosink"
        local setsid = find_command("setsid")
        if setsid then
            command = shell_quote(setsid) .. " sh -c " .. shell_quote(pipeline)
        else
            command = "sh -c " .. shell_quote(pipeline)
        end
    elseif self.command_name == "aplay" then
        command = shell_quote(self.command) .. " -q " .. shell_quote(self.clip_path)
    else
        command = shell_quote(self.command) .. " " .. shell_quote(self.clip_path)
    end
    local pipe = io.popen(command .. " >/dev/null 2>&1 & echo $!", "r")
    if not pipe then return nil, "Der WAV-Audioprozess konnte nicht gestartet werden." end
    self.pid = tonumber(pipe:read("*l"))
    pipe:close()
    if not self.pid then return nil, "Der WAV-Audioprozess lieferte keine Prozess-ID." end
    logger.info("bwrawvideo: audio started", self.command_name, "pid", self.pid)
    self.paused = false
    return true
end

function AudioPlayer:pause()
    if self.pid and not self.paused then
        os.execute("kill -STOP -" .. tostring(self.pid) .. " 2>/dev/null")
        self.paused = true
    end
end

function AudioPlayer:resume()
    if self.pid and self.paused then
        os.execute("kill -CONT -" .. tostring(self.pid) .. " 2>/dev/null")
        self.paused = false
    end
end

function AudioPlayer:stop()
    if self.pid then
        os.execute("kill -TERM -" .. tostring(self.pid) .. " 2>/dev/null")
        self.pid = nil
    end
    if self.clip_path and self.clip_path ~= self.path then
        os.remove(self.clip_path)
    end
    self.clip_path = nil
    self.paused = false
end

return AudioPlayer
