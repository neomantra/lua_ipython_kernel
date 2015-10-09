local json = require "IPyLua.dkjson"
local uuid = require "IPyLua.uuid"
local type = luatype or type

local figure = {}
local figure_methods = {}

-- error checking

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

local function check_table(t, ...)
  local inv_list = invert({...})
  for i,v in pairs(t) do
    assert(inv_list[i], ("unknown field= %s"):format(i))
  end
end

local function check_value(t, k, ...)
  if t[k] then
    local inv_list = invert({...})
    local v = t[k]
    assert(inv_list[v], ("unknown value= %s at field= %s"):format(v,k))
  end
end

local function check_type(t, k, ty)
  local tt = type(t[k])
  assert(t[k] == nil or tt == ty,
         ("type= %s is not valid for field= %s"):format(tt, k))
end

local function check_types(t, keys, types)
  assert(#keys == #types)
  for i=1,#keys do
    local k,ty = keys[i],types[i]
    check_type(t, k, ty)
  end
end

local function check_mandatory(t, key)
  assert(t[key], ("field= %s is mandatory"):format(key))
end

local function check_mandatories(t, ...)
  for _,key in ipairs(table.pack(...)) do
    check_mandatory(t, key)
  end
end

-- private functions

local function add_observer(self, id, tbl)
  self._observers[id] = self._observers[id] or {}
  table.insert(self._observers[id], tbl)
end

local function update_observers(self, id, obj)
  for _,ref in ipairs(self._observers[id] or {}) do
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

local function add_simple_glyph(self, name, attributes)
  local id = uuid.new()
  local list = self._list
  attributes.id = id
  local glyph = {
    attributes = attributes,
    type = name,
    id = id,
  }
  local ref = { type = name, id = id, }
  add_observer(self, id, ref)
  list[#list+1] = glyph
  return ref,glyph
end

local function add_tool(self, name, attributes)
  attributes.plot = {}
  attributes.plot.type = self._doc.type
  attributes.plot.subtype = self._doc.subtype
  local tools = self._doc.attributes.tools
  tools[#tools+1] = add_simple_glyph(self, name, attributes)
end

local function add_axis(self, key, params)
  check_mandatories(params, "pos", "type")
  if not self[key][params.pos] then
    local axis_ref,axis = add_simple_glyph(self, params.type,
                                           { tags={}, doc=nil, axis_label=params.label })
    local formatter_ref,formatter = add_simple_glyph(self, "BasicTickFomatter",
                                                     { tags={}, doc=nil })
    local ticker_ref,ticker =
      add_simple_glyph(self, "BasicTicker",
                       { tags={}, doc=nil, mantissas={2, 5, 10} })
    
    axis.formatter = formatter_ref
    axis.ticker = ticker_ref
    
    append_renderer(self, add_simple_glyph(self, "Grid",
                                           { tags={}, doc=nil, dimension=1,
                                             ticker=axis.ticker }))
    append_renderer(self, axis_ref)
    
    self._doc.attributes[params.pos][1] = axis_ref
    self[key][params.pos] = axis
  else
    local axis = self[key][params.pos]
    axis.attributes.axis_label = params.label
    axis.type = params.type
    update_observers(self, axis.id, axis)
  end
end

local function tool_events(self)
  self._doc.attributes.tool_events =
    add_simple_glyph(
      self, "ToolEvents",
      {
        geometries = {},
        tags = {},
        doc = nil,
      }
    )
end

-- figure class implementation

local figure_methods = {
  
  -- axis
  
  x_axis = function(self, params)
    check_table(params, "type", "label", "pos", "log", "grid", "num_minor_ticks",
                "visible", "number_formatter")
    check_value(params, "type", "LinearAxis", "CategoricalAxis")
    check_value(params, "pos", "below", "above")
    check_types(params,
                {"log","grid","num_minor_ticks","visible"},
                {"boolean","boolean","number","boolean"})
    
    add_axis(self, "_x_axis", params)
    return self
  end,

  y_axis = function(self, params)
    check_table(params, "type", "label", "pos", "log", "grid", "num_minor_ticks",
                "visible", "number_formatter")
    check_value(params, "type", "LinearAxis", "CategoricalAxis")
    check_value(params, "pos", "left", "right")
    check_types(params,
                {"log","grid","num_minor_ticks","visible"},
                {"boolean","boolean","number","boolean"})
    
    add_axis(self, "_y_axis", params)
    return self
  end,
  
  -- tools
  
  tool_box_select = function(self, select_every_mousemove)
    select_every_mousemove = select_every_mousemove or true
    add_tool(self, "BoxSelectTool", { select_every_mousemove=select_every_mousemove, tags={}, doc=nil })
    compile_glyph(self)
    return self
  end,
  
  tool_box_zoom = function(self, dimensions)
    dimensions = dimensions or { "width", "height" }
    add_tool(self, "BoxZoomTool", { dimensions=dimensions, tags={}, doc=nil })
    compile_glyph(self)
    return self
  end,
  
  tool_crosshair = function(self)
    add_tool(self, "CrossHair", { tags={}, doc=nil })
    compile_glyph(self)
    return self
  end,
  
  tool_lasso_select = function(self, select_every_mousemove)
    select_every_mousemove = select_every_mousemove or true
    add_tool(self, "LassoSelectTool", { select_every_mousemove=select_every_mousemove, tags={}, doc=nil })
    compile_glyph(self)
    return self
  end,
  
  tool_pan = function(self, dimensions)
    dimensions = dimensions or { "width", "height" }
    add_tool(self, "PanTool", { dimensions=dimensions, tags={}, doc=nil })
    compile_glyph(self)
    return self
  end,
  
  tool_reset = function(self)
    add_tool(self, "ResetTool", { tags={}, doc=nil })
    compile_glyph(self)
    return self
  end,
  
  tool_resize = function(self)
    add_tool(self, "ResizeTool", { tags={}, doc=nil })
    compile_glyph(self)
    return self
  end,
  
  tool_save = function(self)
    add_tool(self, "PreviewSaveTool", { tags={}, doc=nil })
    compile_glyph(self)
    return self
  end,
  
  tool_wheel_zoom = function(self, dimensions)
    dimensions = dimensions or { "width", "height" }
    add_tool(self, "WheelZoomTool", { dimensions=dimensions, tags={}, doc=nil })
    compile_glyph(self)
    return self
  end,
  
  -- layer functions
  
  points = function(self, params)
    check_table(params, "x", "y", "glyph", "color", "alpha", "size",
                "hover", "legend")
    check_value(params, "glyph", "Circle", "Triangle")
    check_mandatories(params, "x", "y")
    local x = serie_totable(params.x)
    local y = serie_totable(params.y)
    local color = serie_totable( extend(params.color or "#f22c40", #x) )
    local alpha = serie_totable( extend(params.alpha or 0.8, #x) )
    local hover = serie_totable( params.hover )
    local data = {
      x = x,
      y = y,
      color = color,
      fill_alpha = alpha,
      hover = hover,
    }
    local columns = { "x", "y", "fill_alpha", "color" }
    if hover then table.insert(columns, "hover") end
    
    local attributes = {
      tags = {},
      doc = nil,
      selected = {
        ["2d"] = { indices = {} },
        ["1d"] = { indices = {} },
        ["0d"] = { indices = {}, flag=false },
      },
      callback = nil,
      data = data,
      column_names = columns,
    }
    local source_ref = add_simple_glyph(self, "ColumnDataSource", attributes)
    
    local attributes = {
      fill_color = { field = "color" },
      tags = {},
      doc = nil,
      fill_alpha = { field = "fill_alpha" },
      x = { field = "x" },
      y = { field = "y" },
    }
    local points_ref = add_simple_glyph(self, params.glyph or "Circle", attributes)
    
    local attributes = {
      nonselection_glyph = nil,
      data_source = source_ref,
      tags = {},
      doc = nil,
      selection_glyph = nil,
      glyph = points_ref,
    }
    append_renderer(self, add_simple_glyph(self, "GlyphRenderer", attributes) )
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

local html_template = [[
(function(global) {
  if (typeof (window._bokeh_onload_callbacks) === "undefined"){
    window._bokeh_onload_callbacks = [];
  }
  function load_lib(url, callback){
    window._bokeh_onload_callbacks.push(callback);
    if (window._bokeh_is_loading){
      console.log("Bokeh: BokehJS is being loaded, scheduling callback at", new Date());
      return null;
    }
    console.log("Bokeh: BokehJS not loaded, scheduling load and callback at", new Date());
    window._bokeh_is_loading = true;
    var s = document.createElement('script');
    s.src = url;
    s.async = true;
    s.onreadystatechange = s.onload = function(){
      Bokeh.embed.inject_css("http://cdn.pydata.org/bokeh/release/bokeh-0.10.0.min.css");
      window._bokeh_onload_callbacks.forEach(function(callback){callback()});
    };
    s.onerror = function(){
      console.warn("failed to load library " + url);
    };
    document.getElementsByTagName("head")[0].appendChild(s);
  }

  bokehjs_url = "http://cdn.pydata.org/bokeh/release/bokeh-0.10.0.min.js"

  var elt = document.getElementById("$ID");
  if(elt==null) {
    console.log("Bokeh: ERROR: autoload.js configured with elementid '$ID' but no matching script tag was found. ")
    return false;
  }

  // These will be set for the static case
  var all_models = [$MODEL];

  if(typeof(Bokeh) !== "undefined") {
    console.log("Bokeh: BokehJS loaded, going straight to plotting");
    Bokeh.embed.inject_plot("$ID", all_models);
  } else {
    load_lib(bokehjs_url, function() {
      console.log("Bokeh: BokehJS plotting callback run at", new Date())
      Bokeh.embed.inject_plot("$ID", all_models);
    });
  }

}(this));
]]

local figure_mt = {
  __index = figure_methods,
  
  ipylua_show = function(self)
    local html = html_template:
      gsub("$ID", uuid.new()):
      gsub("$MODEL", self:to_json())
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
      default("width",  480)
      default("height",  520)
      default("title",  nil) -- not necessary but useful to make it explicit
      default("xlab",  nil)
      default("ylab",  nil)
      default("xlim",  nil)
      default("ylim",  nil)
      default("padding_factor",  0.07)
      default("plot_width",  nil)
      default("plot_height",  nil)
      default("xgrid",  true)
      default("ygrid",  true)
      default("xaxes",  "below")
      default("yaxes",  "left")
      -- ??? default("theme",  "bokeh_theme") ???
      
      local self = { _list = {}, _y_axis = {}, _x_axis = {}, _observers={} }
      setmetatable(self, figure_mt)
      local plot_id = uuid.new()
      self._doc = {
        type = "Plot",
        subtype = "Chart",
        id = plot_id,
        attributes = {
          plot_width = params.plot_width,
          plot_height = params.plot_height,
          title = params.title,
          --
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
      }
      self._list[1] = self._doc
      
      tool_events(self)
      for _,name in ipairs(params.tools) do self["tool_" .. name](self) end
      if params.xaxes then
        self:x_axis{ label=params.xlab, log=false, grid=params.xgrid,
                     num_minor_ticks=5, visible=true, number_formatter=tostring,
                     type="LinearAxis", pos=params.xaxes }
      end
      if params.yaxes then
        self:y_axis{ label=params.ylab, log=false, grid=params.ygrid,
                     num_minor_ticks=5, visible=true, number_formatter=tostring,
                     type="LinearAxis", pos=params.yaxes }
      end
      
      return self
    end
  }
)

local x = figure():points{ x={1,2,3,4}, y={10,5,20,30} }

print(x:to_json())

return {
  figure = figure,
}
