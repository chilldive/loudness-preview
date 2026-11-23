const { app, BrowserWindow, nativeTheme, ipcMain, dialog, protocol, net } = require('electron')
const { pathToFileURL } = require('url')
const path = require('path')
const fs = require('fs')

app.commandLine.appendSwitch('enable-features', 'SharedArrayBuffer')
protocol.registerSchemesAsPrivileged([
  { scheme: 'app', privileges: { standard: true, secure: true, supportFetchAPI: true, corsEnabled: true } },
])
const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.wasm': 'application/wasm' }
app.commandLine.appendSwitch('js-flags', '--max-old-space-size=8192')

const isMac = process.platform === 'darwin'
const colors = () => nativeTheme.shouldUseDarkColors
  ? { color: '#1e1e1e', symbolColor: '#d8d8d8' }
  : { color: '#ffffff', symbolColor: '#3a3a3a' }

let win
const pending = []

function audioArgs(argv) {
  return argv.slice(app.isPackaged ? 1 : 2).filter(a => !a.startsWith('-') && fs.existsSync(a))
}

function sendPaths(paths) {
  if (!paths.length) return
  if (win && win.webContents && !win.webContents.isLoading()) win.webContents.send('open-paths', paths)
  else pending.push(...paths)
}

function create() {
  win = new BrowserWindow({
    width: 960, height: 660, minWidth: 820, minHeight: 560,
    show: false,
    backgroundColor: colors().color,
    title: 'Loudness Preview',
    titleBarStyle: 'hidden',
    ...(isMac ? { trafficLightPosition: { x: 16, y: 18 } } : { titleBarOverlay: { ...colors(), height: 52 } }),
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      sandbox: false,
      autoplayPolicy: 'no-user-gesture-required',
    },
  })
  win.removeMenu()
  if (process.env.LP_DEBUG) win.webContents.on('console-message', (e) => console.log('[ui]', e.level, e.message))
  win.loadURL('app://ui/index.html')
  win.once('ready-to-show', () => win.show())
  win.webContents.on('did-finish-load', () => {
    if (pending.length) { win.webContents.send('open-paths', pending.splice(0)) }
  })
  nativeTheme.on('updated', () => {
    if (!isMac) win.setTitleBarOverlay({ ...colors(), height: 52 })
    win.setBackgroundColor(colors().color)
  })
}

if (!app.requestSingleInstanceLock()) {
  app.quit()
} else {
  app.on('second-instance', (_e, argv) => {
    sendPaths(audioArgs(argv))
    if (win) { if (win.isMinimized()) win.restore(); win.focus() }
  })
  app.on('open-file', (e, p) => { e.preventDefault(); sendPaths([p]) })
  app.whenReady().then(() => {
    // Serve the UI from app:// with cross-origin isolation (SharedArrayBuffer, wasm fetch)
    const uiRoot = path.join(__dirname, 'ui')
    protocol.handle('app', async (req) => {
      const rel = decodeURIComponent(new URL(req.url).pathname).replace(/^\/+/, '')
      const file = path.normalize(path.join(uiRoot, rel))
      if (!file.startsWith(uiRoot)) return new Response('', { status: 403 })
      const res = await net.fetch(pathToFileURL(file).toString())
      return new Response(res.body, { status: res.status, headers: {
        'content-type': MIME[path.extname(file)] || 'application/octet-stream',
        'cross-origin-opener-policy': 'same-origin',
        'cross-origin-embedder-policy': 'require-corp',
        'cross-origin-resource-policy': 'same-origin',
      } })
    })
    ipcMain.handle('open-dialog', async () => {
      const r = await dialog.showOpenDialog(win, {
        properties: ['openFile', 'multiSelections'],
        filters: [{ name: 'Audio', extensions: ['wav', 'aif', 'aiff', 'flac', 'mp3', 'm4a', 'aac', 'ogg', 'opus', 'wave'] }],
      })
      return r.canceled ? [] : r.filePaths
    })
    ipcMain.handle('read-file', async (_e, p) => {
      const b = await fs.promises.readFile(p)
      return b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength)
    })
    create()
    sendPaths(audioArgs(process.argv))
  })
  app.on('window-all-closed', () => app.quit())
}
