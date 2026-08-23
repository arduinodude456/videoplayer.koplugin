-- BWR1 player for KOReader.
-- Frames are pre-dithered and bit-packed.
--
-- SYNCHRONISATION:
-- Audio ist die Master-Zeitbasis.
-- Der aktuell anzuzeigende Videoframe wird bei jedem Tick aus der
-- tatsächlich verstrichenen Wiedergabezeit berechnet.
-- Dadurch kann sich kein langfristiger Drift durch UIManager:scheduleIn()
-- aufbauen.

local bit = require("bit")
local Blitbuffer = require("ffi/blitbuffer")
local AudioPlayer = require("audioplayer")
local Button = require("ui/widget/button")
local Device = require("device")
local ffi = require("ffi")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local Screen = Device.screen


----------------------------------------------------------------
-- Präzise Wanduhr
----------------------------------------------------------------

local wall_clock

do
    local ok_require, ui_time = pcall(require, "ui/time")

    if ok_require and ui_time and ui_time.now and ui_time.to_s then
        local ok_call, probe = pcall(function()
            return ui_time.to_s(ui_time.now())
        end)

        if ok_call and type(probe) == "number" then
            wall_clock = function()
                return ui_time.to_s(ui_time.now())
            end

            logger.info(
                "bwrawvideo: benutze ui/time für die Synchronisation"
            )
        end
    end

    if not wall_clock then
        logger.info(
            "bwrawvideo: ui/time nicht verfügbar, benutze os.time()"
        )

        wall_clock = os.time
    end
end


----------------------------------------------------------------
-- BWR1 Konstanten
----------------------------------------------------------------

local MAGIC = "BWR1"
local HEADER_BYTES = 32
local VERSION = 1
local PIXEL_FORMAT_MONO1_MSB_WHITE = 1


----------------------------------------------------------------
-- Widget
----------------------------------------------------------------

local RawVideoWidget = InputContainer:extend{
    is_always_active = true,
}


----------------------------------------------------------------
-- Little-Endian Hilfsfunktionen
----------------------------------------------------------------

local function u16_le(data, offset)
    local a, b = data:byte(offset, offset + 1)
    return a + b * 256
end

local function u32_le(data, offset)
    local a, b, c, d = data:byte(offset, offset + 3)

    return a
        + b * 256
        + c * 65536
        + d * 16777216
end


----------------------------------------------------------------
-- Header lesen
----------------------------------------------------------------

local function parse_header(file)
    local data = file:read(HEADER_BYTES)

    if not data or #data ~= HEADER_BYTES then
        return nil, "The BWR1 file has no complete header."
    end

    if data:sub(1, 4) ~= MAGIC then
        return nil, "This is not a BWR1 raw-video file."
    end

    local header = {
        version = data:byte(5),
        pixel_format = data:byte(6),
        width = u16_le(data, 7),
        height = u16_le(data, 9),
        fps_x100 = u16_le(data, 11),
        frames = u32_le(data, 13),
        frame_bytes = u32_le(data, 17),
    }

    if header.version ~= VERSION then
        return nil,
            "Unsupported BWR1 version: "
            .. tostring(header.version)
    end

    if header.pixel_format ~= PIXEL_FORMAT_MONO1_MSB_WHITE then
        return nil, "Unsupported BWR1 pixel format."
    end

    if header.width < 1
        or header.height < 1
        or header.width % 8 ~= 0
    then
        return nil, "Invalid BWR1 dimensions."
    end

    if header.fps_x100 < 1 or header.frames < 1 then
        return nil, "Invalid BWR1 timing or frame count."
    end

    if header.frame_bytes
        ~= header.width / 8 * header.height
    then
        return nil, "Invalid BWR1 frame size."
    end

    return header
end


----------------------------------------------------------------
-- Lookup Tables für 1-Bit -> 8-Bit
----------------------------------------------------------------

local LUT8_FIRST = ffi.new("uint32_t[256]")
local LUT8_SECOND = ffi.new("uint32_t[256]")

local function expand_nibble(value)
    local packed = 0

    for pixel = 0, 3 do
        if bit.band(
            value,
            bit.rshift(0x08, pixel)
        ) ~= 0 then

            packed = bit.bor(
                packed,
                bit.lshift(0xFF, pixel * 8)
            )
        end
    end

    return packed
end

for value = 0, 255 do
    LUT8_FIRST[value] =
        expand_nibble(bit.rshift(value, 4))

    LUT8_SECOND[value] =
        expand_nibble(bit.band(value, 0x0F))
end


----------------------------------------------------------------
-- Initialisierung
----------------------------------------------------------------

function RawVideoWidget:init()
    self.file = assert(
        self.file,
        "BWR1 file path is required"
    )

    self.handle, self.open_error =
        io.open(self.file, "rb")

    if not self.handle then
        return
    end

    self.header, self.open_error =
        parse_header(self.handle)

    if not self.header then
        self.handle:close()
        self.handle = nil
        return
    end

    ------------------------------------------------------------
    -- WICHTIG:
    -- FPS NICHT anhand der WAV-Länge verändern.
    --
    -- Die FPS im BWR1-Header bestimmt die Bildrate.
    -- Die Audiozeit bestimmt dagegen, welcher Frame aktuell
    -- angezeigt werden muss.
    ------------------------------------------------------------

    self.fps = self.header.fps_x100 / 100 
    self.period = 1 / self.fps

    self.frame_index = 0

    -- Exakte logische Wiedergabeposition in Sekunden.
    self.playback_position = 0

    -- Zeitpunkt, an dem playback_position gestartet wurde.
    self.audio_anchor_wall = nil
    self.audio_anchor_pos = 0

    self.paused = true
    self.closed = false

    self.dimen = Geom:new{
        x = 0,
        y = 0,
        w = self.header.width,
        h = self.header.height,
    }

    self._tick = function()
        self:_tick_frame()
    end

    self.audio =
        self.audio_file
        and AudioPlayer.new(self.audio_file)
        or nil

    self:_init_toolbar()
end


----------------------------------------------------------------
-- Fehler
----------------------------------------------------------------

function RawVideoWidget:get_open_error()
    return self.open_error
end

function RawVideoWidget:get_audio_error()
    if not self.audio then
        return "Keine WAV-Datei angegeben."
    end

    local f = io.open(self.audio_file, "rb")

    if not f then
        return "WAV-Datei nicht gefunden: "
            .. self.audio_file
    end

    f:close()

    return self.audio:get_error()
end


----------------------------------------------------------------
-- Toolbar
----------------------------------------------------------------

function RawVideoWidget:_init_toolbar()
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()

    self.toolbar_h =
        math.max(
            64,
            math.floor(self.screen_h * 0.075)
        )

    local button_w =
        math.floor(self.screen_w / 5)

    local function make_button(text, callback)
        return Button:new{
            text = text,
            width = button_w,
            height = self.toolbar_h - 8,
            padding = 4,
            text_font_size = 18,
            callback = callback,
        }
    end

    self.back_button =
        make_button("-5 s", function()
            self:seek_seconds(-5)
        end)

    self.play_button =
        make_button("Play", function()
            self:toggle_pause()
        end)

    self.load_button =
        make_button("Laden", function()
            if self.on_load then
                self.on_load()
            end
        end)

    self.forward_button =
        make_button("+5 s", function()
            self:seek_seconds(5)
        end)

    self.close_button =
        make_button("Schließen", function()
            self:close_player()
        end)

    self.toolbar = HorizontalGroup:new{
        align = "center",
        self.back_button,
        self.play_button,
        self.load_button,
        self.forward_button,
        self.close_button,
    }

    self.toolbar_dimen = Geom:new{
        x = 0,
        y = self.screen_h - self.toolbar_h,
        w = self.screen_w,
        h = self.toolbar_h,
    }

    local y =
        self.toolbar_dimen.y / self.screen_h

    local zones = {
        {
            id = "seek_back",
            x = 0,
            handler = function()
                self:seek_seconds(-5)
            end,
        },

        {
            id = "toggle",
            x = 0.20,
            handler = function()
                self:toggle_pause()
            end,
        },

        {
            id = "load",
            x = 0.40,
            handler = function()
                if self.on_load then
                    self.on_load()
                end
            end,
        },

        {
            id = "seek_forward",
            x = 0.60,
            handler = function()
                self:seek_seconds(5)
            end,
        },

        {
            id = "close",
            x = 0.80,
            handler = function()
                self:close_player()
            end,
        },
    }

    for _, zone in ipairs(zones) do
        local zone_id = zone.id
        local zone_x = zone.x
        local zone_handler = zone.handler

        self:registerTouchZones{
            {
                id = "bwrawvideo_" .. zone_id,
                ges = "tap",

                screen_zone = {
                    ratio_x = zone_x,
                    ratio_y = y,
                    ratio_w = 0.20,
                    ratio_h =
                        self.toolbar_h
                        / self.screen_h,
                },

                handler = function()
                    zone_handler()
                    return true
                end,
            },
        }
    end
end


----------------------------------------------------------------
-- Play/Pause Button
----------------------------------------------------------------

function RawVideoWidget:_update_play_button()
    if self.play_button then
        self.play_button:setText(
            self.paused and "Play" or "Pause",
            self.play_button.width
        )
    end
end


----------------------------------------------------------------
-- Frame lesen
----------------------------------------------------------------

function RawVideoWidget:_read_frame(index)
    index = index - 15
    if index < 0
        or index >= self.header.frames
    then
 self.handle:seek(
        "set",
        HEADER_BYTES
            + 1 * self.header.frame_bytes
    )

    local packed =
        self.handle:read(
            self.header.frame_bytes
        )

    if not packed
        or #packed ~= self.header.frame_bytes
    then
        return nil,
            "Could not read a complete BWR1 frame."
    end

    return packed

    end

    self.handle:seek(
        "set",
        HEADER_BYTES
            + index * self.header.frame_bytes
    )

    local packed =
        self.handle:read(
            self.header.frame_bytes
        )

    if not packed
        or #packed ~= self.header.frame_bytes
    then
        return nil,
            "Could not read a complete BWR1 frame."
    end

    return packed
end


----------------------------------------------------------------
-- Frame expandieren
----------------------------------------------------------------

function RawVideoWidget:_expand_binary_frame(packed)
    local bb = Blitbuffer.new(
        self.header.width,
        self.header.height,
        Blitbuffer.TYPE_BB8
    )

    local destination =
        ffi.cast("uint32_t*", bb.data)

    local output_index = 0

    for i = 0, self.header.frame_bytes - 1 do
        local value = packed:byte(i + 1)

        destination[output_index] =
            LUT8_FIRST[value]

        destination[output_index + 1] =
            LUT8_SECOND[value]

        output_index =
            output_index + 2
    end

    return bb
end


----------------------------------------------------------------
-- Frame laden
----------------------------------------------------------------

function RawVideoWidget:_load_frame(index)
    local packed, err =
        self:_read_frame(index)

    if not packed then
        return nil, err
    end

    local new_frame =
        self:_expand_binary_frame(packed)

    if self.frame_bb then
        self.frame_bb:free()
    end

    self.frame_bb = new_frame

    return true
end


----------------------------------------------------------------
-- Bildschirm aktualisieren
----------------------------------------------------------------

function RawVideoWidget:_refresh_fast()
    UIManager:setDirty(
        self,
        "fast",
        self.dimen,
        false
    )

    UIManager:setDirty(
        self,
        "fast",
        self.toolbar_dimen,
        false
    )
end


----------------------------------------------------------------
-- AUDIO-ZEIT
----------------------------------------------------------------
--
-- Die Audio-Wiedergabe ist die Master-Uhr.
--
-- audio_anchor_pos:
--   Position im Audiostream beim Start/Resume
--
-- audio_anchor_wall:
--   Wanduhrzeit zu diesem Zeitpunkt
--
-- Aktuelle Audiozeit:
--   audio_anchor_pos +
--   (jetzt - audio_anchor_wall)
----------------------------------------------------------------

function RawVideoWidget:_mark_audio_position(position)
    self.audio_anchor_wall = wall_clock()
    self.audio_anchor_pos = position
    self.playback_position = position
end


function RawVideoWidget:_get_audio_position()
    if not self.audio_anchor_wall then
        return self.playback_position or 0
    end

    local elapsed =
        wall_clock()
        - self.audio_anchor_wall

    if elapsed < 0 then
        elapsed = 0
    end

    return self.audio_anchor_pos + elapsed
end


----------------------------------------------------------------
-- Synchronisationskern
----------------------------------------------------------------
--
-- Statt:
--
--   Frame 1
--   warten
--   Frame 2
--   warten
--   Frame 3
--
-- machen wir:
--
--   "Wie weit ist der Ton?"
--   -> daraus Frame berechnen
--
-- Dadurch kann scheduleIn() keinen Drift mehr erzeugen.
----------------------------------------------------------------

function RawVideoWidget:_get_frame_for_time(position)
    local frame =
        math.floor(position * self.fps)

    if frame < 0 then
        frame = 0
    end

    if frame >= self.header.frames then
        frame = self.header.frames - 1
    end

    return frame
end


function RawVideoWidget:_sync_to_audio()
    if not self.audio then
        return self.frame_index
    end

    local audio_position =
        self:_get_audio_position()

    self.playback_position =
        audio_position

    local target_frame =
        self:_get_frame_for_time(audio_position)

    return target_frame
end


----------------------------------------------------------------
-- Wiedergabe-Tick
----------------------------------------------------------------

function RawVideoWidget:_tick_frame()
    if self.closed or self.paused then
        return
    end

    ------------------------------------------------------------
    -- Audio bestimmt den aktuellen Frame.
    ------------------------------------------------------------

    local target_frame =
        self:_sync_to_audio()

    ------------------------------------------------------------
    -- Ende erreicht?
    ------------------------------------------------------------

    if target_frame >= self.header.frames - 1 then
        local ok, err =
            self:_load_frame(
                self.header.frames - 1
            )

        if not ok then
            logger.warn(
                "bwrawvideo: playback stopped:",
                err
            )
        end

        self.frame_index =
            self.header.frames - 1

        self:_refresh_fast()

        self.paused = true
        self:_update_play_button()

        return
    end

    ------------------------------------------------------------
    -- Nur einen Frame laden, wenn er sich geändert hat.
    ------------------------------------------------------------

    if target_frame ~= self.frame_index then
        local ok, err =
            self:_load_frame(target_frame)

        if not ok then
            logger.warn(
                "bwrawvideo: playback stopped:",
                err
            )

            self.paused = true
            self:_update_play_button()

            return
        end

        self.frame_index =
            target_frame

        self:_refresh_fast()
    elseif not self.frame_bb then
        local ok, err =
            self:_load_frame(target_frame)

        if not ok then
            logger.warn(
                "bwrawvideo: playback stopped:",
                err
            )

            self.paused = true
            self:_update_play_button()

            return
        end

        self:_refresh_fast()
    end

    ------------------------------------------------------------
    -- Nächsten Tick planen.
    --
    -- Die tatsächliche Frameauswahl erfolgt beim nächsten Tick
    -- wieder anhand der Audiozeit. Daher ist es egal, wenn dieser
    -- Tick etwas zu spät kommt.
    ------------------------------------------------------------

    UIManager:scheduleIn(
        self.period,
        self._tick
    )
end


----------------------------------------------------------------
-- Start
----------------------------------------------------------------

function RawVideoWidget:start()
    if self.open_error then
        return nil, self.open_error
    end

    self.frame_index = 0
    self.playback_position = 0

    ------------------------------------------------------------
    -- Audio zuerst starten.
    -- Erst danach beginnt die Video-Zeitmessung.
    ------------------------------------------------------------

    if self.audio then
        local ok, err =
            self.audio:start_from(0)

        if not ok then
            return nil, err
        end

        self:_mark_audio_position(0)
    else
        self.audio_anchor_wall =
            wall_clock()

        self.audio_anchor_pos = 0
        self.playback_position = 0
    end

    self.paused = false
    self:_update_play_button()

    ------------------------------------------------------------
    -- Frame 0 sofort anzeigen.
    ------------------------------------------------------------

    local ok, err =
        self:_load_frame(0)

    if not ok then
        self.paused = true
        self:_update_play_button()
        return nil, err
    end

    self:_refresh_fast()

    ------------------------------------------------------------
    -- Danach normale synchronisierte Wiedergabe.
    ------------------------------------------------------------

    UIManager:scheduleIn(
        self.period,
        self._tick
    )

    return true
end


----------------------------------------------------------------
-- Pause / Resume
----------------------------------------------------------------

function RawVideoWidget:toggle_pause()
    if self.closed or self.open_error then
        return
    end

    if self.paused then
        --------------------------------------------------------
        -- RESUME
        --------------------------------------------------------

        local position =
            self.playback_position or 0

        if self.audio then
            local ok, err =
                self.audio:start_from(position)

            if not ok then
                logger.warn(
                    "bwrawvideo: audio resume failed:",
                    err
                )

                return
            end
        end

        self:_mark_audio_position(position)

        self.paused = false
        self:_update_play_button()

        self:_tick_frame()

    else
        --------------------------------------------------------
        -- PAUSE
        --------------------------------------------------------

        -- Position VOR dem Pausieren festhalten.
        self.playback_position =
            self:_get_audio_position()

        if self.audio then
            self.audio:pause()
        end

        self.audio_anchor_wall = nil

        self.paused = true
        self:_update_play_button()

        UIManager:unschedule(self._tick)
    end
end


----------------------------------------------------------------
-- Seek
----------------------------------------------------------------

function RawVideoWidget:seek_seconds(delta)
    if self.closed or self.open_error then
        return
    end

    ------------------------------------------------------------
    -- Aktuelle Zeit bestimmen.
    ------------------------------------------------------------

    local current_position =
        self.paused
        and self.playback_position
        or self:_get_audio_position()

    if not current_position then
        current_position = 0
    end

    local target_position =
        current_position + delta

    ------------------------------------------------------------
    -- Videolänge
    ------------------------------------------------------------

    local video_duration =
        self.header.frames / self.fps

    if target_position < 0 then
        target_position = 0
    end

    if target_position > video_duration then
        target_position = video_duration
    end

    ------------------------------------------------------------
    -- Position setzen.
    ------------------------------------------------------------

    self.playback_position =
        target_position

    local target_frame =
        self:_get_frame_for_time(target_position)

    self.frame_index =
        target_frame

    ------------------------------------------------------------
    -- Audio an dieselbe Stelle setzen.
    ------------------------------------------------------------

    if self.audio then
        local ok, err =
            self.audio:start_from(target_position)

        if not ok then
            logger.warn(
                "bwrawvideo: audio seek failed:",
                err
            )
        end

        if self.paused then
            self.audio:pause()
            self.audio_anchor_wall = nil
        else
            self:_mark_audio_position(
                target_position
            )
        end
    else
        if not self.paused then
            self:_mark_audio_position(
                target_position
            )
        end
    end

    ------------------------------------------------------------
    -- Ziel-Frame sofort anzeigen.
    ------------------------------------------------------------

    local ok, err =
        self:_load_frame(target_frame)

    if not ok then
        logger.warn(
            "bwrawvideo: seek frame failed:",
            err
        )

        return
    end

    self:_refresh_fast()

    ------------------------------------------------------------
    -- Falls Wiedergabe aktiv ist, Tick neu starten.
    ------------------------------------------------------------

    UIManager:unschedule(self._tick)

    if not self.paused then
        UIManager:scheduleIn(
            self.period,
            self._tick
        )
    end
end


----------------------------------------------------------------
-- Zeichnen
----------------------------------------------------------------

function RawVideoWidget:paintTo(bb, x, y)
    self.dimen.x = x or 0
    self.dimen.y = y or 0

    bb:paintRect(
        self.dimen.x,
        self.dimen.y,
        self.dimen.w,
        self.dimen.h,
        Blitbuffer.COLOR_WHITE
    )

    if self.frame_bb then
        bb:blitFrom(
            self.frame_bb,
            self.dimen.x,
            self.dimen.y,
            0,
            0,
            self.dimen.w,
            self.dimen.h
        )
    end

    bb:paintRect(
        self.toolbar_dimen.x,
        self.toolbar_dimen.y,
        self.toolbar_dimen.w,
        self.toolbar_dimen.h,
        Blitbuffer.COLOR_WHITE
    )

    self.toolbar:paintTo(
        bb,
        self.toolbar_dimen.x,
        self.toolbar_dimen.y + 4
    )
end


----------------------------------------------------------------
-- Schließen
----------------------------------------------------------------

function RawVideoWidget:close_player()
    if not self.closed then
        UIManager:close(self)
    end
end


function RawVideoWidget:onCloseWidget()
    self.closed = true
    self.paused = true

    UIManager:unschedule(self._tick)

    if self.audio then
        self.audio:stop()
    end

    if self.frame_bb then
        self.frame_bb:free()
        self.frame_bb = nil
    end

    if self.handle then
        self.handle:close()
        self.handle = nil
    end
end


return RawVideoWidget