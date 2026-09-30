/* Grainient: the animated grain gradient of Captylo (React Bits "Grainient", the same shader
   and the owner's parameters as the app's Metal port, see docs/design/dusk-glass.md).
   Shader: Copyright (c) 2026 David Haz, MIT + Commons Clause, not covered by Captylo's GPLv3;
   see NOTICE.md.
   ONE shared WebGL2 context renders every block into an offscreen canvas, and each element
   with [data-grainient] gets a 2D canvas (first child) that the frame is copied into. One
   context per block broke on phones: Chrome on Android keeps at most 8 WebGL contexts alive
   and drops the oldest (the hero went blank). Only blocks near the viewport render; phones
   render at 1x and 30 fps; Reduce Motion and hidden tabs hold the frame.

   data-grainient="dark" | "light"   palette (default dark)
   data-seed="12.5"                   time offset, so two blocks never look the same
   data-zoom / data-cx / data-cy      framing of the field inside the block
*/
(function () {
  "use strict";

  var VERT = "#version 300 es\nin vec2 position;void main(){gl_Position=vec4(position,0.0,1.0);}";
  var FRAG = [
    "#version 300 es",
    "precision highp float;",
    "uniform vec2 iResolution;uniform float iTime;uniform float uTimeSpeed;uniform float uColorBalance;uniform float uWarpStrength;uniform float uWarpFrequency;uniform float uWarpSpeed;uniform float uWarpAmplitude;uniform float uBlendAngle;uniform float uBlendSoftness;uniform float uRotationAmount;uniform float uNoiseScale;uniform float uGrainAmount;uniform float uGrainScale;uniform float uContrast;uniform float uGamma;uniform float uSaturation;uniform vec2 uCenterOffset;uniform float uZoom;uniform vec3 uColor1;uniform vec3 uColor2;uniform vec3 uColor3;uniform float uDim;",
    "out vec4 fragColor;",
    "#define S(a,b,t) smoothstep(a,b,t)",
    "mat2 Rot(float a){float s=sin(a),c=cos(a);return mat2(c,-s,s,c);}",
    "vec2 hash(vec2 p){p=vec2(dot(p,vec2(2127.1,81.17)),dot(p,vec2(1269.5,283.37)));return fract(sin(p)*43758.5453);}",
    "float noise(vec2 p){vec2 i=floor(p),f=fract(p),u=f*f*(3.0-2.0*f);float n=mix(mix(dot(-1.0+2.0*hash(i+vec2(0.0,0.0)),f-vec2(0.0,0.0)),dot(-1.0+2.0*hash(i+vec2(1.0,0.0)),f-vec2(1.0,0.0)),u.x),mix(dot(-1.0+2.0*hash(i+vec2(0.0,1.0)),f-vec2(0.0,1.0)),dot(-1.0+2.0*hash(i+vec2(1.0,1.0)),f-vec2(1.0,1.0)),u.x),u.y);return 0.5+0.5*n;}",
    "void main(){",
    "  vec2 C=gl_FragCoord.xy;float t=iTime*uTimeSpeed;vec2 uv=C/iResolution.xy;float ratio=iResolution.x/iResolution.y;",
    "  vec2 tuv=uv-0.5+uCenterOffset;tuv/=max(uZoom,0.001);",
    "  float degree=noise(vec2(t*0.1,tuv.x*tuv.y)*uNoiseScale);",
    "  tuv.y*=1.0/ratio;tuv*=Rot(radians((degree-0.5)*uRotationAmount+180.0));tuv.y*=ratio;",
    "  float ws=max(uWarpStrength,0.001);float amplitude=uWarpAmplitude/ws;float warpTime=t*uWarpSpeed;",
    "  tuv.x+=sin(tuv.y*uWarpFrequency+warpTime)/amplitude;tuv.y+=sin(tuv.x*(uWarpFrequency*1.5)+warpTime)/(amplitude*0.5);",
    "  float b=uColorBalance;float s=max(uBlendSoftness,0.0);",
    "  float blendX=(tuv*Rot(radians(uBlendAngle))).x;",
    "  float edge0=-0.3-b-s;float edge1=0.2-b+s;float v0=0.5-b+s;float v1=-0.3-b-s;",
    "  vec3 layer1=mix(uColor3,uColor2,S(edge0,edge1,blendX));",
    "  vec3 layer2=mix(uColor2,uColor1,S(edge0,edge1,blendX));",
    "  vec3 col=mix(layer1,layer2,S(v0,v1,tuv.y));",
    "  vec2 grainUv=uv*max(uGrainScale,0.001);",
    "  float grain=fract(sin(dot(grainUv,vec2(12.9898,78.233)))*43758.5453);",
    "  col+=(grain-0.5)*uGrainAmount;",
    "  col=(col-0.5)*uContrast+0.5;",
    "  float luma=dot(col,vec3(0.2126,0.7152,0.0722));col=mix(vec3(luma),col,uSaturation);",
    "  col=pow(max(col,0.0),vec3(1.0/max(uGamma,0.001)));",
    "  col*=1.0-uDim;",
    "  fragColor=vec4(clamp(col,0.0,1.0),1.0);",
    "}"
  ].join("\n");

  /* GlassTokens.Grainient in the app: timeSpeed 1.05, warp 5.4 / 1.5 / 50, blend -2 / 0.08,
     rotation 500, noise 1.65, grain 0.09 at scale 2 (static), zoom 0.95. The owner keeps the
     10 % dim ("Przyciemnienie tła") on the website as well. */
  var BASE = {
    timeSpeed: 1.05, colorBalance: 0, warpStrength: 1, warpFrequency: 5.4, warpSpeed: 1.5,
    warpAmplitude: 50, blendAngle: -2, blendSoftness: 0.08, rotationAmount: 500, noiseScale: 1.65,
    grainAmount: 0.09, grainScale: 2, contrast: 1.5, gamma: 1, saturation: 1, zoom: 0.95, dim: 0.1
  };
  var PALETTES = {
    dark: { color1: "#10272C", color2: "#214A52", color3: "#9FE6DC" },
    light: { color1: "#B7CCCB", color2: "#214A52", color3: "#9FE6DC", contrast: 1.15, gamma: 1.05, dim: 0 }
  };
  var UNIFORMS = ["iResolution", "iTime", "uTimeSpeed", "uColorBalance", "uWarpStrength", "uWarpFrequency", "uWarpSpeed", "uWarpAmplitude", "uBlendAngle", "uBlendSoftness", "uRotationAmount", "uNoiseScale", "uGrainAmount", "uGrainScale", "uContrast", "uGamma", "uSaturation", "uCenterOffset", "uZoom", "uColor1", "uColor2", "uColor3", "uDim"];

  function hex(h) {
    var m = /^#?([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})$/i.exec(h);
    return m ? [parseInt(m[1], 16) / 255, parseInt(m[2], 16) / 255, parseInt(m[3], 16) / 255] : [1, 1, 1];
  }
  function num(v, d) { var n = parseFloat(v); return isNaN(n) ? d : n; }

  var calm = window.matchMedia("(prefers-reduced-motion: reduce)");
  var phone = window.matchMedia("(max-width: 760px), (pointer: coarse)");
  var views = [];
  var io = "IntersectionObserver" in window ? new IntersectionObserver(function (entries) {
    entries.forEach(function (e) {
      for (var i = 0; i < views.length; i++) if (views[i].host === e.target) views[i].visible = e.isIntersecting;
    });
  }, { rootMargin: "120px 0px" }) : null;
  var ro = "ResizeObserver" in window ? new ResizeObserver(function (entries) {
    entries.forEach(function (e) {
      for (var i = 0; i < views.length; i++) if (views[i].host === e.target) views[i].measure(e.target.getBoundingClientRect());
    });
  }) : null;

  /* the shared context */
  var glCanvas = document.createElement("canvas");
  var gl = null, loc = {};
  function setup() {
    gl = glCanvas.getContext("webgl2", { antialias: false, alpha: false, premultipliedAlpha: false, depth: false, stencil: false, powerPreference: "low-power" });
    if (!gl) return false;
    function compile(type, src) { var s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s); return s; }
    var pr = gl.createProgram();
    gl.attachShader(pr, compile(gl.VERTEX_SHADER, VERT));
    gl.attachShader(pr, compile(gl.FRAGMENT_SHADER, FRAG));
    gl.bindAttribLocation(pr, 0, "position");
    gl.linkProgram(pr);
    if (!gl.getProgramParameter(pr, gl.LINK_STATUS)) { gl = null; return false; }
    gl.useProgram(pr);
    gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
    gl.enableVertexAttribArray(0);
    gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
    UNIFORMS.forEach(function (n) { loc[n] = gl.getUniformLocation(pr, n); });
    return true;
  }
  glCanvas.addEventListener("webglcontextlost", function (e) {
    e.preventDefault();
    gl = null;
    views.forEach(function (v) { v.host.classList.remove("grainient-ready"); v.drawn = false; });
  });
  glCanvas.addEventListener("webglcontextrestored", function () { setup(); });

  function render(v, t) {
    var w = v.canvas.width, h = v.canvas.height, p = v.p;
    if (glCanvas.width < w) glCanvas.width = w;
    if (glCanvas.height < h) glCanvas.height = h;
    gl.viewport(0, 0, w, h);
    gl.uniform2f(loc.iResolution, w, h);
    gl.uniform1f(loc.iTime, t + v.seed);
    gl.uniform1f(loc.uTimeSpeed, p.timeSpeed); gl.uniform1f(loc.uColorBalance, p.colorBalance);
    gl.uniform1f(loc.uWarpStrength, p.warpStrength); gl.uniform1f(loc.uWarpFrequency, p.warpFrequency);
    gl.uniform1f(loc.uWarpSpeed, p.warpSpeed); gl.uniform1f(loc.uWarpAmplitude, p.warpAmplitude);
    gl.uniform1f(loc.uBlendAngle, p.blendAngle); gl.uniform1f(loc.uBlendSoftness, p.blendSoftness);
    gl.uniform1f(loc.uRotationAmount, p.rotationAmount); gl.uniform1f(loc.uNoiseScale, p.noiseScale);
    gl.uniform1f(loc.uGrainAmount, p.grainAmount); gl.uniform1f(loc.uGrainScale, p.grainScale);
    gl.uniform1f(loc.uContrast, p.contrast); gl.uniform1f(loc.uGamma, p.gamma);
    gl.uniform1f(loc.uSaturation, p.saturation); gl.uniform2f(loc.uCenterOffset, v.cx, v.cy);
    gl.uniform1f(loc.uZoom, p.zoom); gl.uniform1f(loc.uDim, p.dim);
    gl.uniform3fv(loc.uColor1, p.c1); gl.uniform3fv(loc.uColor2, p.c2); gl.uniform3fv(loc.uColor3, p.c3);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
    /* the viewport sits at the bottom left of the GL canvas, which is its last rows as an image */
    v.ctx.drawImage(glCanvas, 0, glCanvas.height - h, w, h, 0, 0, w, h);
    v.drawn = true;
    if (!v.ready) { v.ready = true; v.host.classList.add("grainient-ready"); }
  }

  function mount(host) {
    var canvas = document.createElement("canvas");
    canvas.className = "grainient";
    canvas.setAttribute("aria-hidden", "true");
    var ctx = canvas.getContext("2d", { alpha: false });
    if (!ctx) return;
    var ds = host.dataset;
    var p = Object.assign({}, BASE, PALETTES[ds.grainient] || PALETTES.dark);
    p.zoom = num(ds.zoom, p.zoom);
    p.c1 = hex(p.color1); p.c2 = hex(p.color2); p.c3 = hex(p.color3);
    var v = {
      host: host, canvas: canvas, ctx: ctx, p: p, visible: !io, drawn: false, ready: false,
      seed: num(ds.seed, 0), cx: num(ds.cx, 0), cy: num(ds.cy, 0),
      measure: function (r) {
        var d = phone.matches ? 1 : Math.min(window.devicePixelRatio || 1, 1.5);
        var w = Math.max(1, Math.round(r.width * d)), h = Math.max(1, Math.round(r.height * d));
        if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; v.drawn = false; }
      }
    };
    /* phones under memory pressure (many tabs, battery saver) can take a canvas away: hide it so
       the CSS gradient under it shows and the white type stays readable, draw again on restore */
    canvas.addEventListener("contextlost", function (e) {
      e.preventDefault();
      v.lost = true; v.ready = false; v.drawn = false;
      host.classList.remove("grainient-ready");
    });
    canvas.addEventListener("contextrestored", function () { v.lost = false; });
    host.insertBefore(canvas, host.firstChild);
    views.push(v);
    v.measure(host.getBoundingClientRect());
    if (io) io.observe(host);
    if (ro) ro.observe(host);
  }

  /* Time only advances while something moves, in steps of at most 0.1 s, so a hidden tab or a
     long scroll away never makes the field jump. Phones draw every other frame (about 30 fps). */
  var held = 0, last = 0, lastDraw = 0;
  function frame(now) {
    requestAnimationFrame(frame);
    if (!gl) return;
    var moving = !calm.matches && !document.hidden;
    var t = moving && last ? held + Math.min(now - last, 100) / 1000 : held;
    last = now;
    held = t;
    var due = !phone.matches || now - lastDraw >= 31;
    if (due) lastDraw = now;
    for (var i = 0; i < views.length; i++) {
      var v = views[i];
      if (!v.visible || v.lost) continue;
      if (!v.drawn || (moving && due)) render(v, t);
    }
  }

  function init() {
    var hosts = document.querySelectorAll("[data-grainient]");
    if (!setup()) { hosts.forEach(function (h) { h.classList.add("grainient-fallback"); }); return; }
    hosts.forEach(mount);
    if (!ro) window.addEventListener("resize", function () { views.forEach(function (v) { v.measure(v.host.getBoundingClientRect()); }); });
    requestAnimationFrame(frame);
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
})();
