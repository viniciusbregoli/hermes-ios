// The Bot Screen viewer inside the app's WKWebView: noVNC's RFB client on the gateway's /api/display/ws.
// Swift drives it through window.screen* and hears back on webkit.messageHandlers.screen.
import RFB from '@novnc/novnc'
import KeyTable from './node_modules/@novnc/novnc/core/input/keysym.js'
import keysyms from './node_modules/@novnc/novnc/core/input/keysymdef.js'

const post = message => window.webkit.messageHandlers.screen.postMessage(message)
const host = document.getElementById('screen')
let rfb = null

window.screenConnect = (url, viewOnly) => {
    window.screenDisconnect()
    const ws = new WebSocket(url)
    ws.binaryType = 'arraybuffer'
    // noVNC's disconnect event carries only {clean}; the bridge's verdict (4000 control-taken) is the close code.
    let closeCode = 0
    ws.addEventListener('close', e => { closeCode = e.code })
    const client = new RFB(host, ws, { shared: true })
    client.scaleViewport = true
    client.resizeSession = false
    client.background = 'transparent'
    client.qualityLevel = 7
    client.viewOnly = viewOnly
    client.addEventListener('connect', () => post({ type: 'connect' }))
    client.addEventListener('disconnect', e => {
        // A client replaced or closed on purpose has nothing to report.
        if (rfb !== client) return
        rfb = null
        post({ type: 'disconnect', code: closeCode, clean: !!e.detail?.clean })
    })
    rfb = client
}

window.screenDisconnect = () => { const client = rfb; rfb = null; client?.disconnect() }

window.screenViewOnly = viewOnly => { if (rfb) rfb.viewOnly = viewOnly }

// Text from the app's native keyboard and paste, sent as keysyms; nothing is kept here.
const named = { '\n': KeyTable.XK_Return, '\t': KeyTable.XK_Tab, '\b': KeyTable.XK_BackSpace }
window.screenType = text => {
    for (const ch of text) rfb?.sendKey(named[ch] ?? keysyms.lookup(ch.codePointAt(0)), null)
}

post({ type: 'ready' })
