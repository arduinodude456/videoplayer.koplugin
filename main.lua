local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local RawVideoWidget = require("rawvideowidget")

local BWRawVideo = WidgetContainer:extend{
    name = "bwrawvideo",
    is_doc_only = false,
}

local SETTINGS_KEY = "bwrawvideo_file"
local reader_settings = _G.G_reader_settings

function BWRawVideo:init()
    self.ui.menu:registerToMainMenu(self)
end

function BWRawVideo:addToMainMenu(menu_items)
    menu_items.bwrawvideo = {
        text = _("B/W RAW Video"),
        sorting_hint = "more_tools",
        callback = function() self:show_file_dialog() end,
    }
end

function BWRawVideo:show_file_dialog()
    local dialog
    dialog = InputDialog:new{
        title = _("BWR1 video file"),
        input = reader_settings:readSetting(SETTINGS_KEY) or "/mnt/onboard/video.bwr",
        input_hint = _("Absolute path, e.g. /mnt/onboard/video.bwr"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Play"),
                    is_enter_default = true,
                    callback = function()
                        local file = dialog:getInputText()
                        reader_settings:saveSetting(SETTINGS_KEY, file)
                        UIManager:close(dialog)
                        self:play(file)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function BWRawVideo:play(file)
    local player
    local audio_file = file:gsub("%.bwr$", ".wav")
    player = RawVideoWidget:new{
        file = file,
        audio_file = audio_file,
        on_load = function()
            UIManager:close(player)
            self:show_file_dialog()
        end,
    }
    local err = player:get_open_error()
    if err then
        UIManager:show(InfoMessage:new{ text = err, timeout = 5 })
        return
    end
    UIManager:show(player, "fast", player.dimen, false)
    local ok, start_err = player:start()
    if not ok then
        UIManager:close(player)
        UIManager:show(InfoMessage:new{ text = start_err, timeout = 5 })
    end
end

return BWRawVideo
