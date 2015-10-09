local json = require "IPyLua.dkjson"
local uuid = require "IPyLua.uuid"
local html_template = require "IPyLua.html_template"
local null = json.null
local type = luatype or type

local figure = {}
local figure_methods = {}

local function default_true(value)
  if value == nil then return true else return value end
end

local function reduce(t, func)
  local out = t[1]
  for i=2,#t do out = func(out, t[i]) end
  return out
end

local function min(t) return reduce(t, math.min) end
local function max(t) return reduce(t, math.max) end

local function factors(t)
  local out = {} for i=1,#t do out[i] = tostring(t[i]) end return out
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

local function serie_totable(s)
  if s==nil then return nil end
  local tt = type(s)
  if tt == "table" or tt == "userdata" then
    local mt = getmetatable(s)
    if mt and mt.ipylua_totable then
      return mt.ipylua_totable(s)
    elseif tt == "table" then
      return s
    end
  end
  error("serie data type cannot be handled")
end

local function invert(t)
  local r = {}
  for k,v in pairs(t) do r[v] = k end
  return r
end

-- error checking

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
         ("type %s is not valid for field %s"):format(tt, k))
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
  
  x_axis = function(self, params)
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

  y_axis = function(self, params)
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
  
  -- tools
  
  tool_box_select = function(self, select_every_mousemove)
    select_every_mousemove = default_true( select_every_mousemove )
    add_tool(self, "BoxSelectTool", { select_every_mousemove=select_every_mousemove, tags={}, doc=null })
    compile_glyph(self)
    return self
  end,
  
  tool_box_zoom = function(self, dimensions)
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
  
  tool_pan = function(self, dimensions)
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
  
  tool_wheel_zoom = function(self, dimensions)
    dimensions = dimensions or { "width", "height" }
    add_tool(self, "WheelZoomTool", { dimensions=dimensions, tags={}, doc=null })
    compile_glyph(self)
    return self
  end,
  
  -- layer functions
  
  points = function(self, params)
    params = params or {}
    check_table(params, "x", "y", "glyph", "color", "alpha", "size",
                "legend")
    check_value(params, "glyph", "Circle", "Triangle")
    check_mandatories(params, "x", "y")
    local x = serie_totable(params.x)
    local y = serie_totable(params.y)
    local color = serie_totable( extend(params.color or "#f22c40", #x) )
    local alpha = serie_totable( extend(params.alpha or 0.8, #x) )
    -- local hover = serie_totable( params.hover )
    local data = {
      x = x,
      y = y,
      color = color,
      fill_alpha = alpha,
      -- hover = hover,
    }
    local columns = { "x", "y", "fill_alpha", "color" }
    -- if hover then table.insert(columns, "hover") end
    
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
    local source_ref = add_simple_glyph(self, "ColumnDataSource", attributes)
    
    local attributes = {
      fill_color = { field = "color" },
      tags = {},
      doc = null,
      fill_alpha = { field = "fill_alpha" },
      x = { field = "x" },
      y = { field = "y" },
    }
    local points_ref = add_simple_glyph(self, params.glyph or "Circle", attributes)
    
    local attributes = {
      nonselection_glyph = null,
      data_source = source_ref,
      tags = {},
      doc = null,
      selection_glyph = null,
      glyph = points_ref,
    }
    append_renderer(self, add_simple_glyph(self, "GlyphRenderer", attributes) )

    if not self._doc.attributes.x_range then
      local axis = self._doc.attributes.below[1] or self._doc.attributes.above[1]
      if axis.type == "LinearAxis" then
        self:x_range( apply_gap(0.05, min(x), max(x)) )
      else
        self:x_range(factors(x))
      end
    end
    
    if not self._doc.attributes.y_range then
      local axis = self._doc.attributes.left[1] or self._doc.attributes.right[1]
      if axis.type == "LinearAxis" then
        self:y_range( apply_gap(0.05, min(y), max(y)) )
      else
        self:y_range(factors(y))
      end
    end
    
    return self
  end,
  
  -- conversion
  
  to_json = function(self)
    local doc_json = json.encode(self._doc)
    local tbl = { doc_json }
    for i=2,#self._list do
      local v = self._list[i]
      if type(v) ~= "string" then v = json.encode(v) end
      tbl[#tbl+1] = v
    end
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
      
      local self = { _list = {}, _references={}, _dict = {} }
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

return {
  figure = figure,
}
