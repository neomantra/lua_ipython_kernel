local json = require "IPyLua.dkjson"
local uuid = require "IPyLua.uuid"
local html_template = require "IPyLua.html_template"
local null = json.null
local type = luatype or type

local DEF_XGRID = 100
local DEF_YGRID = 100
local DEF_SIZE = 6
local DEF_WIDTH = 6
local DEF_HEIGTH = 6
local DEF_ALPHA = 0.8
local DEF_X = 0
local DEF_Y = 0
local COLORS = {
  "#ff0000", "#00ff00", "#0000ff", "#ffff00", "#ff00ff", "#00ffff", "#000000", 
  "#800000", "#008000", "#000080", "#808000", "#800080", "#008080", "#808080", 
  "#c00000", "#00c000", "#0000c0", "#c0c000", "#c000c0", "#00c0c0", "#c0c0c0", 
  "#400000", "#004000", "#000040", "#404000", "#400040", "#004040", "#404040", 
  "#200000", "#002000", "#000020", "#202000", "#200020", "#002020", "#202020", 
  "#600000", "#006000", "#000060", "#606000", "#600060", "#006060", "#606060", 
  "#a00000", "#00a000", "#0000a0", "#a0a000", "#a000a0", "#00a0a0", "#a0a0a0", 
  "#e00000", "#00e000", "#0000e0", "#e0e000", "#e000e0", "#00e0e0", "#e0e0e0", 
}

local figure = {}
local figure_methods = {}

local function round(val)
  if val > 0 then
    return math.floor(val + 0.5)
  end
  return -math.floor(-val + 0.5)
end

local function default_true(value)
  if value == nil then return true else return value end
end

local function reduce(t, func)
  local out = t[1]
  for i=2,#t do out = func(out, t[i]) end
  return out
end

local math_min = math.min
local math_max = math.max

local function min(t) return reduce(t, math_min) end
local function max(t) return reduce(t, math_max) end

local function minmax(t)
  local min,max = t[1],t[1]
  for i=2,#t do
    min=math_min(min,t[i])
    max=math_max(max,t[i])
  end
  return min,max
end

local function factors(t, out, dict)
  local out,dict = out or {},dict or {}
  for i=1,#t do
    local s = tostring(t[i])
    if not dict[s] then
      out[i],dict[s] = s,true
    end
  end
  return out,dict
end

local function apply_gap(p, a, b)
  local gap = p * (b-a)
  return a-gap, b+gap
end

local function extend(param, n)
  local tt = type(param)
  if tt == "string" or tt == "number" then
    local value = param
    param = {}
    for i=1,n do param[i] = value end
  end
  return param
end

local function toseries(s)
  collectgarbage("collect")
  if s==nil then return nil end
  local tt = type(s)
  if tt == "table" or tt == "userdata" then
    local mt = getmetatable(s)
    if mt and mt.ipylua_toseries then
      return mt.ipylua_toseries(s)
    elseif tt == "table" then
      return s
    end
  end
  error(("series data type %s cannot be handled: " ):format(tt))
end

local function invert(t)
  local r = {}
  for k,v in pairs(t) do r[v] = k end
  return r
end

-- error checking

local function check_equal_sizes(...)
  local arg = table.pack(...)
  local N = #arg[1]
  for i=2,#arg do
    assert(N == #arg[i], "all the given seires shoud be equal in size")
  end
end

local function check_table(t, ...)
  local inv_list = invert({...})
  for i,v in pairs(t) do
    assert(inv_list[i], ("unknown field %s"):format(i))
  end
end

local function check_value(t, k, ...)
  if t[k] then
    local inv_list = invert({...})
    local v = t[k]
    assert(inv_list[v], ("invalid value %s at field %s"):format(v,k))
  end
end

local function check_type(t, k, ty)
  local tt = type(t[k])
  assert(t[k] == nil or tt == ty,
         ("type %s is not valid for field %s, expected %s"):format(tt, k, ty))
end

local function check_types(t, keys, types)
  assert(#keys == #types)
  for i=1,#keys do
    local k,ty = keys[i],types[i]
    check_type(t, k, ty)
  end
end

local function check_mandatory(t, key)
  assert(t[key], ("field %s is mandatory"):format(key))
end

local function check_mandatories(t, ...)
  for _,key in ipairs(table.pack(...)) do
    check_mandatory(t, key)
  end
end

-- private functions

local function next_color(self)
  self._color_number = (self._color_number + 1) % #self._colors
  local color = self._colors[ self._color_number + 1]
  return color
end

local function check_axis_range(self)
  if not self._doc.attributes.x_range then
    local axis = self._doc.attributes.below[1] or self._doc.attributes.above[1]
    if axis.type == "LinearAxis" then
      local x_min,x_max = math.huge,-math.huge
      for _,source in ipairs(self._sources) do
        local s_min,s_max = minmax(source.attributes.data.x)
        x_min = math.min(x_min,s_min)
        x_max = math.max(x_max,s_max)
      end
      self:x_range( apply_gap(0.05, x_min, x_max) )
    else
      local list,dict
      for _,source in ipairs(self._sources) do
        list,dict = factors(x, list, dict)
      end
      self:x_range(list)
    end
  end

  if not self._doc.attributes.y_range then
    local axis = self._doc.attributes.below[1] or self._doc.attributes.above[1]
    if axis.type == "LinearAxis" then
      local y_min,y_max = math.huge,-math.huge
      for _,source in ipairs(self._sources) do
        local s_min,s_max = minmax(source.attributes.data.y)
        y_min = math.min(y_min, s_min)
        y_max = math.max(y_max, s_max)
      end
      self:y_range( apply_gap(0.05, y_min, y_max) )
    else
      local list,dict
      for _,source in ipairs(self._sources) do
        list,dict = factors(x, list, dict)
      end
      self:y_range(list)
    end
  end
end

local function add_source(self, source)
  table.insert(self._sources, source)
end

local function add_reference(self, id, tbl)
  self._references[id] = self._references[id] or {}
  table.insert(self._references[id], tbl)
end

local function update_references(self, id, obj)
  for _,ref in ipairs(self._references[id] or {}) do
    for k,v in pairs(ref) do
      ref[k] = assert( obj[k] )
    end
  end
end

local function compile_glyph(self, i)
  i = i or #self._list
  self._list[i] = json.encode( self._list[i] )
end

local function append_renderer(self, ref)
  table.insert( self._doc.attributes.renderers, ref )
  return ref
end

local function add_simple_glyph(self, name, attributes, subtype)
  local id = uuid.new()
  local list = self._list
  attributes.id = id
  local glyph = {
    attributes = attributes,
    type = name,
    id = id,
  }
  self._dict[id] = glyph
  local ref = { type = name, subtype = subtype, id = id, }
  add_reference(self, id, ref)
  list[#list+1] = glyph
  return ref,glyph
end


local function add_column_data_source(self, data, columns)
  local attributes = {
    tags = {},
    doc = null,
    selected = {
      ["2d"] = { indices = {} },
      ["1d"] = { indices = {} },
      ["0d"] = { indices = {}, flag=false },
    },
    callback = null,
    data = data,
    column_names = columns,
  }
  local source_ref,source = add_simple_glyph(self, "ColumnDataSource",
                                             attributes)
  add_source(self, source)
  return source_ref
end

local function append_source_renderer(self, source_ref, glyph_ref)
  local attributes = {
    nonselection_glyph = null,
    data_source = source_ref,
    tags = {},
    doc = null,
    selection_glyph = null,
    glyph = glyph_ref,
  }
  return append_renderer(self, add_simple_glyph(self, "GlyphRenderer",
                                                attributes) )
end

local function add_legend(self, legend, renderer_ref)
  local attributes = {
    tags = {},
    doc = null,
    plot = self._docref,
    legends = { { legend, { renderer_ref } } },
  }
  return append_renderer(self, add_simple_glyph(self, "Legend", attributes))
end

local function add_tool(self, name, attributes)
  attributes.plot = self._docref
  local tools = self._doc.attributes.tools
  tools[#tools+1] = add_simple_glyph(self, name, attributes)
end

local function add_axis(self, key, params)
  check_mandatories(params, "pos", "type")
  local doc_axis = self._doc.attributes[params.pos]
  if not doc_axis[1] then
    local formatter_ref,formatter = add_simple_glyph(self, "BasicTickFormatter",
                                                     { tags={}, doc=null })
    
    local ticker_ref,ticker =
      add_simple_glyph(self, "BasicTicker",
                       { tags={}, doc=null, mantissas={2, 5, 10} })
    
    local axis_ref,axis = add_simple_glyph(self, params.type,
                                           {
                                             tags={},
                                             doc=null,
                                             axis_label=params.label,
                                             plot = self._docref,
                                             formatter = formatter_ref,
                                             ticker = ticker_ref,
                                           }
    )

    local dim = (key == "x") and 0 or 1
    append_renderer(self, add_simple_glyph(self, "Grid",
                                           { tags={}, doc=null, dimension=dim,
                                             ticker=ticker_ref,
                                             plot = self._docref, }))
    append_renderer(self, axis_ref)
    
    doc_axis[1] = axis_ref
  else
    local axis = self._dict[ doc_axis[1].id ]
    axis.attributes.axis_label = params.label
    axis.type = params.type
    update_references(self, axis.id, axis)
  end
end

local function axis_range(self, a, b, key)
  local range = key .. "_range"
  local glyph
  if not self._doc.attributes[range] then
    local ref
    ref,glyph = add_simple_glyph(self, "DUMMY",
                                 { callback = null, doc = null, tags = {} })
    self._doc.attributes[range] = ref
  else
    glyph = self._dict[ self._doc.attributes[range].id ]
  end
  if type(a) == "table" then
    assert(not b, "expected one table of factors or two numbers (min, max)")
    glyph.type = "FactorRange"
    glyph.attributes.factors = a
    glyph.attributes["start"] = nil
    glyph.attributes["end"] = nil
  else
    assert(type(a) == "number" and type(b) == "number",
           "expected one table of factors or two numbers (min, max)")
    glyph.type = "Range1d"
    glyph.attributes.factors = nil
    glyph.attributes["start"] = a
    glyph.attributes["end"] = b
  end
  update_references(self, glyph.id, glyph)
end

local function tool_events(self)
  self._doc.attributes.tool_events =
    add_simple_glyph(
      self, "ToolEvents",
      {
        geometries = {},
        tags = {},
        doc = null,
      }
    )
end

-- figure class implementation

local figure_methods = {
  
  -- axis
  
  x_axis = function(self, params) -- type, label, pos, log, grid, num_minor_ticks, visible, number_formatter
    params = params or {}
    check_table(params, "type", "label", "pos", "log", "grid", "num_minor_ticks",
                "visible", "number_formatter")
    check_value(params, "type", "LinearAxis", "CategoricalAxis")
    check_value(params, "pos", "below", "above")
    check_types(params,
                {"log","grid","num_minor_ticks","visible"},
                {"boolean","boolean","number","boolean"})
    
    add_axis(self, "x", params)
    return self
  end,

  y_axis = function(self, params) -- type, label, pos, log, grid, num_minor_ticks, visible, number_formatter
    params = params or {}
    check_table(params, "type", "label", "pos", "log", "grid", "num_minor_ticks",
                "visible", "number_formatter")
    check_value(params, "type", "LinearAxis", "CategoricalAxis")
    check_value(params, "pos", "left", "right")
    check_types(params,
                {"log","grid","num_minor_ticks","visible"},
                {"boolean","boolean","number","boolean"})
    
    add_axis(self, "y", params)
    return self
  end,

  x_range = function(self, a, b)
    axis_range(self, a, b, "x")
    return self
  end,

  y_range = function(self, a, b)
    axis_range(self, a, b, "y")
    return self
  end,

  drop_points = function(self, xmin, xmax, ymin, ymax)
    for _,source in ipairs(self._sources) do
      local data = source.attributes.data
      local new_data = {
        x = {},
        y = {},
      }
      local other_than_xy = {}
      for k,v in pairs(data) do
        if k~="x" and k~="y" then
          if type(v) == "table" then
            new_data[k] = {}
            table.insert(other_than_xy, k)
          else
            new_data[k] = v
          end
        end
      end
      local j=1
      for i=1,#data.x do
        local x,y = data.x[i],data.y[i]
        if xmin<=x and x<=xmax and ymin<=y and y<=ymax then
          new_data.x[j] = x
          new_data.y[j] = y
          for _,k in ipairs(other_than_xy) do
            new_data[k][j] = data[k][i]
          end
          j=j+1
        end
      end
      source.attributes.data = new_data
    end
    return self
  end,

  -- tools
  
  tool_box_select = function(self, select_every_mousemove)
    select_every_mousemove = default_true( select_every_mousemove )
    add_tool(self, "BoxSelectTool", { select_every_mousemove=select_every_mousemove, tags={}, doc=null })
    compile_glyph(self)
    return self
  end,
  
  tool_box_zoom = function(self, dimensions) -- { "width", "height" }
    dimensions = dimensions or { "width", "height" }
    add_tool(self, "BoxZoomTool", { dimensions=dimensions, tags={}, doc=null })
    compile_glyph(self)
    return self
  end,
  
  tool_crosshair = function(self)
    add_tool(self, "CrossHair", { tags={}, doc=null })
    compile_glyph(self)
    return self
  end,

  -- tool_hover = function(self, params)
  --   params = params or {}
  --   check_table(params, "always_active", "tooltips")
  --   local always_active = default_true( params.always_active )
  --   local tooltips = params.tooltips or "($x, $y)"
  --   add_tool(self, "HoverTool", { tags={}, doc=null, callback=null,
  --                                 always_active=always_active,
  --                                 mode="mouse", line_policy="prev",
  --                                 name=null, names={}, plot=self._docref,
  --                                 point_policy="snap_to_data",
  --                                 renderers={},
  --                                 tooltips=tooltips })
  --   compile_glyph(self)
  --   return self
  -- end,
  
  tool_lasso_select = function(self, select_every_mousemove)
    select_every_mousemove = default_true( select_every_mousemove )
    add_tool(self, "LassoSelectTool", { select_every_mousemove=select_every_mousemove, tags={}, doc=null })
    compile_glyph(self)
    return self
  end,
  
  tool_pan = function(self, dimensions) -- { "width", "height" }
    dimensions = dimensions or { "width", "height" }
    add_tool(self, "PanTool", { dimensions=dimensions, tags={}, doc=null })
    compile_glyph(self)
    return self
  end,
  
  tool_reset = function(self)
    add_tool(self, "ResetTool", { tags={}, doc=null })
    compile_glyph(self)
    return self
  end,
  
  tool_resize = function(self)
    add_tool(self, "ResizeTool", { tags={}, doc=null })
    compile_glyph(self)
    return self
  end,
  
  tool_save = function(self)
    add_tool(self, "PreviewSaveTool", { tags={}, doc=null })
    compile_glyph(self)
    return self
  end,
  
  tool_wheel_zoom = function(self, dimensions) -- { "width", "height" }
    dimensions = dimensions or { "width", "height" }
    add_tool(self, "WheelZoomTool", { dimensions=dimensions, tags={}, doc=null })
    compile_glyph(self)
    return self
  end,

  -- color functions

  color_last = function(self)
    return self._colors[ self._color_number + 1 ]
  end,

  color_num = function(self, i)
    assert(i>0 and i<=#self._colors,
           ("color number out-of-bounds [1,%d]"):format(#self._colors))
    return self._colors[i]
  end,
  
  -- layer functions

  lines = function(self, params) -- x, y, color, alpha, width, legend
    params = params or {}
    check_table(params, "x", "y", "color", "alpha", "width", "legend")
    check_mandatories(params, "x", "y")
    local x = toseries(params.x)
    local y = toseries(params.y)
    local color = params.color or next_color(self)
    local alpha = params.alpha or DEF_ALPHA
    local width  = params.width or DEF_WIDTH
    check_equal_sizes(x, y)
    -- local hover = toseries( params.hover )
    local data = { x=x, y=y, }
    local columns = { "x", "y" }

    local source_ref = add_column_data_source(self, data, columns)
    
    local attributes = {
      tags = {},
      doc = null,
      line_color = { value = color },
      line_alpha = { value = alpha },
      line_width = { value = width },
      x = { field = "x" },
      y = { field = "y" },
    }
    local lines_ref = add_simple_glyph(self, "Line", attributes)

    local renderer_ref = append_source_renderer(self, source_ref, lines_ref)

    if params.legend then add_legend(self, params.legend, renderer_ref) end
    
    return self
  end,

  bars = function(self, params) -- x, y, width, height, color, alpha, legend
    params = params or {}
    check_table(params, "x", "height", "width", "y", "color", "alpha", "legend")
    check_mandatories(params, "x")
    local x = toseries( extend(params.x or DEF_X, 1) )
    local y = toseries( extend(params.y or DEF_Y, #x) )
    local width = toseries( extend(params.width or DEF_WIDTH, #x) )
    local height = toseries( extend(params.height or DEF_HEIGTH, #x) )
    local color = toseries( extend(params.color or next_color(self), #x) )
    local alpha = toseries( extend(params.alpha or DEF_ALPHA, #x) )
    check_equal_sizes(x, y, width, height, color, alpha)
    -- local hover = toseries( params.hover )
    local data = { x=x, y=y, width=width, height=height, fill_alpha=alpha, color=color }
    local columns = { "x", "y", "width", "height", "fill_alpha", "color" }
    
    local source_ref = add_column_data_source(self, data, columns)
    
    local attributes = {
      tags = {},
      doc = null,
      fill_color = { field = "color" },
      fill_alpha = { field = "fill_alpha" },
      height = { units = "data", field = "height" },
      width = { units = "data", field = "width" },
      x = { field = "x" },
      y = { field = "y" },
    }
    local lines_ref = add_simple_glyph(self, "Rect", attributes)

    local renderer_ref = append_source_renderer(self, source_ref, lines_ref)

    if params.legend then add_legend(self, params.legend, renderer_ref) end
    
    return self
  end,

  points = function(self, params) -- x, y, glyph, color, alpha, size, legend
    params = params or {}
    check_table(params, "x", "y", "glyph", "color", "alpha", "size",
                "legend")
    check_value(params, "glyph", "Circle", "Triangle")
    check_mandatories(params, "x", "y")
    local x = toseries(params.x)
    local y = toseries(params.y)
    local color = toseries( extend(params.color or next_color(self), #x) )
    local alpha = toseries( extend(params.alpha or DEF_ALPHA, #x) )
    local size  = toseries( extend(params.size or DEF_SIZE, #x) )
    check_equal_sizes(x, y, color, alpha, size)
    -- local hover = toseries( params.hover )
    local data = {
      x = x,
      y = y,
      color = color,
      fill_alpha = alpha,
      size = size,
      -- hover = hover,
    }
    local columns = { "x", "y", "fill_alpha", "color", "size" }
    -- if hover then table.insert(columns, "hover") end

    local source_ref = add_column_data_source(self, data, columns)
    
    local attributes = {
      tags = {},
      doc = null,
      fill_color = { field = "color" },
      fill_alpha = { field = "fill_alpha" },
      size = { field = "size" },
      x = { field = "x" },
      y = { field = "y" },
    }
    local points_ref = add_simple_glyph(self, params.glyph or "Circle",
                                        attributes)

    local renderer_ref = append_source_renderer(self, source_ref, points_ref)

    if params.legend then add_legend(self, params.legend, renderer_ref) end
    
    return self
  end,

  hist2d = function(self, params) -- x, y, glyph, color, alpha, size, legend, xgrid, ygrid
    params = params or {}
    check_table(params, "x", "y", "glyph", "color", "alpha", "size", "legend",
                "xgrid", "ygrid")
    check_value(params, "glyph", "Circle")
    check_mandatories(params, "x", "y")
    check_types(params,
                { "color", "alpha", "size" },
                { "string", "number", "number" })
    local x = toseries(params.x)
    local y = toseries(params.y)
    local color = params.color or next_color(self)
    local alpha = params.alpha or DEF_ALPHA
    local size  = params.size or 2*DEF_SIZE
    local xgrid = params.xgrid or DEF_XGRID
    local ygrid = params.ygrid or DEF_YGRID
    check_equal_sizes(x, y)
    local x_min,x_max = minmax(x)
    local y_min,y_max = minmax(y)
    local x_width = (x_max - x_min) / (xgrid-1)
    local y_width = (y_max - y_min) / (ygrid-1)
    local cols = {}
    for i=1,xgrid*ygrid do cols[i] = 0 end
    local max_count = 0
    for i=1,#x do
      local ix = math.floor((x[i]-x_min)/x_width)
      local iy = math.floor((y[i]-y_min)/y_width)
      local k = iy*xgrid + ix + 1
      cols[k] = cols[k] + 1
      if cols[k] > max_count then max_count= cols[k] end
    end
    local x_off = x_width*0.5
    local y_off = y_width*0.5
    local new_x,new_y,new_sizes = {},{},{}
    local l=1
    for i=0,xgrid-1 do
      for j=0,ygrid-2 do
        local k = j*xgrid + i + 1
        if cols[k] > 0 then
          new_x[l] = i*x_width + x_min + x_off
          new_y[l] = j*y_width + y_min + y_off
          new_sizes[l] = size * cols[k]/max_count
          l = l + 1
        end
      end
    end
    x,y,size = new_x,new_y,new_sizes
    
    return self:points{ x=x, y=y, size=size, alpha=alpha, color=color,
                        glyph=params.glyph, legend=params.legend }
  end,
  
  -- conversion

  to_json = function(self)
    check_axis_range(self)
    local doc_json = json.encode(self._doc)
    local tbl = { doc_json }
    for i=2,#self._list do
      local v = self._list[i]
      if type(v) ~= "string" then v = json.encode(v) end
      tbl[#tbl+1] = v
    end
    collectgarbage("collect")
    return ("[%s]"):format(table.concat(tbl, ","))
  end,
  
}

local figure_mt = {
  __index = figure_methods,
  
  ipylua_show = function(self)
    local html = html_template:gsub("$([A-Z]+)",
                                    {
                                      SCRIPTID = uuid.new(),
                                      MODELTYPE = self._doc.type,
                                      MODELID = self._doc.id,
                                      MODEL = self:to_json(),
                                    }
    )
    return {
      ["text/html"] = html,
      ["text/plain"] = "-- impossible to show ASCII art plots",
    }
  end,
}
  
setmetatable(
  figure,
  {
    __call = function(_,params)
      params = params or {}
      
      local function default(name, value)
        params[name] = params[name] or value
      end

      default("tools", { "pan", "wheel_zoom", "box_zoom", "resize", "reset", "save" })
      default("width",  500)
      default("height", 400)
      default("title",  nil) -- not necessary but useful to make it explicit
      default("xlab",  nil)
      default("ylab",  nil)
      default("xlim",  nil)
      default("ylim",  nil)
      default("padding_factor",  0.07)
      default("xgrid",  true)
      default("ygrid",  true)
      default("xaxes",  {"below"})
      default("yaxes",  {"left"})
      -- ??? default("theme",  "bokeh_theme") ???
      
      local self = { _list = {}, _references={}, _dict = {},
                     _color_number = #COLORS - 1, _colors = COLORS,
                     _sources = {} }
      setmetatable(self, figure_mt)
      
      self._docref,self._doc =
        add_simple_glyph(self, "Plot",
                         {
                           plot_width = params.width,
                           plot_height = params.height,
                           title = params.title,
                           --
                           x_range = nil,
                           y_range = nil,
                           extra_x_ranges = {},
                           extra_y_ranges = {},
                           id = plot_id,
                           tags = {},
                           title_text_font_style = "bold",
                           title_text_font_size = { value = "12pt" },
                           tools = {},
                           renderers = {},
                           below = {},
                           above = {},
                           left = {},
                           right = {},
                           responsive = false,
                         },
                         "Chart")
      
      tool_events(self)
      
      for _,name in ipairs(params.tools) do self["tool_" .. name](self) end
      
      for _,pos in ipairs(params.xaxes) do
        self:x_axis{ label=params.xlab, log=false, grid=params.xgrid,
                     num_minor_ticks=5, visible=true, number_formatter=tostring,
                     type="LinearAxis", pos=pos }
      end
      
      for _,pos in ipairs(params.yaxes) do
        self:y_axis{ label=params.ylab, log=false, grid=params.ygrid,
                     num_minor_ticks=5, visible=true, number_formatter=tostring,
                     type="LinearAxis", pos=pos }
      end
      
      return self
    end
  }
)

-- color transformers

-- http://www.andrewnoske.com/wiki/Code_-_heatmaps_and_color_gradients
local function linear_color_transformer(x)
  local x = toseries(x)
  assert(type(x) == "table", "needs a series as input")
  local min,max = minmax(x)
  local diff = max-min
  local color = {}
  -- 4 colors: blue, green, yellow, red
  local COLORS = { {0,0,255}, {0,255,0}, {255,255,0}, {255,0,0} }
  for i=1,#x do
    local idx1,idx2 -- our desired color will be between these two indexes in COLORS
    local fract = 0 -- fraction between idx1 and idx2
    local v = (x[i] - min) / diff
    if v <= 0 then
      idx1,idx2 = 1,1
    elseif v >= 1 then
      idx1,idx2 = #COLORS,#COLORS
    else
      v     = v * (#COLORS-1)
      idx1  = math.floor(v) + 1
      idx2  = idx1+1
      fract = v - (idx1 - 1)
    end
    local r = round( (COLORS[idx2][1] - COLORS[idx1][1])*fract + COLORS[idx1][1] )
    local g = round( (COLORS[idx2][2] - COLORS[idx1][2])*fract + COLORS[idx1][2] )
    local b = round( (COLORS[idx2][3] - COLORS[idx1][3])*fract + COLORS[idx1][3] )
    color[i] = ("#%02x%02x%02x"):format(r, g, b)
  end
  return color
end

local function linear_size_transformer(x, smin, smax)
  local x = toseries(x)
  assert(type(x) == "table", "needs a series as 1st argument")
  assert(smin and smax, "needs two numbers as 2nd and 3rd arguments")
  local sdiff = smax - smin
  local min,max = minmax(x)
  local diff = max-min
  local size = {}
  for i=1,#x do
    local v = (x[i] - min) / diff
    size[i] = v*sdiff + smin
  end
  return size
end

return {
  figure = figure,
  colors = {
    linear = linear_color_transformer,
  },
  sizes = {
    linear = linear_size_transformer,
  },
}
