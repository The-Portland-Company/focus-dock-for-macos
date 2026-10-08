(function(){try{
var KEY="tpc_theme";
var LEGACY_KEY="politogy_theme";
var VALID=["light","dark","system"];
function fromCookie(){try{
  var m=document.cookie.match(/(?:^|;\s*)tpc_theme=([^;]+)/);
  if(m)return decodeURIComponent(m[1]);
  var lm=document.cookie.match(/(?:^|;\s*)politogy_theme=([^;]+)/);
  return lm?decodeURIComponent(lm[1]):null;
}catch(e){return null;}}
var cookie=fromCookie();
var ls=null;try{ls=localStorage.getItem(KEY)||localStorage.getItem(LEGACY_KEY);}catch(e){}
var pref=cookie||ls||"system";
if(VALID.indexOf(pref)===-1)pref="system";
if(cookie&&cookie!==ls){try{localStorage.setItem(KEY,cookie);}catch(e){}}
var resolved=pref;
if(pref==="system"){try{resolved=window.matchMedia("(prefers-color-scheme: dark)").matches?"dark":"light";}catch(e){resolved="light";}}
var d=document.documentElement;
if(resolved==="dark"){d.classList.add("dark");}else{d.classList.remove("dark");}
try{d.style.colorScheme=resolved;}catch(e){}
}catch(e){}})();
(function(){try{
var KEY="tpc_theme";
function fromCookie(){try{
  var m=document.cookie.match(/(?:^|;\s*)tpc_theme=([^;]+)/);
  if(m)return decodeURIComponent(m[1]);
  var lm=document.cookie.match(/(?:^|;\s*)politogy_theme=([^;]+)/);
  return lm?decodeURIComponent(lm[1]):null;
}catch(e){return null;}}
var mql=window.matchMedia("(prefers-color-scheme: dark)");
function onChange(e){
  var cookie=fromCookie();
  var ls=null;try{ls=localStorage.getItem(KEY);}catch(err){}
  var pref=cookie||ls||"system";
  if(pref!=="system")return;
  var d=document.documentElement;
  if(e.matches){d.classList.add("dark");}else{d.classList.remove("dark");}
  try{d.style.colorScheme=e.matches?"dark":"light";}catch(err){}
}
if(mql.addEventListener){mql.addEventListener("change",onChange);}else if(mql.addListener){mql.addListener(onChange);}
function want(){var cookie=fromCookie();var ls=null;try{ls=localStorage.getItem(KEY);}catch(err){}var pref=cookie||ls||"system";return pref==="dark"||(pref!=="light"&&mql.matches);}
var d=document.documentElement;
new MutationObserver(function(){var w=want();if(w!==d.classList.contains("dark")){if(w){d.classList.add("dark");}else{d.classList.remove("dark");}try{d.style.colorScheme=w?"dark":"light";}catch(err){}}}).observe(d,{attributes:true,attributeFilter:["class"]});
}catch(e){}})();
