'use strict';
/*
 * One preload for every Clicky window. Exposes a tiny, whitelisted IPC surface.
 */
const { contextBridge, ipcRenderer } = require('electron');

const INVOKE = new Set([
  'settings:get', 'settings:set', 'settings:setApiKey', 'settings:validateKey', 'settings:resetAll',
  'status:get', 'panel:action', 'chat:send', 'chat:history', 'chat:clear',
  'job:respond', 'job:stop', 'job:run', 'job:list', 'routine:delete', 'routine:toggle', 'routine:add', 'memory:delete',
  'overlay:event', 'overlay:ready', 'model3d:ask', 'model3d:ready', 'notch:resize',
  'audio:levels', 'audio:recorded', 'audio:ended', 'audio:error', 'audio:ready',
  'voice:test', 'app:info', 'window:control', 'permissions:request',
]);
const ON = new Set([
  'status', 'settings', 'voice-state', 'audio-level', 'cursor', 'overlay:init', 'overlay:point', 'overlay:draw',
  'overlay:cards', 'overlay:caption', 'overlay:onboarding', 'overlay:clear', 'overlay:fade-out', 'overlay:prompt-dismiss',
  'overlay:pointing-state', 'overlay:show', 'jobs', 'job-update', 'job-prompt', 'notify', 'chat-msg', 'model3d:show', 'drive-state',
  'home:section', 'audio:start', 'audio:stop', 'audio:cancel', 'audio:play', 'audio:stop-playback', 'audio:music', 'notch:state',
]);

contextBridge.exposeInMainWorld('clicky', {
  invoke(channel, payload) {
    if (!INVOKE.has(channel)) return Promise.reject(new Error('blocked channel ' + channel));
    return ipcRenderer.invoke(channel, payload);
  },
  on(channel, cb) {
    if (!ON.has(channel)) throw new Error('blocked channel ' + channel);
    const handler = (_e, data) => cb(data);
    ipcRenderer.on(channel, handler);
    return () => ipcRenderer.removeListener(channel, handler);
  },
  platform: process.platform,
});
