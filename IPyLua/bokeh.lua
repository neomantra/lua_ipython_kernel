local json = require "IPyLua.dkjson"
local uuid = require "IPyLua.uuid"
local html_template = require "IPyLua.html_template"
local null = json.null
local type = luatype or type

local DEF_ALPHA = 0.8
local DEF_BOX_WIDTH = 0.5
local DEF_BREAKS = 20
local DEF_HEIGTH = 6
local DEF_LEVEL = "__nil__"
local DEF_LINE_WIDTH = 2
local DEF_SIZE = 6
local DEF_VIOLIN_WIDTH=0.90
local DEF_WIDTH = 6
local DEF_X = 0
local DEF_XGRID = 100
local DEF_Y = 0
local DEF_YGRID = 100
local EPSILON = 1e-06

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

local math_abs = math.abs
local math_floor = math.floor
local math_min = math.min
local math_max = math.max

local figure = {}
local figure_methods = {}

-- forward declarations
local box_transformation
local hist2d_transformation
local linear_color_transformer
local linear_size_transformer
------------------------------

local pi4 = math.pi/4.0
local function cor2angle(c)
  if c < 0 then return pi4 else return -pi4 end
end

local function cor2width(c)
  return math_max(EPSILON, 1.0 - math.abs(c))
end

local function quantile(tbl, q)
  local N = #tbl
  local pos = (N+1)*q
  local pos_floor,pos_ceil,result = math.floor(pos),math.ceil(pos)
  local result
  if pos_floor == 0 then
    return tbl[1]
  elseif pos_floor >= N then
    return tbl[N]
  else
    local dec = pos - pos_floor
    local a,b = tbl[pos_floor],tbl[pos_ceil]
    return a + dec * (b - a)
  end
end

local function take_outliers(tbl, upper, lower)
  local result = {}
  for i=1,#tbl do
    local x = tbl[i]
    if x < lower or x > upper then result[#result+1] = x end
  end
  return result
end

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

local function min(t)
  local t  = t or 0.0
  local tt = type(t)
  if tt == "table" or tt == "userdata" then
    return reduce(t, math_min)
  else
    return t
  end
end

local function max(t)
  local t  = t or 0.0
  local tt = type(t)
  if tt == "table" or tt == "userdata" then
    return reduce(t, math_max)
  else
    return t
  end
end

local function minmax(t, size)
  local t = t or 0.0
  local size = size or 0.0
  local tmin,tmax
  local tt = type(t)
  if tt == "table" or tt == "userdata" then
    if type(size) == "table" or type(size) == "userdata" then
      local s = size[1] * 0.5
      tmin = t[1] - s
      tmax = t[1] + s
      for i=2,#t do
        local s = size[i] * 0.5
        tmin = math_min(tmin, t[i] - s)
        tmax = math_max(tmax, t[i] + s)
      end
    else
      assert(type(size) == "number",
             "Needs a series or number as second parameter")
      local s = size * 0.5
      tmin = t[1] - s
      tmax = t[1] + s
      for i=2,#t do
        tmin = math_min(tmin, t[i] - s)
        tmax = math_max(tmax, t[i] + s)
      end
    end
  else
    local s = max(size) * 0.5
    tmin = t - s 
    tmax = t + s
  end
  return tmin,tmax
end

local function factors(t, out, dict)
  local out,dict = out or {},dict or {}
  if type(t) == "table" or type(t) == "userdata" then
    for i=1,#t do
      local s = tostring(t[i])
      if not dict[s] then
        out[#out+1],dict[s] = s,true
      end
    end
  else
    local s = tostring(t)
    if not dict[s] then
      out[#out+1],dict[s] = s,true
    end
  end
  return out,dict
end

local function apply_gap(p, a, b)
  local gap = p * (b-a)
  return a-gap, b+gap
end

local function tomatrix(m)
  local tt = type(m)
  if tt == "table" then return m end
  if tt == "userdata" then
    mt = getmetatable(m)
    if mt.__index and mt.__len then return m end
  end
  error("Improper data type")
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
    else
      error(("series data type %s cannot be handled: " ):format(tt))
    end
  else
    return s
  end
end

local function invert(t)
  local r = {}
  for k,v in pairs(t) do r[v] = k end
  return r
end

local function compute_optim(x, DEF)
  local optim
  local x = toseries(x)
  if not x or type(x) == "number" then
    optim = DEF
  elseif type(x) == "string" then
    optim = 1.0
  else
    if type(x[1]) == "string" then
      optim = 1.0
    else
      local t = {}
      for i=1,#x do t[i] = x[i] end table.sort(t)
      optim = math.huge
      for i=2,#t do optim = math_min( optim, math_abs( t[i-1] - t[i] ) ) end
    end
  end
  return optim
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

local function create_data_columns(data, more_data)
  local N
  local s_data,columns = {},{}
  
  local function process(k, v)
    local v  = toseries(v)
    local tt = type(v)
    if tt == "table" or tt == "userdata" then
      local M = #v
      assert(not N or N==M, "Found different series sizes")
      N = M
      s_data[k] = v
      table.insert(columns, k)
    end
  end
  
  for k,v in pairs(data)      do process( k, v ) end
  for k,v in pairs(more_data) do process( k, v ) end
  
  return s_data,columns,s_more_data
end

local function create_simple_glyph_attributes(data, more_data, translate)
  local attributes = { tags={}, doc=null }
  for _,tbl in ipairs{ data, more_data } do
    for k,v in pairs(tbl) do
      local units
      local tt = type(v)
      if k == "height" or k == "width" then units = "data" end
      if tt == "table" or tt == "userdata" then
        attributes[ translate[k] or k ] = { units = units, field = k }
      else
        attributes[ translate[k] or k ] = { units = units, value = v }
      end
    end
  end
  return attributes
end

local function next_color(self)
  self._color_number = (self._color_number + 1) % #self._colors
  local color = self._colors[ self._color_number + 1]
  return color
end

local function check_axis_range(self)
  local glyphs = self._glyphs
  
  if not self._doc.attributes.x_range then
    local axis = self._doc.attributes.below[1] or self._doc.attributes.above[1]
    if axis.type == "LinearAxis" then
      local x_min,x_max = math.huge,-math.huge
      for _,source in ipairs(self._sources) do
        local s_min,s_max = minmax(source.attributes.data.x or
                                     (glyphs[source.id].attributes.x or {}).value,
                                   source.attributes.data.width or
                                     (glyphs[source.id].attributes.width or {}).value)
        
        x_min = math.min(x_min,s_min)
        x_max = math.max(x_max,s_max)
      end
      self:x_range( apply_gap(0.05, x_min, x_max) )
    else
      local list,dict = {},{}
      for _,source in ipairs(self._sources) do
        list,dict = factors(source.attributes.data.x or
                              (glyphs[source.id].attributes.x or {}).value,
                            list, dict)
      end
      self:x_range(list)
    end
  end

  if not self._doc.attributes.y_range then
    local axis = self._doc.attributes.left[1] or self._doc.attributes.right[1]
    if axis.type == "LinearAxis" then
      local y_min,y_max = math.huge,-math.huge
      for _,source in ipairs(self._sources) do
        local s_min,s_max = minmax(source.attributes.data.y or
                                     (glyphs[source.id].attributes.y or {}).value,
                                   source.attributes.data.height or
                                     (glyphs[source.id].attributes.height or {}).value)
        
        y_min = math.min(y_min, s_min)
        y_max = math.max(y_max, s_max)
      end
      self:y_range( apply_gap(0.05, y_min, y_max) )
    else
      local list,dict
      for _,source in ipairs(self._sources) do
        list,dict = factors(source.attributes.data.y or
                              (glyphs[source.id].attributes.y or {}).value,
                            list, dict)
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

local function add_simple_glyph(self, name, attributes, subtype, source_ref)
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
  if source_ref then self._glyphs[source_ref.id] = glyph end
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
  
  local formatter_type = "BasicTickFormatter"
  local ticker_type = "BasicTicker"
  
  if params.type == "CategoricalAxis" then
    formatter_type = "CategoricalTickFormatter"
    ticker_type = "CategoricalTicker"
  end
  
  local doc_axis = self._doc.attributes[params.pos]
  if not doc_axis[1] then
    
    local formatter_ref,formatter = add_simple_glyph(self, formatter_type,
                                                     { tags={}, doc=null })
    
    local ticker_ref,ticker =
      add_simple_glyph(self, ticker_type,
                       { tags={}, doc=null, mantissas={2, 5, 10},
                         num_minor_ticks=params.num_minor_ticks })
    
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
    if params.label then axis.attributes.axis_label = params.label end
    if params.type then
      axis.type = params.type
      local formatter_id = axis.attributes.formatter.id
      local ticker_id    = axis.attributes.ticker.id
      local formatter    = self._dict[ formatter_id ]
      local ticker       = self._dict[ ticker_id ]
      formatter.type     = formatter_type
      ticker.type        = ticker_type
      update_references(self, formatter_id, formatter)
      update_references(self, ticker_id, ticker)
    end
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

  crop_points = function(self, xmin, xmax, ymin, ymax)
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
  
  tool_hover = function(self, params) -- always_active, tooltips
    params = params or {}
    check_table(params, "always_active", "tooltips")
    local always_active = default_true( params.always_active )
    local tooltips = params.tooltips or
      {
        {"Tag", "@hover"},
        {"(x,y)", "($x, $y)"}
      }
    add_tool(self, "HoverTool", { tags={},
                                  doc=null,
                                  callback=null,
                                  always_active=always_active,
                                  name=null,
                                  names={},
                                  plot=self._docref,
                                  point_policy="follow_mouse",
                                  renderers={},
                                  tooltips=tooltips })
    compile_glyph(self)
    return self
  end,
  
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
  
  boxes = function(self, params) -- min, max, q1, q2, q3, x, outliers, width, alpha, legend, color
    check_table(params, "min", "max", "q1", "q2", "q3", "x",
                "outliers", "width", "alpha", "legend", "color")
    
    check_mandatories(params, "min", "max", "q1", "q2", "q3", "x")

    local x   = params.x
    local min = params.min
    local max = params.max
    local q1  = params.q1
    local q2  = params.q2
    local q3  = params.q3
    local outliers = params.outliers
    local width = params.width or DEF_BOX_WIDTH
    local alpha = params.alpha or DEF_ALPHA

    local box_height = {}
    local box_mid = {}
    local line_height = {}
    local line_mid = {}
    local max_height = 0
    for i=1,#x do
      box_mid[i]     = (q1[i] + q3[i])/2.0
      box_height[i]  = q3[i] - q1[i]
      line_mid[i]    = (max[i] + min[i])/2.0
      line_height[i] = max[i] - min[i]
      if box_height[i] > max_height then max_height = box_height[i] end
    end

    local color = params.color or next_color(self)

    self:bars{ x = x,
               y = line_mid,
               height = line_height,
               width = width * 0.005,
               alpha = alpha,
               color = color,
               line_color = "#000000", }
    
    self:bars{ x = x,
               y = box_mid,
               height = box_height,
               width = width,
               color = color,
               alpha = alpha,
               legend = params.legend,
               line_color = "#000000", }

    self:bars{ x = x,
               y = q2,
               height = 0.005 * max_height,
               width = width,
               alpha = alpha,
               color = "#000000", }

    self:bars{ x = x,
               y = min,
               height = 0.005 * max_height,
               width = width * 0.3,
               alpha = alpha,
               color = color,
               line_color = "#000000", }

    self:bars{ x = x,
               y = max,
               height = 0.005 * max_height,
               width = width * 0.3,
               alpha = alpha,
               color = color,
               line_color = "#000000", }

    -- FIXME: check sizes
    if outliers then
      for i=1,#x do
        if outliers[i] and #outliers[i] > 0 then
          local list = {}
          for j=1,#outliers[i] do list[j] = x[i] end
          self:points{ x = list,
                       y = outliers[i],
                       color = color,
                       alpha = alpha, }
          --xgrid = 1, }
        end
      end
    end

    self:x_axis{ type="CategoricalAxis", pos="below" }
    
    return self
  end,
  
  boxplot = function(self, params) -- x, y, legend, alpha, color, factors, width, ignore_outliers
    
    local boxes =
      box_transformation( params,
                          {
                            legend=params.legend,
                            alpha=params.alpha,
                            color=params.color,
                          }
      )

    return self:boxes( boxes )
    
  end,
  
  lines = function(self, params) -- x, y, color, alpha, width, legend, more_data
    params = params or {}
    check_table(params, "x", "y", "color", "alpha", "width", "legend", "more_data")
    check_mandatories(params, "x", "y")
    local x = params.x
    local y = params.y
    local color = params.color or next_color(self)
    local alpha = params.alpha or DEF_ALPHA
    local width  = params.width or DEF_LINE_WIDTH
    
    local data = { x=x, y=y, width=width, alpha=alpha, color=color }
    local more_data = params.more_data or {}
    
    local s_data,s_columns,s_more_data = create_data_columns(data, more_data)
    
    local source_ref = add_column_data_source(self, s_data, s_columns)
    
    local attributes =
      create_simple_glyph_attributes(data, more_data,
                                     { color="line_color",
                                       alpha="line_alpha",
                                       width="line_width", })
    
    local lines_ref = add_simple_glyph(self, "Line", attributes, nil, source_ref)

    local renderer_ref = append_source_renderer(self, source_ref, lines_ref)

    if params.legend then add_legend(self, params.legend, renderer_ref) end
    
    return self
  end,

  bars = function(self, params) -- x, y, width, height, color, alpha, legend, hover, more_data
    params = params or {}
    check_table(params, "x", "height", "width", "y", "color", "alpha",
                "legend", "hover", "more_data", "line_color")
    check_mandatories(params, "x")
    local x = params.x or DEF_X
    local y = params.y or DEF_Y
    local width = params.width or "auto"
    local height = params.height or "auto"
    local color = params.color or next_color(self)
    local alpha = params.alpha or DEF_ALPHA
    local hover = params.hover
    local line_color = params.line_color
    
    if width == "auto" then width = compute_optim(x, DEF_WIDTH) end
    if height == "auto" then height = compute_optim(y, DEF_HEIGTH) end
    
    local data = {
      x=x,
      y=y,
      width=width,
      height=height,
      fill_alpha=alpha,
      color=color,
      hover=hover,
      line_color=line_color,
    }
    local more_data = params.more_data or {}
    
    local s_data,s_columns,s_more_data = create_data_columns(data, more_data)
    
    local source_ref = add_column_data_source(self, s_data, s_columns)
    
    local attributes =
      create_simple_glyph_attributes(data, more_data,
                                     { color="fill_color" })
    
    local lines_ref = add_simple_glyph(self, "Rect", attributes, nil, source_ref)

    local renderer_ref = append_source_renderer(self, source_ref, lines_ref)

    if params.legend then add_legend(self, params.legend, renderer_ref) end
    
    return self
  end,
  
  corplot = function(self, params) -- xy, names, alpha, legend
    params = params or {}
    check_table(params, "xy", "names", "alpha", "legend")
    check_mandatories(params, "xy")
    local alpha = params.alpha or DEF_ALPHA
    local hover = params.hover

    local names = params.names or {}
    local xy = tomatrix( params.xy )

    local bars_x = {}
    local bars_y = {}
    local bars_cor = {}

    local ovals_x     = {}
    local ovals_y     = {}
    local ovals_w     = {}
    local ovals_h     = {}
    local ovals_cor   = {}
    local ovals_angle = {}
    local text = {}
    local text_angle = {}
    
    local N = #xy
    for i=N,1,-1 do
      local row = toseries( xy[i] )
      assert(#row == N, "Needs a squared matrix as input")
      for j=1,#row do
        local c = row[j]
        if j>i then
          local a = cor2angle(c)
          table.insert(ovals_x, names[j] or j)
          table.insert(ovals_y, names[i] or i)
          table.insert(ovals_angle, a)
          table.insert(ovals_w, 0.9 * cor2width(c))
          table.insert(ovals_cor, c)
          table.insert(text, ("%.3f"):format(c))
          table.insert(text_angle, -a)
        else
          table.insert(bars_x, names[j] or j)
          table.insert(bars_y, names[i] or i)
          table.insert(bars_cor, c)
        end
      end
    end
    
    local bars_data = {
      x=bars_x,
      y=bars_y,
      width=1.0,
      height=1.0,
      alpha=alpha,
      color=linear_color_transformer(bars_cor, -1.0, 1.0),
      hover=bars_cor,
      legend=params.legend,
    }
    bars_data.line_color = bars_data.color

    self:bars( bars_data )
    
    local ovals_data = {
      x=ovals_x,
      y=ovals_y,
      alpha=alpha,
      color=linear_color_transformer(ovals_cor, -1.0, 1.0),
      legend=params.legend,
      glyph="Oval",
      more_data = {
        angle=ovals_angle,
        width=ovals_w,
        height=0.9,
      }
    }
    
    self:points( ovals_data )

    local text_data = {
      x = ovals_x,
      y = ovals_y,
      color = "#000000",
      glyph = "Text",
      alpha = 1.0,
      more_data = {
        angle = text_angle,
        text = text,
        text_font_style="bold",
        text_color = "#000000",
        text_alpha = 1.0,
        text_align = "center",
        text_baseline = "middle",
      }
    }

    self:points( text_data )
    
    if names then
      self:x_axis{ type="CategoricalAxis", pos="below" }
      self:y_axis{ type="CategoricalAxis", pos="left" }
    end
    
    return self
  end,

  points = function(self, params) -- x, y, glyph, color, alpha, size, legend, hover, more_data
    params = params or {}
    check_table(params, "x", "y", "glyph", "color", "alpha", "size",
                "legend", "hover", "more_data")
    check_value(params, "glyph", "Circle", "Triangle", "Oval", "Text")
    check_mandatories(params, "x", "y")
    local x = params.x
    local y = params.y
    local color = params.color or next_color(self)
    local alpha = params.alpha or DEF_ALPHA
    local size  = params.size or DEF_SIZE
    local hover = params.hover
    
    local data = {
      x=x,
      y=y,
      color = color,
      fill_alpha = alpha,
      size = size,
      hover = hover,
    }
    local more_data = params.more_data or {}
    
    local s_data,s_columns = create_data_columns(data, more_data)
    
    local source_ref = add_column_data_source(self, s_data, s_columns)
    
    local attributes =
      create_simple_glyph_attributes(data, more_data,
                                     { color="fill_color", })
    
    local points_ref = add_simple_glyph(self, params.glyph or "Circle",
                                        attributes, nil, source_ref)

    local renderer_ref = append_source_renderer(self, source_ref, points_ref)

    if params.legend then add_legend(self, params.legend, renderer_ref) end
    
    return self
  end,

  hist2d = function(self, params) -- x, y, glyph, color, alpha, size, legend, xgrid, ygrid
    params = params or {}
    local hist2d = hist2d_transformation(
      { x = params.x,
        y = params.y,
        minsize = params.minsize,
        maxsize = params.maxsize,
        xgrid = params.xgrid,
        ygrid = params.ygrid,
      },
      {
        glyph  = params.glyph,
        color  = params.color,
        alpha  = params.alpha,
        legend = params.legend,
      }
    )
    return self:points( hist2d )
  end,

  vioplot = function(self, params) -- x, y, legend, alpha, color, factors, width
    
    local color = params.color or next_color(self)
    
    local violins =
      violin_transformation(params,
                            {
                              alpha = params.alpha,
                              legend = params.legend,
                              color = color,
                              line_color = color,
                            }
      )
    
    for i=1,#violins.bars do
      self:bars(violins.bars[i])
    end
    
    self:boxes(violins.boxes)
    
    self:x_axis{ type="CategoricalAxis", pos="below" }
    
    return self
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
    __call = function(_,params) -- tools, height, title, xlab, ylab, xlim, ylim, padding_factor, xgrid, ygrid, xaxes, yaxes, tooltips
      params = params or {}
      
      local function default(name, value)
        params[name] = params[name] or value
      end

      default("tools", { "pan", "wheel_zoom", "box_zoom", "resize",
                         "reset", "save", "hover" })
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
      default("tooltips", nil)
      -- ??? default("theme",  "bokeh_theme") ???
      
      local self = { _list = {}, _references={}, _dict = {},
                     _color_number = #COLORS - 1, _colors = COLORS,
                     _sources = {}, _glyphs = {} }
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
      
      for _,name in ipairs(params.tools) do
        if name == "hover" then
          self["tool_" .. name](self, { tooltips = params.tooltips })
        else
          self["tool_" .. name](self)
        end
      end
      
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

-- data transformers

local function hist(x, breaks, output_type, scale)
  local result = {}
  local min    = x[1]
  local max    = x[#x]
  local diff   = max - min
  assert(diff > 0, "Unable to compute histogram for given data")
  local inc    = diff / breaks
  local half   = inc * 0.5
  local bins   = {}
  local width  = {}
  local y      = {}
  local max    = 0.0
  for i=1,breaks do
    bins[i] = 0.0
    y[i] = (i - 1.0) * inc + half + min
  end
  for i=1,#x do
    local b = math_floor( (x[i] - min)/diff * breaks ) + 1.0
    b = math_max(0.0, math_min(breaks, b))
    bins[b] = bins[b] + 1.0
    max = math_max(max, bins[b])
  end
  local scale = scale or 1.0
  for i=1,#bins do width[i] = (bins[i]/max)*scale end
  if output_type == "ratio" then
    local scale = scale or 1.0
    local N = #x for i=1,#bins do bins[i] = (bins[i]/N) end
  elseif scale then
    for i=1,#bins do bins[i] = bins[i] end
  end
  return { y=y, width=width, height=inc, bins=bins, }
end

--
function box_transformation(params, more_params) -- x, y, factors, width, ignore_outliers
  local x = toseries( params.x )
  local y = toseries( params.y )

  assert(type(y) == "table" or type(y) == "userdata")

  local boxes = {
    min      = {},
    max      = {},
    q1       = {},
    q2       = {},
    q3       = {},
    outliers = {},
    width    = {},
    x        = {},
  }

  local DEF_LEVEL = DEF_LEVEL
  local levels
  if not params.factors then
    if type(x) == "table" or type(x) == "userdata" then
      levels = factors(x)
    else
      DEF_LEVEL = x or DEF_LEVEL
      levels = { DEF_LEVEL }
    end
  else
    local aux = params.factors
    levels = {}
    for i=1,#aux do levels[i] = tostring(aux[i]) end
  end
  
  local plt = {}
  for i,factor in ipairs(levels) do plt[factor] = {} end
  
  for i=1,#y do
    local key = x and x[i] and tostring(x[i]) or DEF_LEVEL
    assert( plt[key], "found unknown factor level " .. key )
    table.insert( plt[key], y[i] )
  end
  
  for i,factor in ipairs(levels) do
    
    local cur = plt[factor]
    table.sort(cur)
    
    local q1 = quantile(cur, 0.25)
    local q2 = quantile(cur, 0.50)
    local q3 = quantile(cur, 0.75)
    local IQ = q3 - q1
    
    local min = params.min or quantile(cur, 0.0)
    local max = params.max or quantile(cur, 1.0)
    
    local upper = math.min(q3 + 1.5 * IQ, max)
    local lower = math.max(q1 - 1.5 * IQ, min)
    
    local outliers
    if not params.ignore_outliers then
      outliers = take_outliers(cur, upper, lower)
    end
    
    boxes.min[i]      = upper
    boxes.max[i]      = lower
    boxes.q1[i]       = q1
    boxes.q2[i]       = q2
    boxes.q3[i]       = q3
    boxes.outliers[i] = outliers
    boxes.width       = params.width or DEF_BOX_WIDTH
    boxes.x[i]        = tostring( factor )

  end
  
  for k,v in pairs(more_params or {}) do
    assert(k ~= "more_data", "Unable to handle more_data argument")
    assert(not boxes[k], "Unable to redefine parameter " .. k)
    boxes[k]=v
  end
  
  return boxes
end

-- local hist2d_transformation is declared at the top of this file
function hist2d_transformation(params, more_params) -- x, y, minsize, maxsize, xgrid, ygrid
  params = params or {}
  check_table(params, "x", "y", "maxsize", "minsize", "xgrid", "ygrid")
  check_mandatories(params, "x", "y")
  check_types(params,
              { "minsize", "maxsize" },
              { "number", "number" })
  local x = toseries(params.x)
  local y = toseries(params.y)
  local maxsize = params.maxsize or 2*DEF_SIZE
  local minsize = params.minsize or 0.5*DEF_SIZE
  local xgrid = params.xgrid or DEF_XGRID
  local ygrid = params.ygrid or DEF_YGRID
  assert(minsize <= maxsize, "failure of predicate minsize < maxsize")
  check_equal_sizes(x, y)
  local x_min,x_max = assert( minmax(x) )
  local y_min,y_max = assert( minmax(y) )
  local x_width,y_width,x_off,y_off
  if xgrid == 1 or x_max == x_min then
    x_width = math.max(1.0, x_max - x_min)
    x_off = 0.0
  else
    x_width = (x_max - x_min) / (xgrid-1)
    x_off = x_width*0.5
  end
  if ygrid == 1 or y_max == y_min then
    y_width = math.max(1.0, y_max - y_min)
    y_off = 0.0
  else
    y_width = (y_max - y_min) / (ygrid-1)
    y_off = y_width*0.5
  end
  local grid = {}
  for i=1,xgrid*ygrid do grid[i] = 0 end
  local max_count = 0
  for i=1,#x do
    local ix = math.floor((x[i]-x_min)/x_width)
    local iy = math.floor((y[i]-y_min)/y_width)
    local k = iy*xgrid + ix + 1
    grid[k] = grid[k] + 1
    if grid[k] > max_count then max_count= grid[k] end
  end
  local size_diff = maxsize - minsize
  local new_x,new_y,new_sizes,counts,ratios = {},{},{},{},{}
  local l=1
  for i=0,xgrid-1 do
    for j=0,ygrid-2 do
      local k = j*xgrid + i + 1
      if grid[k] > 0 then
        local ratio = grid[k]/max_count
        new_x[l] = i*x_width + x_min + x_off
        new_y[l] = j*y_width + y_min + y_off
        new_sizes[l] = minsize + size_diff * ratio
        counts[l] = grid[k]
        ratios[l] = ratio
        l = l + 1
      end
    end
  end

  local result = {
    x = new_x,
    y = new_y,
    size = new_sizes,
    more_data = {
      count = counts,
      ratio = ratios,
    },
  }
  for k,v in pairs(more_params or {}) do
    assert(k ~= "more_data", "Unable to handle more_data argument")
    result[k]=v
  end
  
  return result
end

function violin_transformation(params, more_params) -- x, y, factors, width, breaks
  local breaks = params.breaks or DEF_BREAKS
  local width  = params.width or DEF_VIOLIN_WIDTH
  local more_params = more_params or {}
  local x = toseries( params.x )
  local y = toseries( params.y )

  assert(type(y) == "table" or type(y) == "userdata")

  local violins = {
    bars  = {},
    boxes = {
      min      = {},
      max      = {},
      q1       = {},
      q2       = {},
      q3       = {},
      outliers = {},
      width    = {},
      x        = {},
    },
  }

  local DEF_LEVEL = DEF_LEVEL
  local levels
  if not params.factors then
    if type(x) == "table" or type(x) == "userdata" then
      levels = factors(x)
    else
      DEF_LEVEL = x or DEF_LEVEL
      levels = { DEF_LEVEL }
    end
  else
    local aux = params.factors
    levels = {}
    for i=1,#aux do levels[i] = tostring(aux[i]) end
  end
  
  local plt = {}
  for i,factor in ipairs(levels) do plt[factor] = {} end
  
  for i=1,#y do
    local key = x and x[i] and tostring(x[i]) or DEF_LEVEL
    assert( plt[key], "found unknown factor level " .. key )
    table.insert( plt[key], y[i] )
  end
  
  for i,factor in ipairs(levels) do
    local cur = plt[factor]
    table.sort(cur)
    
    local bars = violins.bars
    local h = hist(cur, breaks, "ratio", width)
    
    bars[i] = {
      x      = tostring( factor ),
      y      = h.y,
      width  = h.width,
      height = h.height,
      hover  = h.bins,
    }

    local boxes = violins.boxes
    local q1 = quantile(cur, 0.25)
    local q2 = quantile(cur, 0.50)
    local q3 = quantile(cur, 0.75)
    local IQ = q3 - q1
    
    local min = quantile(cur, 0.0)
    local max = quantile(cur, 1.0)
    
    local upper = math.min(q3 + 1.5 * IQ, max)
    local lower = math.max(q1 - 1.5 * IQ, min)
    
    boxes.x[i]        = tostring( factor )
    boxes.min[i]      = upper
    boxes.max[i]      = lower
    boxes.q1[i]       = q1
    boxes.q2[i]       = q2
    boxes.q3[i]       = q3
    boxes.width       = width * 0.05
    boxes.alpha       = 1.0
    boxes.color       = more_params.color
    
    for k,v in pairs(more_params) do
      assert(k ~= "more_data", "Unable to handle more_data argument")
      assert(not bars[i][k], "Unable to redefine parameter " .. k)
      bars[i][k]=v
    end
  end
  
  return violins
end

-- color transformers

-- http://www.andrewnoske.com/wiki/Code_-_heatmaps_and_color_gradients
function linear_color_transformer(x, xmin, xmax)
  local x = toseries(x)
  assert(type(x) == "table", "needs a series as input")
  if not xmin and xmax then xmin = min(x) end
  if not xmax and xmin then xmax = max(x) end
  local min,max = xmin,xmax
  if not min and not max then min,max = minmax(x) end
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

function linear_size_transformer(x, smin, smax)
  local x = toseries(x)
  assert(type(x) == "table", "needs a series as 1st argument")
  local smin,smax = smin or DEF_SIZE*0.5, smax or DEF_SIZE*2.0
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
  transformations = {
    box = box_transformation,
    hist2d = hist2d_transformation,
  },
}
