'use strict';
const { contextBridge, ipcRenderer } = require('electron');
const methods = ['getState','preview','addDownloads','retryDownload','cancelDownload','removeDownload','chooseDownloadDirectory','chooseCookiesFile','chooseVideo','revealFile','openFile','startSubtitle','cancelSubtitle','retrySubtitle','prepareModels','cancelModelPreparation','saveSettings','openDownloadDirectory'];
const api = Object.fromEntries(methods.map(name => [name, (...args) => ipcRenderer.invoke(`feather:${name}`, ...args)]));
api.onState = callback => { const listener = (_event, value) => callback(value); ipcRenderer.on('feather:state', listener); return () => ipcRenderer.removeListener('feather:state', listener); };
ipcRenderer.on('feather:heartbeat', () => ipcRenderer.send('feather:heartbeat-reply'));
contextBridge.exposeInMainWorld('feather', api);
