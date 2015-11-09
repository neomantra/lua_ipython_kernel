local pyget = pyget
local dom_builder = {}

local element_mt = {
  __tostring = function(self) return "<"..self.tag..">" end,
  ipylua_show = function(self)
    local tbl = { "<", self.tag }
    for k,v in pairs(tbl) do
      if type(k)~="number" and k~="tag" then
        tbl[#tbl+1] = ('%s="%s"'):format(k,tostring(v))
      end
    end
    tbl[#tbl+1] = ">"
    for i=1,#self do
      local data = pyget(self[i])
      if data["image/png"] then
        tbl[#tbl+1] = ('<img src="data:image/png;base64,%s">'):format(data["image/png"])
      elseif data["text/html"] then
        tbl[#tbl+1] = data["text/html"]
      else
        tbl[#tbl+1] = assert( data["text/plain"] )
      end
    end
    tbl[#tbl+1] = "</"
    tbl[#tbl+1] = self.tag
    tbl[#tbl+1] = ">"
    return { ["text/html"] = table.concat(tbl) }
  end,
}
local function element(tag,params)
  local t = {} for k,v in pairs(params or {}) do t[k] = v end
  t.tag = tag
  return setmetatable(t, element_mt)
end

setmetatable(dom_builder,{
               __index = function(_,tag)
                 return function(params)
                   return element(tag,params)
                 end
               end,
})

return dom_builder
