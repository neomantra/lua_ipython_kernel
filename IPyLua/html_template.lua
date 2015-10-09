return [[<script
    id="$SCRIPTID"
    data-bokeh-data="static"
    data-bokeh-modelid="$MODELID"
    data-bokeh-modeltype="$MODELTYPE"
    data-bokeh-loglevel="info"
>
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

  bokehjs_url = "http://cdn.pydata.org/bokeh/release/bokeh-0.10.0.js"

  var elt = document.getElementById("$SCRIPTID");
  if(elt==null) {
    console.log("Bokeh: ERROR: autoload.js configured with elementid '$SCRIPTID' but no matching script tag was found. ")
    return false;
  }

  // These will be set for the static case
  var all_models = $MODEL;

  if(typeof(Bokeh) !== "undefined") {
    console.log("Bokeh: BokehJS loaded, going straight to plotting");
    Bokeh.embed.inject_plot("$SCRIPTID", all_models);
  } else {
    load_lib(bokehjs_url, function() {
      console.log("Bokeh: BokehJS plotting callback run at", new Date())
      Bokeh.embed.inject_plot("$SCRIPTID", all_models);
    });
  }

}(this));
</script>
]]
