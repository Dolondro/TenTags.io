local giflib = require("giflib")
--local gif = assert(giflib.load_gif('out/tempgif-eade6c9ae5cc474d904b8047699f93e6.gif'))
local gif = assert(giflib.load_gif('giphy.gif'))
gif:write_first_frame("out/test-frame-2.gif")
gif:close()
