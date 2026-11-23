const { contextBridge, ipcRenderer, webUtils } = require('electron')

contextBridge.exposeInMainWorld('host', {
  platform: process.platform,
  openDialog: () => ipcRenderer.invoke('open-dialog'),
  readFile: (p) => ipcRenderer.invoke('read-file', p),
  pathForFile: (f) => webUtils.getPathForFile(f),
  onOpenPaths: (fn) => ipcRenderer.on('open-paths', (_e, paths) => fn(paths)),
})
