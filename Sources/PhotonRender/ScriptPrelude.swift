/// The JavaScript half of the SceneScript runtime (docs/re/08). It runs once per scene context, after
/// `scripts/jsclasses/baseclasses.js`, and receives the native bridge `N` (SceneScript.swift).
///
/// Most of the engine's DLL logic lives here rather than in Swift so that a frame costs one JS call:
/// - the scope stack (§2.5) and the `thisObject` / `thisLayer` stacks (§2.7);
/// - hook dispatch with disable-on-throw (§2.4) and the frame order of `Bindings_Tick` (§2.3);
/// - return-value conversion per reflection type id (§2.6); Swift handles degrees (flag 4);
/// - `engine` (§3.1), `input` (§3.2), `console` (§3.3), `localStorage` (§3.4), timers (§3.5);
/// - generic host-object wrappers built from the reflection tables (§3.10), cached per handle so
///   expando properties survive.
enum ScriptPrelude {
    static let source = #"""
(function(global, N) {
'use strict';
const HOOKS = ['init','update','resizeScreen','destroy','applyUserProperties','applyGeneralSettings','animationEvent',
  'cursorHitTest','cursorEnter','cursorLeave','cursorMove','cursorClick','cursorDown','cursorUp',
  'mediaStatusChanged','mediaPlaybackChanged','mediaPropertiesChanged','mediaThumbnailChanged','mediaTimelineChanged'];
const T_INT = 0, T_VEC2 = 1, T_VEC3 = 2, T_VEC4 = 3, T_FLOAT = 4, T_STRING = 5, T_BOOL = 6, T_OBJECT = 7, T_BYTE = 8;
const HK = Symbol('host');

// ---- scope / context stacks (§2.5, §2.7) ----
let scope = 1;
const scopeStack = [], objStack = [], layerStack = [], scriptStack = [];
let cursorCallback = false, shortcutUsed = false;
const globalAssetOwner = {};
function enter(sc, rec, obj, layer) {
  scopeStack.push(scope); scope = sc;
  scriptStack.push(rec); objStack.push(obj); layerStack.push(layer);
}
function leave() {
  scope = scopeStack.pop(); scriptStack.pop(); objStack.pop(); layerStack.pop();
}
function notGlobal(what, verb) {
  if (scope === 0) throw new Error(what + ' cannot be ' + (verb || 'accessed') + ' from global scope.');
}
function onlyGlobal(what) {
  if (scope !== 0) throw new Error(what + ' can only be called from global scope.');
}
function curScript() { return scriptStack.length ? scriptStack[scriptStack.length - 1] : null; }

// ---- frame state, refreshed once per tick ----
const F = { dt: 0, runtime: 0, tod: 0, sw: 1920, sh: 1080, cw: 1920, ch: 1080, wx: 0, wy: 0, wz: 0, sx: 0, sy: 0, down: false };
function setFrame(a) {
  F.dt = a[0]; F.runtime = a[1]; F.tod = a[2]; F.sw = a[3]; F.sh = a[4]; F.cw = a[5]; F.ch = a[6];
  F.wx = a[7]; F.wy = a[8]; F.wz = a[9]; F.sx = a[10]; F.sy = a[11]; F.down = !!a[12];
}

// ---- value conversion (§2.6) ----
function mk(type, a) {
  let o;
  switch (type) {
  case T_VEC2: o = Object.create(Vec2.prototype); o.x = +a[0]; o.y = +a[1]; return o;
  case T_VEC3: o = Object.create(Vec3.prototype); o.x = +a[0]; o.y = +a[1]; o.z = +a[2]; return o;
  case T_VEC4: o = Object.create(Vec4.prototype); o.x = +a[0]; o.y = +a[1]; o.z = +a[2]; o.w = +a[3]; return o;
  case 9: o = Object.create(Mat4.prototype); o.m = Array.from(a); return o;
  case 10: o = Object.create(Mat3.prototype); o.m = Array.from(a); return o;
  }
  return a;
}
function toJS(type, v) {
  if (v === null || v === undefined) return undefined;
  switch (type) {
  case T_VEC2: case T_VEC3: case T_VEC4: return Array.isArray(v) ? mk(type, v) : v;
  case T_BOOL: return !!v;
  case T_BYTE: return v ? 1 : 0;
  case T_OBJECT: return Array.isArray(v) ? wrap(v[0], v[1]) : null;
  }
  return v;
}
function isNum(x) { return typeof x === 'number'; }
/// JS → native. `undefined` means "not convertible": the write is skipped.
function fromJS(type, v) {
  switch (type) {
  case T_INT: return isNum(v) ? (v | 0) : undefined;
  case T_FLOAT: return isNum(v) ? v : undefined;
  case T_STRING: return (v === null || v === undefined) ? undefined : String(v);
  case T_BOOL: case T_BYTE: return typeof v === 'boolean' ? v : undefined;
  case T_VEC2:
    if (isNum(v)) return [v, v];
    if (v !== null && typeof v === 'object' && isNum(v.x) && isNum(v.y)) return [v.x, v.y];
    return undefined;
  case T_VEC3:
    if (isNum(v)) return [v, v, v];
    if (v !== null && typeof v === 'object' && isNum(v.x) && isNum(v.y) && isNum(v.z)) return [v.x, v.y, v.z];
    return undefined;
  case T_VEC4:
    if (isNum(v)) return [v, v, v, v];
    if (v !== null && typeof v === 'object' && isNum(v.x) && isNum(v.y) && isNum(v.z) && isNum(v.w)) return [v.x, v.y, v.z, v.w];
    return undefined;
  }
  return undefined;
}

// ---- host wrappers (§3.10) ----
const wrappers = new Map();
const protos = {};
function wrap(h, cls) {
  if (h === null || h === undefined || h < 0) return null;
  let w = wrappers.get(h);
  if (w) return w;
  if (cls === undefined) cls = N.className(h);
  w = Object.create(protos[cls] || protos.object || Object.prototype);
  Object.defineProperty(w, HK, { value: h });
  wrappers.set(h, w);
  return w;
}
function argOut(a) {
  if (a !== null && typeof a === 'object' && a[HK] !== undefined) return { __host: a[HK] };
  if (typeof a === 'function') return { __fn: registerCallback(a) };
  return a;
}
const callbacks = [];
function registerCallback(fn) {
  const rec = curScript();
  callbacks.push({ fn: fn, rec: rec, obj: objStack[objStack.length - 1], layer: layerStack[layerStack.length - 1] });
  return callbacks.length - 1;
}
// ---- IModelData (dll 0x1816361f0 create, 0x181636890 destroy, descriptor 0x18162fd40, shape 0x181630720) ----
const MD_ERRORS = ['', 'Invalid material', 'Shader expecting more vertex data.', 'Inconsistent vertex buffer size',
  'Invalid model data token', 'Vertex buffer size cannot increase', 'Index buffer size cannot increase',
  'Model data not created as dynamic', 'Buffer lock failed', 'Incorrect index buffer type',
  'Cannot add shapes in IModelData.update', 'Cannot delete shape or buffers in IModelData.update',
  'Material cannot be changed in IModelData.update', 'Vertex format cannot be changed in IModelData.update'];
const MD_FORMAT = { position: 0x1, normal: 0x2, tangentSigned: 0x4, uv: 0x8, color: 0x8000 };
function parseModelData(cfg, creation) {
  const list = Array.isArray(cfg.shapes) ? cfg.shapes : [cfg];
  const out = { shapes: [] };
  if (cfg.boundingBoxMins !== null && typeof cfg.boundingBoxMins === 'object') {
    const a = cfg.boundingBoxMins, b = cfg.boundingBoxMaxs || {};
    out.boundsMin = [+a.x || 0, +a.y || 0, +a.z || 0]; out.boundsMax = [+b.x || 0, +b.y || 0, +b.z || 0];
  }
  for (const sh of list) {
    // Shape 0x181630720: null → remove-shape flag (+0x12c); any other non-object → an empty shape record.
    if (sh === null) { out.shapes.push({ remove: true }); continue; }
    if (typeof sh !== 'object') { out.shapes.push({ format: 0, vertexDynamic: true, indexDynamic: true }); continue; }
    const r = {};
    if (sh.vertexBuffer instanceof Float32Array) r.vertices = Array.from(sh.vertexBuffer);
    else if (creation) throw new Error('Vertex buffer missing.');
    if (sh.indexBuffer instanceof Uint16Array) r.indices = Array.from(sh.indexBuffer);
    else if (sh.indexBuffer instanceof Uint32Array) { r.indices = Array.from(sh.indexBuffer); r.index32 = true; }
    else if (sh.indexBuffer === null) r.removeIndices = true;   // 0x181630a26: `indexBuffer: null` (+0x24)
    let fmt = 0;
    if (Array.isArray(sh.vertexFormat)) {
      for (const f of sh.vertexFormat) { if (typeof f !== 'string') break; fmt |= MD_FORMAT[f] || 0; }
    }
    if (creation && fmt === 0) throw new Error('Vertex format missing.');
    r.format = fmt;
    if (typeof sh.material === 'string') r.material = sh.material;
    else if (creation) throw new Error('Material missing.');
    r.vertexDynamic = typeof sh.isVertexBufferDynamic === 'boolean' ? sh.isVertexBufferDynamic : true;
    r.indexDynamic = typeof sh.isIndexBufferDynamic === 'boolean' ? sh.isIndexBufferDynamic : true;
    out.shapes.push(r);
  }
  if (out.shapes.length === 0) throw new Error('Shapes missing.');
  return out;
}
function modelDataMethod(m) {
  return function(cfg) {
    if (scope === 0) throw new Error(m + ' cannot be called from global scope.');
    const rec = curScript();
    if (m === 'destroyModelData') {
      const tok = cfg && cfg.__modelDataToken;
      return N.call(this[HK], m, [typeof tok === 'number' ? tok : -1], rec ? rec.key : '');
    }
    if (arguments.length < 1 || cfg === null || typeof cfg !== 'object') return null;
    const d = parseModelData(cfg, true);
    const r = N.call(this[HK], m, [d], rec ? rec.key : '');
    if (typeof r !== 'number') return null;
    if (r < 0) throw new Error(MD_ERRORS[-r] || 'Invalid model data token');
    const o = Object.create(IModelData.prototype);
    Object.defineProperty(o, '__modelDataToken', { value: r, writable: false, enumerable: false, configurable: false });
    return o;
  };
}
// applyData / replaceData (dll 0x181636b60 / 0x181636ef0): no argument → nothing; the descriptor is parsed in update
// mode (no "missing" errors); with at least one shape the host (+0x58 → exe 0x1401d6400) applies it, `replace`
// false / true; a non-zero host error code throws its message.
function modelDataUpdate(self, cfg, replace) {
  if (cfg === null || typeof cfg !== 'object') return;
  const d = parseModelData(cfg, false);
  if (!d.shapes.length) return;
  const tok = self && self.__modelDataToken;
  const rec = curScript();
  const r = N.call(global.thisScene[HK], 'updateModelData', [typeof tok === 'number' ? tok : -1, d, replace], rec ? rec.key : '');
  if (typeof r === 'number' && r > 0) throw new Error(MD_ERRORS[r] || '');
}
if (typeof IModelData === 'function') {
  IModelData.prototype.applyData = function(cfg) { if (arguments.length < 1) return; modelDataUpdate(this, cfg, false); };
  IModelData.prototype.replaceData = function(cfg) {
    if (currentHook === 1) throw new Error('IModelData.replace cannot be called in update.');
    if (arguments.length < 1) return;
    modelDataUpdate(this, cfg, true);
  };
}

function defineClass(name, props, methods) {
  const p = {};
  for (const [prop, type, flags] of props) {
    const desc = {
      get() { notGlobal(prop); return toJS(type, N.get(this[HK], prop)); },
      configurable: true, enumerable: true
    };
    desc.set = (flags & 2) ? function() {} : function(v) {
      notGlobal(prop);
      const c = fromJS(type, v);
      if (c !== undefined) N.set(this[HK], prop, c);
    };
    Object.defineProperty(p, prop, desc);
  }
  for (const m of methods) {
    if (m === 'createModelData' || m === 'destroyModelData') {
      Object.defineProperty(p, m, { value: modelDataMethod(m), writable: true, configurable: true });
      continue;
    }
    Object.defineProperty(p, m, {
      value: function() {
        notGlobal(m, 'called');
        const rec = curScript();
        return N.call(this[HK], m, Array.prototype.map.call(arguments, argOut), rec ? rec.key : '');
      },
      writable: true, configurable: true
    });
  }
  protos[name] = p;
}

// ---- global API ----
let audioBuffers = [];
let userPropsCache = null;
const engine = {
  isRunningInEditor() { return false; },
  isPortrait() { notGlobal('isPortrait', 'called'); return F.sh > F.sw; },
  isLandscape() { notGlobal('isLandscape', 'called'); return F.sw >= F.sh; },
  registerAudioBuffers(res) {
    onlyGlobal('registerAudioBuffers');
    if (res !== 16 && res !== 32 && res !== 64) throw new Error('Resolution must be either 16, 32 or 64.');
    const b = { left: new Float32Array(res), right: new Float32Array(res), average: new Float32Array(res) };
    audioBuffers.push(b);
    return b;
  },
  // dll 0x181655810: argc < 1 or a non-string → null; duplicate path (per script, +0xe8) → null; else the path.
  // The boolean second argument is stored only. `requestFeatures` (0x181659270) is never installed.
  registerAsset(path, flag) {
    onlyGlobal('registerAsset');
    if (arguments.length < 1 || typeof path !== 'string') return null;
    const rec = curScript() || globalAssetOwner;
    const list = rec.assets || (rec.assets = []);
    if (list.some((e) => e.path === path)) return null;
    list.push({ path: path, flag: typeof flag === 'boolean' ? flag : false });
    return path;
  },
  // dll 0x181655e10 / 0x1816562d0: no argument, a non-function or no running script → null (not a throw).
  setTimeout(fn, ms) { notGlobal('setTimeout', 'called'); return addTimer(arguments.length, fn, ms, false); },
  setInterval(fn, ms) { notGlobal('setInterval', 'called'); return addTimer(arguments.length, fn, ms, true); },
  // Same native as the cancel function (0x181656780), but it reads its own data, which holds no timer: always
  // false (§3.1). The global-scope message is the native's own.
  clearTimeout() { if (scope === 0) throw new Error('timeout cannot be cleared from global scope.'); return false; },
  isMobileDevice() { return false; },
  isDesktopDevice() { return true; },
  isWallpaper() { return true; },
  isScreensaver() { return false; },
  isObjectValid(o) { return !!(o && typeof o === 'object' && o[HK] !== undefined && N.valid(o[HK])); },
  // dll 0x181656b70: only inside cursorClick/Down/Up (engine+0x62c ∈ 11…13); no or non-string argument → false;
  // host +0xf0 returns 0 → true, 1 → false, 2 → "more than one" error, anything else → undefined.
  openUserShortcut(name) {
    if (!(currentHook >= 11 && currentHook <= 13)) throw new Error('Cannot execute user command outside of cursor callbacks.');
    if (arguments.length < 1 || typeof name !== 'string') return false;
    let r;
    if (shortcutUsed) r = 2;
    else { r = N.shortcut(name); if (r === 0) shortcutUsed = true; }
    if (r === 0) return true;
    if (r === 1) return false;
    if (r === 2) throw new Error('Cannot execute more than one user command per cursor click.');
    return undefined;
  },
  get screenResolution() { notGlobal('screenResolution'); return mk(T_VEC2, [F.sw, F.sh]); },
  get canvasSize() { notGlobal('canvasSize'); return mk(T_VEC2, [Math.trunc(F.cw), Math.trunc(F.ch)]); },
  get userProperties() {
    notGlobal('userProperties');
    if (!userPropsCache) userPropsCache = _Internal.convertUserProperties(N.userProperties(false));
    return userPropsCache;
  },
  get timeOfDay() { notGlobal('timeOfDay'); return F.tod; },
  get frametime() { notGlobal('frametime'); return F.dt; },
  get runtime() { notGlobal('runtime'); return F.runtime; },
  AUDIO_RESOLUTION_16: 16, AUDIO_RESOLUTION_32: 32, AUDIO_RESOLUTION_64: 64
};
const input = {
  get cursorWorldPosition() { notGlobal('cursorWorldPosition'); return mk(T_VEC3, [F.wx, F.wy, F.wz]); },
  get cursorScreenPosition() { notGlobal('cursorScreenPosition'); return mk(T_VEC2, [F.sx, F.sy]); },
  get cursorLeftDown() { notGlobal('cursorLeftDown'); return F.down; }
};
// dll 0x1816541d0: symbols become their description, arguments are joined with ' ', every '%' is deleted (the text is
// later a vsnprintf format, truncated to 16383 bytes); a throwing toString aborts the call.
function joinArgs(args) {
  const t = Array.prototype.map.call(args, (a) => String(typeof a === 'symbol' ? a.description : a)).join(' ').split('%').join('');
  return t.length > 16383 ? t.slice(0, 16383) : t;
}
const console = {
  log() { N.log(0, joinArgs(arguments)); },
  error() { N.log(1, joinArgs(arguments)); }
};
// dll 0x181658680 set / 0x181658a80 get / 0x181658f70 delete / 0x181659150 clear: the host gets one flag,
// `location === "global"` (string compare at 0x181658807 …); a missing or any other location uses the other
// store, so the default is NOT the global store. Keys must be strings (one message for all three).
function loc(l) { return (typeof l === 'string' && l === 'global') ? 'global' : 'screen'; }
function lsScope(what) { if (scope === 0) throw new Error(what + ' cannot be cleared from global scope.'); }
function lsKey(k) { if (typeof k !== 'string') throw new Error('LocalStorageSet key not a string.'); }
const localStorage = {
  set(key, value, location) {
    lsScope('LocalStorageSet'); lsKey(key);
    N.storage(0, loc(location), key, JSON.stringify(value));
  },
  // Missing key → undefined; a stored value that no longer parses → null (0x181658e2a).
  get(key, location) {
    lsScope('LocalStorageGet'); lsKey(key);
    const s = N.storage(1, loc(location), key, '');
    if (s === null || s === undefined) return undefined;
    try { return JSON.parse(s); } catch (e) { return null; }
  },
  delete(key, location) { lsScope('LocalStorageDelete'); lsKey(key); N.storage(2, loc(location), key, ''); },
  clear(location) { lsScope('LocalStorageClear'); N.storage(3, loc(location), '', ''); },
  LOCATION_GLOBAL: 'global',
  LOCATION_SCREEN: 'screen'
};
global.engine = engine;
global.input = input;
global.console = console;
global.localStorage = localStorage;
Object.defineProperty(global, 'thisObject', { get() { const h = objStack[objStack.length - 1]; return h === undefined ? null : wrap(h); }, configurable: true });
Object.defineProperty(global, 'thisLayer', { get() { const h = layerStack[layerStack.length - 1]; return h === undefined ? null : wrap(h); }, configurable: true });

// ---- timers (§3.1, §3.5) ----
// Timer record (dll 0x181655f68, 0x30 bytes): float remaining/interval (ms / 1000 rounded to float), repeat,
// thisObject/thisLayer, the function and the cancel handle. Kept in the script's vector (script+0x160).
function addTimer(argc, fn, ms, repeat) {
  if (argc < 1 || typeof fn !== 'function') return null;
  const rec = curScript();
  if (!rec) return null;   // 0x181643fb0: no current script
  const secs = (argc > 1 && isNum(ms)) ? Math.fround(ms / 1000) : 0;
  const t = { remaining: secs, interval: secs, repeat: repeat, fn: fn, dead: false,
              obj: objStack[objStack.length - 1], layer: layerStack[layerStack.length - 1] };
  const handle = { live: true };
  t.handle = handle;
  rec.timers.push(t);
  // Cancel function 0x181656780: if its handle still holds a timer, it clears the handle and erases the FIRST
  // timer of the owning script (begin() of script+0x160, 0x1816568d3–0x18165690b), not necessarily this one;
  // then returns true. A cleared handle returns false.
  return function() {
    if (scope === 0) throw new Error('timeout cannot be cleared from global scope.');
    if (!handle.live) return false;
    handle.live = false;
    if (rec.timers.length) { rec.timers[0].dead = true; rec.timers.shift(); }
    return true;
  };
}
// Tick 0x18164f800: iterate a copy of the script's timer vector; remaining -= dt (float); > 0 → wait.
// Firing pushes thisObject/thisLayer and the "callback" scope; a throw is logged (no disabling). Afterwards a
// repeating timer is reset to its interval, a one-shot is erased and its handle cleared (0x18165034d–0x181650483).
function runTimers(rec, dt) {
  const list = rec.timers;
  if (!list.length) return;
  const copy = list.slice();
  for (const t of copy) {
    if (t.dead) continue;
    t.remaining = Math.fround(t.remaining - dt);
    if (t.remaining > 0) continue;
    enter(1, rec, t.obj, t.layer);
    try { t.fn(); } catch (e) { report(rec, e, 'timer'); }
    finally { leave(); }
    if (t.dead) continue;
    if (t.repeat) t.remaining = t.interval;
    else {
      t.dead = true; t.handle.live = false;
      const i = list.indexOf(t);
      if (i >= 0) list.splice(i, 1);
    }
  }
}

// ---- modules ----
const modules = new Map();
function require(spec) {
  let key = String(spec).toLowerCase();
  if (!key.endsWith('.js')) key += '.js';
  if (modules.has(key)) return modules.get(key);
  const fn = N.loadModule(key);
  if (typeof fn !== 'function') throw new Error('Unable to load module \'' + spec + '\'');
  const ns = fn(require);
  modules.set(key, ns);
  return ns;
}

// ---- scripts ----
const scripts = [];
function report(rec, e, where) {
  let msg;
  if (e && typeof e === 'object') {
    msg = String(e.message !== undefined ? (e.name ? e.name + ': ' : '') + e.message : e);
    if (e.line !== undefined) msg += ' (line ' + e.line + ', col ' + e.column + ')';
  } else {
    msg = String(e);
  }
  N.log(2, (rec ? rec.name : '?') + (where ? ' [' + where + ']' : '') + ': ' + msg);
}
let currentHook = -1;   // engine+0x62c
function callHook(rec, idx, args) {
  const fn = rec.hooks[idx];
  if (!fn || (rec.disabled & (1 << idx))) return undefined;
  enter(1, rec, rec.obj, rec.layer);
  const prevHook = currentHook; currentHook = idx;
  try { return fn.apply(undefined, args); }
  catch (e) { report(rec, e, HOOKS[idx]); rec.disabled |= (1 << idx); return undefined; }
  finally { currentHook = prevHook; leave(); }
}

// ---- media integration (exe session mgr+0x140, Bindings_Tick 0x1401714ab, replay 0x140172bdb; DLL CallHook cases
// 14–18 0x18164f56a / 0x18164f41d / 0x18164ee18 / 0x18164f12b / 0x18164f4dc) ----
const MEDIA = { enabled: false, state: 0, props: null, thumb: false, colors: [0, 0, 0, 0, 0], position: 0, duration: 0 };
const MEDIA_PROPS = ['title', 'artist', 'albumArtist', 'albumTitle', 'subTitle', 'genres', 'contentType'];
const MEDIA_COLORS = ['primaryColor', 'secondaryColor', 'tertiaryColor', 'textColor', 'highContrastColor'];
function mediaArg(idx) {
  switch (idx) {
  case 14: return { enabled: MEDIA.enabled };
  case 15: return { state: MEDIA.state | 0 };
  case 16: {
    const o = {};
    for (const k of MEDIA_PROPS) o[k] = String((MEDIA.props && MEDIA.props[k]) || '');
    return o;
  }
  case 17: {
    // u32 0x00BBGGRR per colour: x = (c & 0xff) / 255, y = (c >> 8 & 0xff) / 255, z = (c >> 16 & 0xff) / 255 (float).
    const o = { hasThumbnail: MEDIA.thumb };
    MEDIA_COLORS.forEach((k, i) => {
      const c = MEDIA.colors[i] >>> 0;
      o[k] = mk(T_VEC3, [Math.fround((c & 0xff) / 255), Math.fround(((c >>> 8) & 0xff) / 255), Math.fround(((c >>> 16) & 0xff) / 255)]);
    });
    return o;
  }
  case 18: return { position: Math.fround(MEDIA.position), duration: Math.fround(MEDIA.duration) };
  }
}
function mediaDispatch(list, idx) {
  for (const rec of list) {
    if (rec.state !== 2 || !rec.hooks[idx]) continue;
    callHook(rec, idx, [mediaArg(idx)]);
  }
}
// Replay to scripts initialised now: status if enabled, playback if state != 0, properties if the title is not
// empty, thumbnail if the thumbnail data is not empty, timeline if duration != 0.
function replayMedia(list) {
  if (!N.mediaSession()) return;
  if (MEDIA.enabled) mediaDispatch(list, 14);
  if (MEDIA.state !== 0) mediaDispatch(list, 15);
  if (MEDIA.props && MEDIA.props.title) mediaDispatch(list, 16);
  if (MEDIA.thumb) mediaDispatch(list, 17);
  if (MEDIA.duration !== 0) mediaDispatch(list, 18);
}
// One queued event: flags 0x10 status, 0x4 playback, 0x1 properties, 0x2 thumbnail, 0x8 timeline. A thumbnail
// first updates the `$mediaThumbnail` user properties and runs the user-property pass (applyUserProperties with
// an empty object: the entries have no `type`), then the hooks fire in the order 14, 15, 16, 17, 18.
function mediaEvent(ev) {
  const f = ev.flags | 0;
  if (f & 2) {
    MEDIA.thumb = !!ev.thumb; MEDIA.colors = ev.colors || [0, 0, 0, 0, 0];
    api.userPropertiesChanged('{}', null);
  }
  if (f & 0x10) { MEDIA.enabled = !!ev.enabled; mediaDispatch(scripts, 14); }
  if (f & 4) { MEDIA.state = ev.state | 0; mediaDispatch(scripts, 15); }
  if (f & 1) { MEDIA.props = ev.props || {}; mediaDispatch(scripts, 16); }
  if (f & 2) mediaDispatch(scripts, 17);
  if (f & 8) { MEDIA.position = +ev.position || 0; MEDIA.duration = +ev.duration || 0; mediaDispatch(scripts, 18); }
}
// animationEvent payload: the event's JSON text, parsed under a TryCatch; a parse failure gives null.
function parseEvent(json) {
  try { return JSON.parse(json); } catch (e) { return null; }
}

const api = {
  defineClass: defineClass,
  setFrame: setFrame,
  mk: mk,
  wrap: wrap,
  setScene(h) { global.thisScene = wrap(h, 'scene'); },
  /// Compiles one binding (CreateScript, §2.2). Returns the script index, or -1.
  create(fn, obj, layer, type, key, name, propsJSON) {
    const rec = { fn: fn, ns: null, hooks: new Array(19).fill(null), mask: 0, disabled: 0, state: 0,
                  obj: obj, layer: layer, type: type, key: key, name: name, timers: [] };
    enter(0, rec, undefined, undefined);
    try {
      rec.ns = fn(require);
    } catch (e) {
      report(rec, e, 'compile');
      return -1;
    } finally { leave(); }
    for (let i = 0; i < 19; i++) {
      let f;
      try { f = rec.ns[HOOKS[i]]; } catch (e) { f = undefined; }
      if (typeof f === 'function') { rec.hooks[i] = f; rec.mask |= (1 << i); }
    }
    if (propsJSON) {
      try {
        const sp = rec.ns.scriptProperties;
        if (sp !== null && typeof sp === 'object') _Internal.updateScriptProperties(rec.ns, propsJSON);
      } catch (e) { report(rec, e, 'scriptproperties'); }
    }
    scripts.push(rec);
    return scripts.length - 1;
  },
  mask(i) { return scripts[i].mask; },
  /// `0x140172830` for one batch (scene load: the general bindings, then each object right after it is created;
  /// createLayer: the new object): state 2, init(value), replay of the cached media session. Returns the init
  /// results per index (null = nothing to write). Scripts initialised during scene load are remembered for the
  /// load-time applyUserProperties pass (`loadUserProperties`).
  initScripts(idx, values, loading) {
    const out = [], fresh = [];
    for (let j = 0; j < idx.length; j++) {
      const rec = scripts[idx[j]];
      if (!rec || rec.state !== 0) { out.push(null); continue; }
      rec.state = 2;
      fresh.push(rec);
      let c;
      if (rec.hooks[0]) c = fromJS(rec.type, callHook(rec, 0, [toJS(rec.type, values[j])]));
      out.push(c === undefined ? null : c);
    }
    if (fresh.length) replayMedia(fresh);
    return out;
  },
  /// Scene_ApplyUserProperties at the end of the load (0x140114f10 → 0x140181f30 → 0x1401731d0): every
  /// initialised script that exports applyUserProperties gets all user properties, in registration order.
  loadUserProperties() {
    let json = null;
    for (const rec of scripts) {
      if (rec.state !== 2 || !rec.hooks[4]) continue;
      if (json === null) json = N.userProperties(true);
      callHook(rec, 4, [_Internal.convertUserProperties(json)]);
    }
  },
  /// One frame. `values[i]` is script i's current property value; returns per-script values to write back
  /// (null = none). Order (docs/re/08 §2.3, §7):
  /// 1. scripts still in state 0 (normally none: `initScripts` runs them when their object is created) get
  ///    init and the media replay;
  /// 2. Bindings_Tick 0x140171440: queued media events (hooks 14–18), animation events (hook 6), engine Tick
  ///    (audio buffers, timers), update.
  /// `media`: array of media events or null; `anim`: array of [layer, owner, eventJSON] or null.
  tick(frame, values, media, anim) {
    setFrame(frame);
    const n = scripts.length;
    const out = new Array(n).fill(null);
    const fresh = [];
    for (let i = 0; i < n; i++) {
      const rec = scripts[i];
      if (rec.state !== 0) continue;
      rec.state = 2;
      fresh.push(rec);
      if (!rec.hooks[0]) continue;
      const c = fromJS(rec.type, callHook(rec, 0, [toJS(rec.type, values[i])]));
      if (c !== undefined) { out[i] = c; values[i] = c; }
    }
    if (fresh.length) replayMedia(fresh);
    if (media) for (const ev of media) mediaEvent(ev);
    if (anim) {
      for (const [layer, owner, json] of anim) {
        for (let i = 0; i < n; i++) {
          const rec = scripts[i];
          if (rec.state !== 2 || !rec.hooks[6]) continue;
          if (layer !== null && rec.layer !== layer && rec.obj !== owner) continue;
          const c = fromJS(rec.type, callHook(rec, 6, [parseEvent(json), toJS(rec.type, values[i])]));
          if (c !== undefined) { out[i] = c; values[i] = c; }
        }
      }
    }
    if (audioBuffers.length) {
      const a = N.audio();
      for (const b of audioBuffers) {
        const r = b.left.length, l = r === 16 ? a[0] : r === 32 ? a[2] : a[4], rr = r === 16 ? a[1] : r === 32 ? a[3] : a[5];
        for (let k = 0; k < r; k++) { b.left[k] = l[k]; b.right[k] = rr[k]; b.average[k] = (l[k] + rr[k]) * 0.5; }
      }
    }
    for (let i = 0; i < n; i++) runTimers(scripts[i], F.dt);
    for (let i = 0; i < n; i++) {
      const rec = scripts[i];
      if (!rec.hooks[1] || (rec.disabled & 2)) continue;
      const c = fromJS(rec.type, callHook(rec, 1, [toJS(rec.type, values[i])]));
      if (c !== undefined) out[i] = c;
    }
    return out;
  },
  /// Live user-property change (Scene_ApplyUserProperties 0x140181f30 → 0x1401731d0): drop the cached
  /// engine.userProperties, re-apply bound script properties, then applyUserProperties(changed) on every
  /// initialised script that exports it. `changedJSON` holds only entries with both `value` and `type`.
  userPropertiesChanged(changedJSON, scriptPropsByIndex) {
    userPropsCache = null;
    for (let i = 0; i < scripts.length; i++) {
      const rec = scripts[i];
      if (rec.state !== 2) continue;
      if (scriptPropsByIndex && scriptPropsByIndex[i] !== undefined) {
        try {
          const sp = rec.ns.scriptProperties;
          if (sp !== null && typeof sp === 'object') _Internal.updateScriptProperties(rec.ns, scriptPropsByIndex[i]);
        } catch (e) { report(rec, e, 'scriptproperties'); }
      }
      if (rec.hooks[4]) callHook(rec, 4, [_Internal.convertUserProperties(changedJSON)]);
    }
  },
  /// resizeScreen (hook 2) for every script.
  resize(w, h) {
    for (const rec of scripts) if (rec.hooks[2]) callHook(rec, 2, [mk(T_VEC2, [w, h])]);
  },
  /// Cursor hooks 8–13 for the scripts whose thisLayer is `layer`.
  // Event builder dll 0x18164ec5f: button is always 0; `hitBox` exists only when the exe's puppet hit test named a bone.
  // openUserShortcut is accepted only in hooks 11–13 (0x181656b8c).
  cursor(idx, layer, button, world, local, hitBox) {
    cursorCallback = idx >= 11 && idx <= 13; shortcutUsed = false;
    try {
      for (const rec of scripts) {
        // Scene_HitTest 0x14018a36c–0x14018a378: a binding gets the event when its layer (+0x48) is the hit object or
        // when it has no owner (+8 == 0); then hook bit and state 2.
        if (!rec.hooks[idx] || (rec.layer !== layer && rec.obj !== undefined && rec.obj !== null)) continue;
        const ev = { button: 0, worldPosition: mk(T_VEC3, world), localPosition: mk(T_VEC3, local) };
        if (typeof hitBox === 'string') ev.hitBox = hitBox;
        callHook(rec, idx, [ev]);
      }
    } finally { cursorCallback = false; }
  },
  /// Layers with at least one cursor-hook script (mask bits 7–13).
  /// Whether an owner-less binding (no `obj`) has cursor hooks: it hears every object's events.
  cursorOwnerless() {
    for (const rec of scripts) if ((rec.mask & 0x3f80) && (rec.obj === undefined || rec.obj === null)) return true;
    return false;
  },
  cursorLayers() {
    const s = new Set();
    for (const rec of scripts) if ((rec.mask & 0x3f80) && rec.layer !== undefined) s.add(rec.layer);
    return Array.from(s);
  },
  callback(id) {
    const c = callbacks[id];
    if (!c) return;
    enter(1, c.rec, c.obj, c.layer);
    try { c.fn(); } catch (e) { report(c.rec, e, 'callback'); }
    finally { leave(); }
  },
  destroyAll() {
    for (const rec of scripts) if (rec.hooks[3]) callHook(rec, 3, []);
  },
  invalidateUserProperties() { userPropsCache = null; }
};
return api;
})
"""#
}
