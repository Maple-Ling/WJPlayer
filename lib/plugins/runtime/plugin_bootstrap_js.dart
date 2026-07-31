/// 引导脚本：在插件 main.js 之前注入，基于唯一的宿主桥 `__lp_host`
/// 构建插件可见的全局 `ctx` 对象，并提供宿主回调入口 `__lp_invoke`。
///
/// 约定：
///  - `__lp_host(channel, method, argsJson)` 由 Dart 注入，返回 Promise<string>，
///    字符串是 `{ok:true,value:...}` 或 `{ok:false,error:"..."}` 的 JSON。
///  - 插件注册的回调（actions/eventListeners/settingsPages 的 handler 等）以函数形式
///    出现在描述对象里，引导脚本会把它们替换成 `{__handler__:"id"}` 再交给宿主；
///    宿主触发时通过 `__lp_invoke('__handler', '["id", args]')` 回调。
const String kPluginBootstrapJs = r'''
(function () {
  'use strict';

  var __handlers = {};
  var __handlerSeq = 0;
  var __eventListeners = {}; // event -> [fn]

  function __callHost(channel, method, args) {
    var payload;
    try {
      payload = JSON.stringify(args === undefined ? [] : args);
    } catch (e) {
      return Promise.reject(new Error('参数无法序列化: ' + e));
    }
    return __lp_host(channel, method, payload).then(function (str) {
      var res;
      try { res = JSON.parse(str); } catch (e) { throw new Error('宿主返回非法: ' + str); }
      if (res && res.ok) return res.value;
      throw new Error((res && res.error) ? res.error : '宿主调用失败');
    });
  }

  // 递归把描述对象里的函数替换成 {__handler__: id}，并登记到 __handlers。
  function __serialize(value) {
    if (typeof value === 'function') {
      var id = 'h' + (++__handlerSeq);
      __handlers[id] = value;
      return { __handler__: id };
    }
    if (Array.isArray(value)) {
      return value.map(__serialize);
    }
    if (value && typeof value === 'object') {
      var out = {};
      for (var k in value) {
        if (Object.prototype.hasOwnProperty.call(value, k)) {
          out[k] = __serialize(value[k]);
        }
      }
      return out;
    }
    return value;
  }

  // ---- ctx.log ----
  var log = {
    info: function (msg) { return __callHost('log', 'info', [String(msg)]); },
    warn: function (msg) { return __callHost('log', 'warn', [String(msg)]); },
    error: function (msg) { return __callHost('log', 'error', [String(msg)]); }
  };

  // ---- ctx.http（仅 HTTPS，域名白名单由宿主校验）----
  var http = {
    get: function (url, options) {
      return __callHost('http', 'get', [url, options || {}]);
    },
    post: function (url, body, options) {
      return __callHost('http', 'post', [url, body, options || {}]);
    },
    delete: function (url, options) {
      return __callHost('http', 'delete', [url, options || {}]);
    }
  };

  // ---- ctx.storage（每插件独立，<=5MB）----
  var storage = {
    get: function (key) { return __callHost('storage', 'get', [String(key)]); },
    set: function (key, val) { return __callHost('storage', 'set', [String(key), val]); },
    delete: function (key) { return __callHost('storage', 'delete', [String(key)]); },
    keys: function () { return __callHost('storage', 'keys', []); },
    clear: function () { return __callHost('storage', 'clear', []); }
  };

  // ---- ctx.player ----
  var player = {
    getCurrentMedia: function () { return __callHost('player', 'getCurrentMedia', []); },
    play: function () { return __callHost('player', 'play', []); },
    pause: function () { return __callHost('player', 'pause', []); },
    seek: function (seconds) { return __callHost('player', 'seek', [Number(seconds)]); },
    on: function (event, fn) {
      if (typeof fn !== 'function') return;
      (__eventListeners[event] = __eventListeners[event] || []).push(fn);
    },
    off: function (event, fn) {
      var list = __eventListeners[event];
      if (!list) return;
      __eventListeners[event] = list.filter(function (f) { return f !== fn; });
    }
  };

  // ---- ctx.ui ----
  var ui = {
    showToast: function (msg, opts) { return __callHost('ui', 'showToast', [String(msg), opts || {}]); },
    showDialog: function (opts) { return __callHost('ui', 'showDialog', [opts || {}]); },
    // 弹出一个表单（字段 schema），resolve 为 {字段名: 值} 或 null（取消）
    showForm: function (schema) { return __callHost('ui', 'showForm', [schema || {}]); },
    showList: function (opts) { return __callHost('ui', 'showList', [opts || {}]); },
    openPage: function (pageId, params) { return __callHost('ui', 'openPage', [String(pageId), params || {}]); },
    showProgress: function (opts) { return __callHost('ui', 'showProgress', [opts || {}]); },
    updateProgress: function (id, opts) { return __callHost('ui', 'updateProgress', [String(id), opts || {}]); },
    closeProgress: function (id) { return __callHost('ui', 'closeProgress', [String(id)]); }
  };

  // ---- ctx.emby ----
  var emby = {
    getCurrentUser: function () { return __callHost('emby', 'getCurrentUser', []); },
    getServerUrl: function () { return __callHost('emby', 'getServerUrl', []); },
    // 返回 { url, name, username, userId }（username 来自添加服务器时填写的账号）
    getServerInfo: function () { return __callHost('emby', 'getServerInfo', []); },
    // 返回 { username, password, url }（需要 emby.credentials 权限）
    getCredentials: function () { return __callHost('emby', 'getCredentials', []); },
    apiRequest: function (opts) { return __callHost('emby', 'apiRequest', [opts || {}]); }
  };

  // ---- ctx.extensions ----
  var extensions = {
    register: function (type, descriptor) {
      var serialized = __serialize(descriptor || {});
      return __callHost('extensions', 'register', [String(type), serialized]);
    },
    unregister: function (type, id) {
      return __callHost('extensions', 'unregister', [String(type), String(id)]);
    }
  };

  // ---- ctx.cfproxy（CF 优选反代，需 cfproxy 权限）----
  var cfproxy = {
    // 列出已添加服务器及其优选状态：[{id,name,host,url,active,pinnedIp,latencyMs,downloadKBps,scheduleEnabled,scheduleMinutes}]
    listServers: function () { return __callHost('cfproxy', 'listServers', []); },
    // 当前已启用反代的概况：{active:[{id,name,pinnedIp,latencyMs,downloadKBps,scheduleEnabled}]}
    getStatus: function () { return __callHost('cfproxy', 'getStatus', []); },
    // 打开宿主提供的「优选反代」可视化面板（推荐入口，自带实时测速进度）
    openPanel: function () { return __callHost('cfproxy', 'openPanel', []); },
    // 对某服务器测速并应用最优 IP，resolve 为最优结果或 null
    speedTest: function (serverId) { return __callHost('cfproxy', 'speedTest', [{ serverId: serverId }]); },
    // 关闭某服务器的反代，恢复直连
    disable: function (serverId) { return __callHost('cfproxy', 'disable', [{ serverId: serverId }]); },
    // 定时测速：setSchedule(serverId, enabled, minutes)
    setSchedule: function (serverId, enabled, minutes) {
      return __callHost('cfproxy', 'setSchedule', [{ serverId: serverId, enabled: !!enabled, minutes: Number(minutes) || 30 }]);
    },
    // 生命周期：按持久化配置恢复 / 全部拆除（通常在 onEnable/onDisable 调用）
    restore: function () { return __callHost('cfproxy', 'restore', []); },
    teardown: function () { return __callHost('cfproxy', 'teardown', []); }
  };

  globalThis.ctx = {
    log: log,
    http: http,
    storage: storage,
    player: player,
    ui: ui,
    emby: emby,
    extensions: extensions,
    cfproxy: cfproxy,
    // 延时（毫秒），用于重试退避。封顶 10s。
    sleep: function (ms) { return __callHost('util', 'sleep', [Number(ms) || 0]); },
    // 插件元信息，由宿主在加载后通过 __lp_setMeta 注入
    plugin: {}
  };

  globalThis.__lp_setMeta = function (meta) {
    globalThis.ctx.plugin = meta || {};
  };

  // 宿主 -> 插件 的统一回调入口。返回 Promise<string(JSON)>。
  globalThis.__lp_invoke = function (name, argsJson) {
    var args;
    try { args = JSON.parse(argsJson || '[]'); } catch (e) { args = []; }

    function wrap(p) {
      return Promise.resolve(p).then(function (v) {
        return JSON.stringify(v === undefined ? null : v);
      }).catch(function (e) {
        return JSON.stringify({ __error__: String(e && e.message ? e.message : e) });
      });
    }

    if (name === '__handler') {
      var id = args[0];
      var handlerArgs = Array.isArray(args[1]) ? args[1] : [args[1]];
      var fn = __handlers[id];
      if (typeof fn !== 'function') return Promise.resolve(JSON.stringify(null));
      return wrap(fn.apply(null, handlerArgs));
    }

    if (name === '__named') {
      var fnName = args[0];
      var fnArgs = Array.isArray(args[1]) ? args[1] : [];
      var fn = globalThis[fnName];
      if (typeof fn !== 'function') return Promise.resolve(JSON.stringify(null));
      return wrap(fn.apply(null, fnArgs));
    }

    if (name === '__event') {
      var event = args[0];
      var data = args[1];
      var list = __eventListeners[event] || [];
      var results = list.map(function (fn) {
        try { return Promise.resolve(fn(data)); } catch (e) { return Promise.resolve(null); }
      });
      return Promise.all(results).then(function () { return JSON.stringify(null); });
    }

    // 命名生命周期回调：onEnable / onDisable（插件可挂在 ctx 上）
    if (typeof globalThis['__lp_' + name] === 'function') {
      return wrap(globalThis['__lp_' + name].apply(null, args));
    }

    return Promise.resolve(JSON.stringify(null));
  };

  // 插件可注册生命周期： ctx.onEnable(fn) / ctx.onDisable(fn)
  globalThis.ctx.onEnable = function (fn) { globalThis.__lp_onEnable = fn; };
  globalThis.ctx.onDisable = function (fn) { globalThis.__lp_onDisable = fn; };
})();
''';
