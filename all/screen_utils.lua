-- chunkname: @./all/screen_utils.lua
local V = require("lib.klua.vector")
local SU = {}

function SU.clamp_window_aspect(w, h, ref_w, ref_h)
	local sw, sh, scale
	local origin = V.v(0, 0)

	-- -- 屏幕比较方，按照宽来伸缩，上下有可能留下黑边
	-- if MIN_SCREEN_ASPECT > w / h then
	-- 	print("clamp to width")
	-- 	sw = ref_w
	-- 	sh = ref_w / MIN_SCREEN_ASPECT
	-- 	scale = w / ref_w
	-- 	origin.y = (h - sh * scale) * 0.5
	-- elseif MAX_SCREEN_ASPECT < w / h then
	-- 	print("clamp to height")
	-- 	sh = ref_h
	-- 	sw = ref_h * MAX_SCREEN_ASPECT
	-- 	scale = h / ref_h
	-- 	origin.x = (w - sw * scale) * 0.5
	-- else
	-- 	print("no clamp")
	-- 	sw = ref_h * (w / h)
	-- 	sh = ref_h
	-- 	scale = h / ref_h
	-- end

	-- 不搞分别，统一按照高度来伸缩！
	sw = ref_h * (w / h)
	sh = ref_h
	scale = h / ref_h

	return sw, sh, scale, origin
end

-- function SU.clamp_window_aspect(w, h, ref_w, ref_h)
--     local scale_x = w / ref_w
--     local scale_y = h / ref_h
--     local scale = math.max(scale_x, scale_y) -- 保证内容填满屏幕，允许溢出
--     local sw = ref_w
--     local sh = ref_h
--     local origin = V.v(
--         (w - ref_w * scale) * 0.5, -- 居中
--         (h - ref_h * scale) * 0.5
--     )
--     return sw, sh, scale, origin
-- end

function SU.remove_references(screen, klass)
	for k, v in pairs(screen) do
		if v and type(v) == "table" and v.isInstanceOf and v:isInstanceOf(klass) then
			screen[k] = nil
		end
	end
end

function SU.get_safe_frame(w, h, ref_w, ref_h)
	local a = w / h

	for _, v in pairs(SAFE_FRAME_STEPS) do
		if a >= v[1] then
			return v[2]
		end
	end

	return SAFE_FRAME_STEPS[#SAFE_FRAME_STEPS][2]
end

function SU.get_hud_scale(w, h, ref_w, ref_h)
	local a = w / h

	for _, v in pairs(HUD_SCALE_STEPS) do
		if a >= v[1] then
			return v[2]
		end
	end

	return HUD_SCALE_STEPS[#HUD_SCALE_STEPS][2]
end

return SU
