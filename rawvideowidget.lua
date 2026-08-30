-- BWC1 Color Video Player for KOReader.
--
-- Frames are pre-dithered and 3-bit color packed.
--
-- SYNCHRONISATION:
-- Audio ist die Master-Zeitbasis.
-- Der aktuell anzuzeigende Videoframe wird bei jedem Tick aus der
-- tatsächlich verstrichenen Wiedergabezeit berechnet.
-- Dadurch kann sich kein langfristiger Drift durch UIManager:scheduleIn()
-- aufbauen.
--
-- BWC1 COLOR FORMAT:
--
--   0 = #000000 Schwarz
--   1 = #FFFFFF Weiß
--   2 = #FF0000 Rot
--   3 = #00FF00 Grün
--   4 = #0000FF Blau
--   5 = #FFFF00 Gelb
--   6 = #FF00FF Magenta / Lila
--   7 = #00FFFF Cyan / Türkis
--
-- Jeder Pixel benötigt 3 Bit.
-- 8 Pixel werden in 3 Bytes gepackt.
--
-- Das Dithering erfolgt bereits beim Konvertieren des Videos.
-- Der Player selbst muss deshalb kein Dithering mehr durchführen.


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
-- BWC1 Konstanten
----------------------------------------------------------------

local MAGIC = "BWC1"
local HEADER_BYTES = 32
local VERSION = 1

-- 3-bit color, most-significant-bit first.
local PIXEL_FORMAT_COLOR3_MSB = 2


----------------------------------------------------------------
-- BWC1 Palette
----------------------------------------------------------------
--
-- Die Werte werden direkt als RGB32-Struktur geschrieben.
--
-- Wichtig:
-- Nicht als uint32_t schreiben!
-- ColorRGB32 besteht in KOReader aus:
--
--   uint8_t r
--   uint8_t g
--   uint8_t b
--   uint8_t alpha
--
----------------------------------------------------------------

local COLOR_BLACK = {
    r = 0x00,
    g = 0x00,
    b = 0x00,
    alpha = 0xFF,
}

local COLOR_WHITE = {
    r = 0xFF,
    g = 0xFF,
    b = 0xFF,
    alpha = 0xFF,
}

local COLOR_RED = {
    r = 0xFF,
    g = 0x00,
    b = 0x00,
    alpha = 0xFF,
}

local COLOR_GREEN = {
    r = 0x00,
    g = 0xFF,
    b = 0x00,
    alpha = 0xFF,
}

local COLOR_BLUE = {
    r = 0x00,
    g = 0x00,
    b = 0xFF,
    alpha = 0xFF,
}

local COLOR_YELLOW = {
    r = 0xFF,
    g = 0xFF,
    b = 0x00,
    alpha = 0xFF,
}

local COLOR_MAGENTA = {
    r = 0xFF,
    g = 0x00,
    b = 0xFF,
    alpha = 0xFF,
}

local COLOR_CYAN = {
    r = 0x00,
    g = 0xFF,
    b = 0xFF,
    alpha = 0xFF,
}


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

    if not a or not b then
        return nil
    end

    return a + b * 256
end


local function u32_le(data, offset)
    local a, b, c, d =
        data:byte(offset, offset + 3)

    if not a or not b or not c or not d then
        return nil
    end

    return a
        + b * 256
        + c * 65536
        + d * 16777216
end


----------------------------------------------------------------
-- Header lesen
----------------------------------------------------------------

local function parse_header(file)

    local data =
        file:read(HEADER_BYTES)

    if not data
        or #data ~= HEADER_BYTES
    then
        return nil,
            "The BWC1 file has no complete header."
    end

    if data:sub(1, 4) ~= MAGIC then
        return nil,
            "This is not a BWC1 color raw-video file."
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

    if not header.version
        or not header.pixel_format
        or not header.width
        or not header.height
        or not header.fps_x100
        or not header.frames
        or not header.frame_bytes
    then
        return nil,
            "Invalid BWC1 header."
    end

    if header.version ~= VERSION then
        return nil,
            "Unsupported BWC1 version: "
            .. tostring(header.version)
    end

    if header.pixel_format
        ~= PIXEL_FORMAT_COLOR3_MSB
    then
        return nil,
            "Unsupported BWC1 pixel format: "
            .. tostring(header.pixel_format)
    end

    if header.width < 1
        or header.height < 1
        or header.width % 8 ~= 0
    then
        return nil,
            "Invalid BWC1 dimensions."
    end

    if header.fps_x100 < 1
        or header.frames < 1
    then
        return nil,
            "Invalid BWC1 timing or frame count."
    end

    ------------------------------------------------------------
    -- 3 Bit pro Pixel:
    --
    -- 8 Pixel = 24 Bit = 3 Byte
    ------------------------------------------------------------

    local expected_frame_bytes =
        (header.width
        * header.height
        * 3)
        / 8

    if header.frame_bytes
        ~= expected_frame_bytes
    then
        return nil,
            "Invalid BWC1 frame size. Expected "
            .. tostring(expected_frame_bytes)
            .. ", got "
            .. tostring(header.frame_bytes)
            .. "."
    end

    return header
end


----------------------------------------------------------------
-- Initialisierung
----------------------------------------------------------------

function RawVideoWidget:init()

    self.file = assert(
        self.file,
        "BWC1 file path is required"
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
    -- FPS NICHT anhand der WAV-Länge verändern.
    --
    -- Die FPS im BWC1-Header bestimmt die Bildrate.
    -- Die Audiozeit bestimmt dagegen, welcher Frame aktuell
    -- angezeigt werden muss.
    ------------------------------------------------------------

    self.fps =
        self.header.fps_x100 / 100

    self.period =
        1 / self.fps

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

    local f =
        io.open(
            self.audio_file,
            "rb"
        )

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

    self.screen_w =
        Screen:getWidth()

    self.screen_h =
        Screen:getHeight()

    self.toolbar_h =
        math.max(
            64,
            math.floor(
                self.screen_h * 0.075
            )
        )

    local button_w =
        math.floor(
            self.screen_w / 5
        )

    local function make_button(
        text,
        callback
    )

        return Button:new{
            text = text,
            width = button_w,
            height =
                self.toolbar_h - 8,
            padding = 4,
            text_font_size = 18,
            callback = callback,
        }
    end

    self.back_button =
        make_button(
            "-5 s",
            function()
                self:seek_seconds(-5)
            end
        )

    self.play_button =
        make_button(
            "Play",
            function()
                self:toggle_pause()
            end
        )

    self.load_button =
        make_button(
            "Laden",
            function()
                if self.on_load then
                    self.on_load()
                end
            end
        )

    self.forward_button =
        make_button(
            "+5 s",
            function()
                self:seek_seconds(5)
            end
        )

    self.close_button =
        make_button(
            "Schließen",
            function()
                self:close_player()
            end
        )

    self.toolbar =
        HorizontalGroup:new{
            align = "center",

            self.back_button,
            self.play_button,
            self.load_button,
            self.forward_button,
            self.close_button,
        }

    self.toolbar_dimen =
        Geom:new{
            x = 0,
            y = self.screen_h - self.toolbar_h,
            w = self.screen_w,
            h = self.toolbar_h,
        }

    local y =
        self.toolbar_dimen.y
        / self.screen_h

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
        local zone_handler =
            zone.handler

        self:registerTouchZones{
            {
                id =
                    "bwrawvideo_"
                    .. zone_id,

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
            self.paused
                and "Play"
                or "Pause",

            self.play_button.width
        )
    end
end


----------------------------------------------------------------
-- BWC1 Frame lesen
----------------------------------------------------------------

function RawVideoWidget:_read_frame(index)

    ------------------------------------------------------------
    -- index ist 0-basiert.
    ------------------------------------------------------------

    if index < 0 then
        index = 0
    end

    if index >= self.header.frames then
        index =
            self.header.frames - 1
    end

    ------------------------------------------------------------
    -- Header überspringen und direkt zum gewünschten Frame.
    ------------------------------------------------------------

    local offset =
        HEADER_BYTES
        + index * self.header.frame_bytes

    local ok, seek_error =
        self.handle:seek(
            "set",
            offset
        )

    if not ok then
        return nil,
            "Could not seek to BWC1 frame "
            .. tostring(index)
            .. ": "
            .. tostring(seek_error)
    end

    local packed =
        self.handle:read(
            self.header.frame_bytes
        )

    if not packed
        or #packed ~= self.header.frame_bytes
    then
        return nil,
            "Could not read a complete "
            .. "BWC1 frame."
    end

    return packed
end


----------------------------------------------------------------
-- 3-Bit-Pixel auslesen
----------------------------------------------------------------
--
-- Das Encoder-Format packt 8 Pixel in 3 Bytes:
--
-- p0 p1 p2 p3 p4 p5 p6 p7
--
-- b0:
--
-- 76543210
-- p0---p1--p2--
--
-- b1:
--
-- p2-p3---p4--p5-
--
-- b2:
--
-- p5--p6---p7---
--
-- Jeder Pixel ist ein Wert von 0 bis 7.
--
----------------------------------------------------------------

local function unpack_8_pixels(
    b0,
    b1,
    b2
)

    local p0 =
        bit.band(
            bit.rshift(b0, 5),
            0x07
        )

    local p1 =
        bit.band(
            bit.rshift(b0, 2),
            0x07
        )

    local p2 =
        bit.bor(
            bit.lshift(
                bit.band(
                    b0,
                    0x03
                ),
                1
            ),
            bit.rshift(
                b1,
                7
            )
        )

    local p3 =
        bit.band(
            bit.rshift(b1, 4),
            0x07
        )

    local p4 =
        bit.band(
            bit.rshift(b1, 1),
            0x07
        )

    local p5 =
        bit.bor(
            bit.lshift(
                bit.band(
                    b1,
                    0x01
                ),
                2
            ),
            bit.rshift(
                b2,
                6
            )
        )

    local p6 =
        bit.band(
            bit.rshift(b2, 3),
            0x07
        )

    local p7 =
        bit.band(
            b2,
            0x07
        )

    return
        p0,
        p1,
        p2,
        p3,
        p4,
        p5,
        p6,
        p7
end


----------------------------------------------------------------
-- Frame expandieren
----------------------------------------------------------------

function RawVideoWidget:_expand_color_frame(
    packed
)

    ------------------------------------------------------------
    -- KOReader besitzt einen nativen RGB32-Blitbuffer.
    --
    -- TYPE_BBRGB32:
    --
    --   r
    --   g
    --   b
    --   alpha
    --
    -- Das ist für Farbdarstellung auf dem Libra Colour der
    -- passende Blitbuffer-Typ.
    ------------------------------------------------------------

    local bb =
        Blitbuffer.new(
            self.header.width,
            self.header.height,
            Blitbuffer.TYPE_BBRGB32
        )

    local destination =
        ffi.cast(
            "ColorRGB32*",
            bb.data
        )

    local pixel_count =
        self.header.width
        * self.header.height

    local output_index = 0
    local input_index = 1

    while output_index < pixel_count do

        local b0 =
            packed:byte(input_index)

        local b1 =
            packed:byte(input_index + 1)

        local b2 =
            packed:byte(input_index + 2)

        if not b0
            or not b1
            or not b2
        then
            bb:free()

            return nil,
                "Incomplete BWC1 color group."
        end

        local p0,
            p1,
            p2,
            p3,
            p4,
            p5,
            p6,
            p7 =
            unpack_8_pixels(
                b0,
                b1,
                b2
            )

        --------------------------------------------------------
        -- Pixel 0
        --------------------------------------------------------

        if output_index < pixel_count then

            local color =
                COLOR_BLACK

            if p0 == 1 then
                color = COLOR_WHITE
            elseif p0 == 2 then
                color = COLOR_RED
            elseif p0 == 3 then
                color = COLOR_GREEN
            elseif p0 == 4 then
                color = COLOR_BLUE
            elseif p0 == 5 then
                color = COLOR_YELLOW
            elseif p0 == 6 then
                color = COLOR_MAGENTA
            elseif p0 == 7 then
                color = COLOR_CYAN
            end

            destination[output_index].r =
                color.r

            destination[output_index].g =
                color.g

            destination[output_index].b =
                color.b

            destination[output_index].alpha =
                color.alpha
        end

        --------------------------------------------------------
        -- Pixel 1
        --------------------------------------------------------

        if output_index + 1 < pixel_count then

            local color =
                COLOR_BLACK

            if p1 == 1 then
                color = COLOR_WHITE
            elseif p1 == 2 then
                color = COLOR_RED
            elseif p1 == 3 then
                color = COLOR_GREEN
            elseif p1 == 4 then
                color = COLOR_BLUE
            elseif p1 == 5 then
                color = COLOR_YELLOW
            elseif p1 == 6 then
                color = COLOR_MAGENTA
            elseif p1 == 7 then
                color = COLOR_CYAN
            end

            destination[output_index + 1].r =
                color.r

            destination[output_index + 1].g =
                color.g

            destination[output_index + 1].b =
                color.b

            destination[output_index + 1].alpha =
                color.alpha
        end

        --------------------------------------------------------
        -- Pixel 2
        --------------------------------------------------------

        if output_index + 2 < pixel_count then

            local color =
                COLOR_BLACK

     if p2 == 1 then
                color = COLOR_WHITE
            elseif p2 == 2 then
                color = COLOR_RED
            elseif p2 == 3 then
                color = COLOR_GREEN
            elseif p2 == 4 then
                color = COLOR_BLUE
            elseif p2 == 5 then
                color = COLOR_YELLOW
            elseif p2 == 6 then
                color = COLOR_MAGENTA
            elseif p2 == 7 then
                color = COLOR_CYAN
            end

            destination[output_index + 2].r =
                color.r

            destination[output_index + 2].g =
                color.g

            destination[output_index + 2].b =
                color.b

            destination[output_index + 2].alpha =
                color.alpha
        end

        --------------------------------------------------------
        -- Pixel 3
        --------------------------------------------------------

        if output_index + 3 < pixel_count then

            local color =
                COLOR_BLACK

            if p3 == 1 then
                color = COLOR_WHITE
            elseif p3 == 2 then
                color = COLOR_RED
            elseif p3 == 3 then
                color = COLOR_GREEN
            elseif p3 == 4 then
                color = COLOR_BLUE
            elseif p3 == 5 then
                color = COLOR_YELLOW
            elseif p3 == 6 then
                color = COLOR_MAGENTA
            elseif p3 == 7 then
                color = COLOR_CYAN
            end

            destination[output_index + 3].r =
                color.r

            destination[output_index + 3].g =
                color.g

            destination[output_index + 3].b =
                color.b

            destination[output_index + 3].alpha =
                color.alpha
        end

        --------------------------------------------------------
        -- Pixel 4
        --------------------------------------------------------

        if output_index + 4 < pixel_count then

            local color =
                COLOR_BLACK

            if p4 == 1 then
                color = COLOR_WHITE
            elseif p4 == 2 then
                color = COLOR_RED
            elseif p4 == 3 then
                color = COLOR_GREEN
            elseif p4 == 4 then
                color = COLOR_BLUE
            elseif p4 == 5 then
                color = COLOR_YELLOW
            elseif p4 == 6 then
                color = COLOR_MAGENTA
            elseif p4 == 7 then
                color = COLOR_CYAN
            end

            destination[output_index + 4].r =
                color.r

            destination[output_index + 4].g =
                color.g

            destination[output_index + 4].b =
                color.b

            destination[output_index + 4].alpha =
                color.alpha
        end

        --------------------------------------------------------
        -- Pixel 5
        --------------------------------------------------------

        if output_index + 5 < pixel_count then

            local color =
                COLOR_BLACK

            if p5 == 1 then
                color = COLOR_WHITE
            elseif p5 == 2 then
                color = COLOR_RED
            elseif p5 == 3 then
                color = COLOR_GREEN
            elseif p5 == 4 then
                color = COLOR_BLUE
            elseif p5 == 5 then
                color = COLOR_YELLOW
            elseif p5 == 6 then
                color = COLOR_MAGENTA
            elseif p5 == 7 then
                color = COLOR_CYAN
            end

            destination[output_index + 5].r =
                color.r

            destination[output_index + 5].g =
                color.g

            destination[output_index + 5].b =
                color.b

            destination[output_index + 5].alpha =
                color.alpha
        end

        --------------------------------------------------------
        -- Pixel 6
        --------------------------------------------------------

        if output_index + 6 < pixel_count then

            local color =
                COLOR_BLACK

            if p6 == 1 then
                color = COLOR_WHITE
            elseif p6 == 2 then
                color = COLOR_RED
            elseif p6 == 3 then
                color = COLOR_GREEN
            elseif p6 == 4 then
                color = COLOR_BLUE
            elseif p6 == 5 then
                color = COLOR_YELLOW
            elseif p6 == 6 then
                color = COLOR_MAGENTA
            elseif p6 == 7 then
                color = COLOR_CYAN
            end

            destination[output_index + 6].r =
                color.r

            destination[output_index + 6].g =
                color.g

            destination[output_index + 6].b =
                color.b

            destination[output_index + 6].alpha =
                color.alpha
        end

        --------------------------------------------------------
        -- Pixel 7
        --------------------------------------------------------

        if output_index + 7 < pixel_count then

            local color =
                COLOR_BLACK

            if p7 == 1 then
                color = COLOR_WHITE
            elseif p7 == 2 then
                color = COLOR_RED
            elseif p7 == 3 then
                color = COLOR_GREEN
            elseif p7 == 4 then
                color = COLOR_BLUE
            elseif p7 == 5 then
                color = COLOR_YELLOW
            elseif p7 == 6 then
                color = COLOR_MAGENTA
            elseif p7 == 7 then
                color = COLOR_CYAN
            end

            destination[output_index + 7].r =
                color.r

            destination[output_index + 7].g =
                color.g

            destination[output_index + 7].b =
                color.b

            destination[output_index + 7].alpha =
                color.alpha
        end

        output_index =
            output_index + 8

        input_index =
            input_index + 3
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
        self:_expand_color_frame(
            packed
        )

    if not new_frame then
        return nil,
            "Could not expand BWC1 color frame."
    end

    if self.frame_bb then
        self.frame_bb:free()
    end

    self.frame_bb =
        new_frame

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
--
--   audio_anchor_pos +
--   (jetzt - audio_anchor_wall)
--
----------------------------------------------------------------

function RawVideoWidget:_mark_audio_position(
    position
)

    self.audio_anchor_wall =
        wall_clock()

    self.audio_anchor_pos =
        position

    self.playback_position =
        position
end


function RawVideoWidget:_get_audio_position()

    if not self.audio_anchor_wall then
        return self.playback_position
            or 0
    end

    local elapsed =
        wall_clock()
        - self.audio_anchor_wall

    if elapsed < 0 then
        elapsed = 0
    end

    return
        self.audio_anchor_pos
        + elapsed
end


----------------------------------------------------------------
-- Synchronisationskern
----------------------------------------------------------------

function RawVideoWidget:_get_frame_for_time(
    position
)

    local frame =
        math.floor(
            position * self.fps
        )

    if frame < 0 then
        frame = 0
    end

    if frame >= self.header.frames then
        frame =
            self.header.frames - 1
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

    return self:_get_frame_for_time(
        audio_position
    )
end


----------------------------------------------------------------
-- Wiedergabe-Tick
----------------------------------------------------------------

function RawVideoWidget:_tick_frame()

    if self.closed
        or self.paused
    then
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

    if target_frame >=
        self.header.frames - 1
    then

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

    if target_frame
        ~= self.frame_index
    then

        local ok, err =
            self:_load_frame(
                target_frame
            )

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
            self:_load_frame(
                target_frame
            )

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
    -- Die Frameauswahl erfolgt beim nächsten Tick erneut
    -- anhand der tatsächlichen Wiedergabezeit.
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
        return nil,
            self.open_error
    end

    self.frame_index = 0
    self.playback_position = 0

    ------------------------------------------------------------
    -- Audio zuerst starten.
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
    -- Wiedergabe starten.
    ------------------------------------------------------------

    UIManager:unschedule(
        self._tick
    )

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

    if self.closed
        or self.open_error
    then
        return
    end

    if self.paused then

        --------------------------------------------------------
        -- RESUME
        --------------------------------------------------------

        local position =
            self.playback_position
            or 0

        if position < 0 then
            position = 0
        end

        local duration =
            self.header.frames
            / self.fps

        if position >= duration then
            position = 0
            self.frame_index = 0
        end

        if self.audio then

            local ok, err =
                self.audio:start_from(
                    position
                )

            if not ok then

                logger.warn(
                    "bwrawvideo: audio resume failed:",
                    err
                )

                return
            end
        end

        self:_mark_audio_position(
            position
        )

        self.paused = false

        self:_update_play_button()

        --------------------------------------------------------
        -- Sofort den zur Audiozeit passenden Frame laden.
        --------------------------------------------------------

        local target_frame =
            self:_get_frame_for_time(
                position
            )

        local ok, err =
            self:_load_frame(
                target_frame
            )

        if not ok then

            logger.warn(
                "bwrawvideo: resume frame failed:",
                err
            )

            self.paused = true

            self:_update_play_button()

            return
        end

        self.frame_index =
            target_frame

        self:_refresh_fast()

        UIManager:unschedule(
            self._tick
        )

        UIManager:scheduleIn(
            self.period,
            self._tick
        )

    else

        --------------------------------------------------------
        -- PAUSE
        --------------------------------------------------------

        local position

        if self.audio then
            position =
                self:_get_audio_position()
        else
            position =
                self.playback_position
        end

        self.playback_position =
            position

        self:_mark_audio_position(
            position
        )

        if self.audio then
            self.audio:pause()
        end

        self.paused = true

        self:_update_play_button()

        UIManager:unschedule(
            self._tick
        )
    end
end


----------------------------------------------------------------
-- Seek
----------------------------------------------------------------

function RawVideoWidget:seek_seconds(
    delta
)

    if self.closed
        or self.open_error
    then
        return
    end

    local current_position

    if self.audio
        and not self.paused
    then
        current_position =
            self:_get_audio_position()
    else
        current_position =
            self.playback_position
            or 0
    end

    local target_position =
        current_position + delta

    ------------------------------------------------------------
    -- Dauer aus Frameanzahl und FPS.
    ------------------------------------------------------------

    local duration =
        self.header.frames
        / self.fps

    if target_position < 0 then
        target_position = 0
    end

    if target_position > duration then
        target_position = duration
    end

    local target_frame =
        self:_get_frame_for_time(
            target_position
        )

    ------------------------------------------------------------
    -- Audio an die neue Position setzen.
    ------------------------------------------------------------

    if self.audio then

        if not self.paused then

            local ok, err =
                self.audio:start_from(
                    target_position
                )

            if not ok then

                logger.warn(
                    "bwrawvideo: seek audio failed:",
                    err
                )

                return
            end

        else

            -- Im Pause-Zustand wird die Audio-Position nur
            -- logisch vorgemerkt. Beim Resume startet Audio
            -- dann an dieser Position.
            self.audio:stop()
        end
    end

    ------------------------------------------------------------
    -- Neue Audio-Zeitbasis setzen.
    ------------------------------------------------------------

    self:_mark_audio_position(
        target_position
    )

    ------------------------------------------------------------
    -- Ziel-Frame sofort anzeigen.
    ------------------------------------------------------------

    local ok, err =
        self:_load_frame(
            target_frame
        )

    if not ok then

        logger.warn(
            "bwrawvideo: seek frame failed:",
            err
        )

        return
    end

    self.frame_index =
        target_frame

    self:_refresh_fast()

    ------------------------------------------------------------
    -- Laufenden Tick neu starten.
    ------------------------------------------------------------

    UIManager:unschedule(
        self._tick
    )

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

function RawVideoWidget:paintTo(
    bb,
    x,
    y
)

    self.dimen.x =
        x or 0

    self.dimen.y =
        y or 0

    ------------------------------------------------------------
    -- Hintergrund
    ------------------------------------------------------------

    bb:paintRect(
        self.dimen.x,
        self.dimen.y,
        self.dimen.w,
        self.dimen.h,
        Blitbuffer.COLOR_WHITE
    )

    ------------------------------------------------------------
    -- Farbbild
    ------------------------------------------------------------

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

    ------------------------------------------------------------
    -- Toolbar
    ------------------------------------------------------------

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

    if self.closed then
        return
    end

    self.closed = true
    self.paused = true

    ------------------------------------------------------------
    -- Timer stoppen
    ------------------------------------------------------------

    UIManager:unschedule(
        self._tick
    )

    ------------------------------------------------------------
    -- Audio stoppen
    ------------------------------------------------------------

    if self.audio then
        self.audio:stop()
    end

    ------------------------------------------------------------
    -- Frame freigeben
    ------------------------------------------------------------

    if self.frame_bb then

        self.frame_bb:free()

        self.frame_bb = nil
    end

    ------------------------------------------------------------
    -- Datei schließen
    ------------------------------------------------------------

    if self.handle then

        self.handle:close()

        self.handle = nil
    end
end


return RawVideoWidget
