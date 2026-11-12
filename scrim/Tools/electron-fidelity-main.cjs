const { app, BrowserWindow } = require("electron")

app.commandLine.appendSwitch("force-device-scale-factor", process.env.SCRIM_DEVICE_SCALE_FACTOR || "1")
app.commandLine.appendSwitch("disable-gpu")

app.whenReady().then(async () => {
    const window = new BrowserWindow({
        width: 1920,
        height: 1080,
        useContentSize: true,
        show: false,
        webPreferences: { backgroundThrottling: false }
    })
    await window.loadURL("about:blank")
})

app.on("window-all-closed", () => {})
