local Device = require("device")
local UIManager = require("ui/uimanager")
local Font = require("ui/font")
local InputContainer = require("ui/widget/container/inputcontainer")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local TitleBar = require("ui/widget/titlebar")
local Button = require("ui/widget/button")
local TextWidget = require("ui/widget/textwidget")
local GestureRange = require("ui/gesturerange")
local Size = require("ui/size")
local Geom = require("ui/geometry")
local Blitbuffer = require("ffi/blitbuffer")
local _ = require("gettext")

local UpdatesListItem = InputContainer:extend{
    entry = nil,
    width = nil,
    dialog = nil,
}

local function getListFace()
    local face
    if TextWidget.getDefaultFace then
        face = TextWidget:getDefaultFace()
    end
    if (not face) and Font and Font.getFace then
        face = Font:getFace("smallinfofont")
            or Font:getFace("infofont")
            or Font:getFace("x_smalltfont")
            or Font:getFace("ffont")
            or Font:getFace("infont")
    end
    return face
end

function UpdatesListItem:init()
    local entry = self.entry or {}
    self.entry = entry
    local content_width = self.width or math.floor(math.min(Device.screen:getWidth(), Device.screen:getHeight()) * 0.9)
    local text_args = {
        text = entry.text or "",
        alignment = "left",
        width = content_width - 2 * Size.padding.default,
    }
    local face = getListFace()
    if face then
        text_args.face = face
    end
    local text_widget = TextWidget:new(text_args)
    local background = entry.dim and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE
    self.frame = FrameContainer:new{
        padding = Size.padding.default,
        bordersize = 0,
        background = background,
        text_widget,
    }
    self[1] = self.frame
    self.dimen = self.frame:getSize()

    if entry.callback then
        local tap_range = function()
            return Geom:new{ x = self.dimen.x, y = self.dimen.y, w = self.dimen.w, h = self.dimen.h }
        end
        self.ges_events = {
            UpdatesTap = {
                GestureRange:new{ ges = "tap", range = tap_range },
            },
        }
    end
end

function UpdatesListItem:onUpdatesTap()
    if self.entry and self.entry.callback then
        self.entry.callback()
    end
    return true
end

local AppStoreUpdatesDialog = InputContainer:extend{
    appstore = nil,
    title = "",
    items = nil,
    summary_text = nil,
    filter_label = nil,
    on_check_updates = nil,
    on_toggle_filter = nil,
    on_match = nil,
    on_switch_target = nil,
    on_close = nil,
}

function AppStoreUpdatesDialog:init()
    self.screen_w = Device.screen:getWidth()
    self.screen_h = Device.screen:getHeight()
    self.width = self.screen_w
    self.height = self.screen_h
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }

    self.title_bar = TitleBar:new{
        width = self.width,
        title = self.title or _("AppStore · Updates"),
        fullscreen = false,
        with_bottom_line = true,
        close_callback = function()
            UIManager:close(self)
        end,
        show_parent = self,
    }

    self.check_button = Button:new{
        text = _("Check all updates"),
        menu_style = true,
        callback = function()
            if self.on_check_updates then
                self.on_check_updates()
            end
        end,
    }

    self.filter_button = Button:new{
        text = self.filter_label or _("Show needs update"),
        menu_style = true,
        callback = function()
            if self.on_toggle_filter then
                self.on_toggle_filter()
            end
        end,
    }

    self.match_button = Button:new{
        text = _("Match with repo"),
        menu_style = true,
        callback = function()
            if self.on_match then
                self.on_match()
            end
        end,
    }

    self.switch_button = Button:new{
        text = _("Switch to patches"),
        menu_style = true,
        callback = function()
            if self.on_switch_target then
                self.on_switch_target()
            end
        end,
    }

    self.controls = HorizontalGroup:new{
        self.check_button,
        self.filter_button,
        self.match_button,
        self.switch_button,
    }

    local summary_args = {
        text = self.summary_text or _("No plugins tracked yet."),
        alignment = "left",
    }
    local summary_face = getListFace()
    if summary_face then
        summary_args.face = summary_face
    end
    self.summary_widget = TextWidget:new(summary_args)

    self.list_group = VerticalGroup:new{}
    self.list_container = FrameContainer:new{
        padding = Size.padding.default,
        bordersize = 0,
        self.list_group,
    }

    local list_height = self.screen_h - self.title_bar:getHeight() - self.controls:getSize().h - 3 * Size.span.vertical_default

    self.scroller = ScrollableContainer:new{
        dimen = Geom:new{ w = self.width, h = list_height },
        show_parent = self,
        self.list_container,
    }
    self.cropping_widget = self.scroller

    self.content = VerticalGroup:new{
        self.title_bar,
        self.controls,
        FrameContainer:new{ padding = Size.padding.default, self.summary_widget },
        self.scroller,
    }

    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        self.content,
    }

    self:setItems(self.items or {})
end

function AppStoreUpdatesDialog:setItems(items)
    self.items = items or {}
    self.list_group:clear()
    for idx, entry in ipairs(self.items) do
        local item = UpdatesListItem:new{
            entry = entry,
            width = self.width - 2 * Size.padding.default,
            dialog = self,
        }
        self.list_group[#self.list_group + 1] = item
        if idx < #self.items then
            self.list_group[#self.list_group + 1] = VerticalSpan:new{ width = Size.span.vertical_default }
        end
    end
    UIManager:setDirty(self)
end

function AppStoreUpdatesDialog:setSummary(text)
    if self.summary_widget then
        self.summary_widget:setText(text or "")
        UIManager:setDirty(self)
    end
end

function AppStoreUpdatesDialog:setFilterLabel(text)
    if self.filter_button and text then
        self.filter_button:setText(text)
        UIManager:setDirty(self)
    end
end

function AppStoreUpdatesDialog:onCloseWidget()
    if self.on_close then
        self.on_close()
    end
end

return AppStoreUpdatesDialog

