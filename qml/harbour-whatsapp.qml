import QtQuick 2.0
import Sailfish.Silica 1.0
import QtPositioning 5.2
import Sailfish.Pickers 1.0
import org.nemomobile.contacts 1.0
import io.thp.pyotherside 1.5

ApplicationWindow {
    id: app
    initialPage: mainPage
    cover: undefined

    property bool connected: false
    property string pairCode: ""
    property string pairErrorMsg: ""
    property string connState: ""
    property string lastError: ""
    property bool paired: false
    property bool backendFailed: false

    onConnectedChanged: if (mainPage) mainPage.updateAttachedStatus()

    function retryBackend() {
        backendFailed = false
        pairErrorMsg = ""
        call('start_backend.start', [])
    }
    property var waContactsMap: ({})
    property int backendPort: 8085
    property string phone: ""
    property var chats: []
    property var waContacts: []

    // Python backend starter
    Python {
        id: python
        
        Component.onCompleted: {
            addImportPath(Qt.resolvedUrl('..'))
            
            setHandler('backendReady', function(success, port) {
                if (success) {
                    if (port) backendPort = port
                    backendFailed = false
                    console.log("Backend ready on port " + backendPort)
                    checkStatus()
                    loadPrefs()
                } else {
                    console.log("Backend failed to start")
                    backendFailed = true
                    pairErrorMsg = "Backend did not start in time. This can happen " +
                        "on the first launch right after a reboot. Tap Retry, or see " +
                        "~/.local/share/harbour/harbour-whatsapp/backend.log"
                }
            })
            
            importModule('start_backend', function() {
                call('start_backend.start', [])
            })
        }
        
        Component.onDestruction: {
            call('start_backend.stop', [])
        }
        
        onError: {
            console.log("Python error:", traceback)
        }
    }


    
    
    // Sailfish Contacts: nur instanziiert, wenn der Opt-in aktiv ist -
    // ohne Einstellung wird die Kontaktdatenbank nie angefasst
    property bool contactsOptIn: false
    property string globalNotice: ""

    // ---- Live-Standort-Freigabe (app-weit, ueberlebt Seitenwechsel) ----
    property bool   liveActive: false
    property string liveChatJid: ""
    property double liveUntil: 0
    property bool   liveStarted: false   // Startpaket schon gesendet?
    property int    liveMinutes: 0

    function liveCall(path, cb) {
        var xhr = new XMLHttpRequest()
        xhr.open("GET", "http://127.0.0.1:" + backendPort + path)
        xhr.onreadystatechange = function() { if (xhr.readyState === 4 && cb) cb(xhr) }
        xhr.send()
    }

    function startLiveShare(chatJid, minutes) {
        liveChatJid = chatJid
        liveMinutes = minutes
        liveUntil = Date.now() + minutes * 60000
        liveStarted = false
        liveActive = true
        globalNotice = "Waiting for GPS fix to start live location\u2026"
    }

    function stopLiveShare() {
        if (liveChatJid !== "") {
            liveCall("/live/stop?to=" + liveChatJid)
        }
        liveActive = false
        liveStarted = false
        liveChatJid = ""
        globalNotice = "Live location ended"
    }

    PositionSource {
        id: livePosition
        active: liveActive
        updateInterval: 20000
        onPositionChanged: {
            if (!liveActive) return
            if (Date.now() > liveUntil) { stopLiveShare(); return }
            if (!position.latitudeValid || !position.longitudeValid) return
            var lat = position.coordinate.latitude.toFixed(6)
            var lon = position.coordinate.longitude.toFixed(6)
            if (!liveStarted) {
                liveCall("/live/start?to=" + liveChatJid + "&lat=" + lat + "&lon=" + lon
                         + "&minutes=" + liveMinutes, function(xhr) {
                    if (xhr.status === 200) {
                        liveStarted = true
                        globalNotice = "Sharing live location (" + liveMinutes + " min)"
                    } else {
                        globalNotice = "Live location failed: " + xhr.responseText
                        liveActive = false
                    }
                })
            } else {
                liveCall("/live/update?to=" + liveChatJid + "&lat=" + lat + "&lon=" + lon,
                         function(xhr) { if (xhr.status === 410) stopLiveShare() })
            }
        }
    }

    Timer {
        interval: 30000
        running: liveActive
        repeat: true
        onTriggered: if (Date.now() > liveUntil) stopLiveShare()
    }

    Loader {
        id: peopleLoader
        active: contactsOptIn
        sourceComponent: PeopleModel {
            filterType: PeopleModel.FilterAll
            requiredProperty: PeopleModel.PhoneNumberRequired
        }
    }

    property bool prefsLoaded: false

    function loadPrefs() {
        var xhr = new XMLHttpRequest()
        xhr.open("GET", "http://127.0.0.1:" + backendPort + "/prefs")
        xhr.onreadystatechange = function() {
            if (xhr.readyState === 4 && xhr.status === 200) {
                var p = JSON.parse(xhr.responseText) || {}
                contactsOptIn = p.contactSuggestions === "1"
                prefsLoaded = true
            }
        }
        xhr.send()
    }

    function setPref(key, value) {
        var xhr = new XMLHttpRequest()
        xhr.open("GET", "http://127.0.0.1:" + backendPort + "/prefs/set?key=" + key + "&value=" + encodeURIComponent(value))
        xhr.send()
    }
    
    // Landesvorwahl aus der eigenen Nummer ableiten (1/7 einstellig,
    // sonst bekannte zweistellige, sonst dreistellig)
    function ownCountryCode() {
        if (!phone) return ""
        var c1 = phone.charAt(0)
        if (c1 === "1" || c1 === "7") return c1
        var two = ["20","27","30","31","32","33","34","36","39","40","41",
                   "43","44","45","46","47","48","49","51","52","53","54",
                   "55","56","57","58","60","61","62","63","64","65","66",
                   "81","82","84","86","90","91","92","93","94","95","98"]
        var c2 = phone.substring(0, 2)
        if (two.indexOf(c2) >= 0) return c2
        return phone.substring(0, 3)
    }

    // Beliebige Nummer in kanonische internationale Form (JID-Nummer) wandeln
    function toJid(raw) {
        if (!raw) return ""
        var n = String(raw).replace(/[^0-9+]/g, "")
        if (n.indexOf("+") === 0) n = n.substring(1)
        else if (n.indexOf("00") === 0) n = n.substring(2)
        else if (n.indexOf("0") === 0) n = ownCountryCode() + n.substring(1)
        n = n.replace(/[^0-9]/g, "")
        return n.length >= 8 ? n : ""
    }

    // Find contact name from Sailfish contacts by phone number (jid)
    function findLocalContactName(phoneNumber) {
        if (!phoneNumber) return ""
        var jid = String(phoneNumber).replace(/[^0-9]/g, "")
        var suffixResult = ""

        var pm = peopleLoader.item
        if (!pm) return ""
        for (var i = 0; i < pm.count; i++) {
            var person = pm.get(i)
            if (person && person.phoneDetails) {
                for (var j = 0; j < person.phoneDetails.length; j++) {
                    var raw = person.phoneDetails[j].normalizedNumber || person.phoneDetails[j].number
                    var cand = toJid(raw)
                    // Exakter Treffer in kanonischer Form gewinnt sofort
                    if (cand !== "" && cand === jid) {
                        return person.displayLabel || ""
                    }
                    // Fallback: Suffix-Match nur mit >= 9 Ziffern (nationale Rufnummer),
                    // falls die Landesvorwahl-Heuristik danebenlag
                    if (suffixResult === "") {
                        var pn = String(raw || "").replace(/[^0-9]/g, "").replace(/^0+/, "")
                        var shorter = pn.length < jid.length ? pn : jid
                        var longer  = pn.length < jid.length ? jid : pn
                        if (shorter.length >= 9 &&
                            longer.lastIndexOf(shorter) === longer.length - shorter.length) {
                            suffixResult = person.displayLabel || ""
                        }
                    }
                }
            }
        }
        return suffixResult
    }
    
    // Lokales Adressbuch + WhatsApp-Kontakte zusammenfuehren
    function mergedContacts() {
        var merged = {}
        var i, c
        var pm = peopleLoader.item
        for (i = 0; pm && i < pm.count; i++) {
            var person = pm.get(i)
            if (!person || !person.phoneDetails) continue
            for (var j = 0; j < person.phoneDetails.length; j++) {
                var jid = toJid(person.phoneDetails[j].normalizedNumber
                                || person.phoneDetails[j].number)
                if (jid && !merged[jid]) {
                    merged[jid] = { jid: jid,
                                    name: person.displayLabel || ("+" + jid),
                                    source: "local" }
                }
            }
        }
        if (waContacts) {
            for (i = 0; i < waContacts.length; i++) {
                c = waContacts[i]
                merged[c.jid] = { jid: c.jid,
                                  name: (merged[c.jid] && merged[c.jid].name)
                                        || c.name || ("+" + c.jid),
                                  source: "whatsapp" }
            }
        }
        var result = []
        for (var key in merged) result.push(merged[key])
        result.sort(function(a, b) { return a.name.localeCompare(b.name) })
        return result
    }

    function getDisplayName(jid, waName) {
        var localName = findLocalContactName(jid)
        if (localName) return localName
        if (waName) return waName
        return "+" + jid
    }


    function rescanBackendPort() {
        // Backend kann auf 8085-8089 liegen; falls der gemerkte Port tot ist
        // (z.B. Launcher-Timeout, Backend kam spaeter auf anderem Port hoch),
        // alle Kandidaten durchprobieren
        for (var p = 8085; p <= 8089; p++) {
            if (p === backendPort) continue
            (function(port) {
                var probe = new XMLHttpRequest()
                probe.open("GET", "http://127.0.0.1:" + port + "/status")
                probe.onreadystatechange = function() {
                    if (probe.readyState === 4 && probe.status === 200) {
                        console.log("Backend rediscovered on port " + port)
                        backendPort = port
                        backendFailed = false
                        checkStatus()
                    }
                }
                probe.send()
            })(p)
        }
    }

    function checkStatus() {
        var xhr = new XMLHttpRequest()
        xhr.open("GET", "http://127.0.0.1:" + backendPort + "/status")
        xhr.onreadystatechange = function() {
            if (xhr.readyState === 4 && xhr.status !== 200) {
                rescanBackendPort()
            }
            if (xhr.readyState === 4 && xhr.status === 200) {
                var data = JSON.parse(xhr.responseText)
                var wasConnected = connected
                connected = data.connected
                pairCode = data.pairCode || ""
                phone = data.phone || ""
                connState = data.state || ""
                lastError = data.lastError || ""
                paired = data.paired === true
                if (!prefsLoaded && connState !== "starting") {
                    loadPrefs()
                }
                if (connected && !wasConnected) {
                    loadChats()
                    loadWAContacts()
                }
            }
        }
        xhr.send()
    }

    function loadChats() {
        var xhr = new XMLHttpRequest()
        xhr.open("GET", "http://127.0.0.1:" + backendPort + "/chats")
        xhr.onreadystatechange = function() {
            if (xhr.readyState === 4 && xhr.status === 200) {
                chats = JSON.parse(xhr.responseText) || []
            }
        }
        xhr.send()
    }

    function loadWAContacts() {
        var xhr = new XMLHttpRequest()
        xhr.open("GET", "http://127.0.0.1:" + backendPort + "/contacts")
        xhr.onreadystatechange = function() {
            if (xhr.readyState === 4 && xhr.status === 200) {
                var data = JSON.parse(xhr.responseText) || {}
                var list = []
                for (var jid in data) {
                    list.push({ jid: jid, name: data[jid] })
                }
                list.sort(function(a, b) { return a.name.localeCompare(b.name) })
                waContacts = list
                waContactsMap = data
            }
        }
        xhr.send()
    }

    function doLogout() {
        var xhr = new XMLHttpRequest()
        xhr.open("GET", "http://127.0.0.1:" + backendPort + "/logout")
        xhr.onreadystatechange = function() {
            if (xhr.readyState === 4) {
                connected = false
                pairCode = ""
                phone = ""
                chats = []
                waContacts = []
            }
        }
        xhr.send()
    }

    function formatTime(ts) {
        if (!ts) return ""
        var d = new Date(ts * 1000)
        var now = new Date()
        if (d.toDateString() === now.toDateString()) {
            return d.getHours() + ":" + (d.getMinutes() < 10 ? "0" : "") + d.getMinutes()
        }
        return d.getDate() + "." + (d.getMonth()+1)
    }

    function formatSize(bytes) {
        if (!bytes) return ""
        if (bytes < 1024) return bytes + " B"
        if (bytes < 1024*1024) return (bytes/1024).toFixed(1) + " KB"
        return (bytes/1024/1024).toFixed(1) + " MB"
    }

    Timer {
        interval: 5000
        running: connected
        repeat: true
        onTriggered: loadChats()
    }

    Timer {
        interval: 3000
        running: !connected
        repeat: true
        onTriggered: checkStatus()
    }


    // Avatar component
    Component {
        id: avatarComponent
        Item {
            property string jid: ""
            property string name: ""
            property bool isGroup: false
            
            Rectangle {
                id: avatarBg
                anchors.fill: parent
                radius: width/2
                color: isGroup ? "#25D366" : Theme.rgba(Theme.primaryColor, 0.2)
                visible: avatarImage.status !== Image.Ready
                
                Label {
                    anchors.centerIn: parent
                    text: isGroup ? "G" : (name ? name.charAt(0).toUpperCase() : "+")
                    font.pixelSize: parent.width * 0.5
                    color: isGroup ? "white" : Theme.highlightColor
                }
            }
            
            Image {
                id: avatarImage
                anchors.fill: parent
                fillMode: Image.PreserveAspectCrop
                source: jid ? "http://127.0.0.1:" + backendPort + "/avatar/" + jid : ""
                visible: status === Image.Ready
                
                layer.enabled: true
                layer.effect: ShaderEffect {
                    property real radius: 0.5
                    fragmentShader: "
                        uniform sampler2D source;
                        uniform lowp float qt_Opacity;
                        varying highp vec2 qt_TexCoord0;
                        void main() {
                            highp vec2 uv = qt_TexCoord0 - vec2(0.5);
                            if (length(uv) > 0.5) discard;
                            gl_FragColor = texture2D(source, qt_TexCoord0) * qt_Opacity;
                        }
                    "
                }
            }
        }
    }

    Page {
        id: mainPage

        // Status-Seite als attached page: Sailfish zeigt den Glow-Indikator
        // oben rechts, Wisch von rechts nach links oeffnet sie.
        // Erst anhaengen, wenn die Verbindung steht - vorher gehoert der
        // Platz dem Pairing-/Verbindungszustand.
        function updateAttachedStatus() {
            if (status === PageStatus.Active && connected) {
                pageStack.pushAttached(statusPage)
            }
        }
        onStatusChanged: updateAttachedStatus()

        SilicaListView {
            anchors.fill: parent
            model: connected ? chats : null

            PullDownMenu {
                MenuItem {
                    text: "Logout"
                    visible: connected
                    onClicked: logoutRemorse.execute("Logging out", doLogout, 15000)
                }
                MenuItem {
                    text: "Reload"
                    visible: connected
                    onClicked: {
                        var xhr = new XMLHttpRequest()
                        xhr.open("GET", "http://127.0.0.1:" + backendPort + "/reload")
                        xhr.onreadystatechange = function() {
                            if (xhr.readyState === 4) {
                                loadWAContacts()
                                loadChats()
                            }
                        }
                        xhr.send()
                    }
                }
                MenuItem {
                    text: "Settings"
                    onClicked: pageStack.push(settingsPage)
                }
                MenuItem {
                    text: "Profile"
                    visible: connected
                    onClicked: pageStack.push(profilePage)
                }
                MenuItem {
                    text: "Search"
                    visible: connected
                    onClicked: pageStack.push(searchPage)
                }
                MenuItem {
                    text: "Channels"
                    visible: connected
                    onClicked: pageStack.push(channelsPage)
                }
                MenuItem {
                    text: "Join via link"
                    visible: connected
                    onClicked: pageStack.push(joinLinkPage)
                }
                MenuItem {
                    text: "New group"
                    visible: connected
                    onClicked: pageStack.push(newGroupPage)
                }
                MenuItem {
                    text: "New chat"
                    visible: connected
                    onClicked: pageStack.push(newChatPage)
                }
            }

            RemorsePopup { id: logoutRemorse }

            header: Column {
                width: parent.width

                PageHeader { 
                    title: "WhatsApp"
                    description: {
                        if (connected) return "+" + phone
                        switch (connState) {
                        case "starting":         return "Starting backend\u2026"
                        case "connecting":       return "Connecting\u2026"
                        case "reconnecting":     return "Reconnecting\u2026"
                        case "waiting_for_pair": return "Not paired \u2013 enter phone number below"
                        case "logged_out":       return "Logged out \u2013 pair again"
                        case "relogin_required": return "Action required \u2013 see below"
                        case "secrets_error":    return "Sailfish Secrets problem \u2013 see below"
                        case "error":            return lastError !== "" ? lastError : "Connection error"
                        default:                 return "Not connected"
                        }
                    }
                }

                // Verbunden wird gerade (Verknuepfung existiert): nur Spinner
                BusyIndicator {
                    running: !connected && paired
                    visible: running
                    size: BusyIndicatorSize.Medium
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                Button {
                    text: "Retry connection"
                    visible: backendFailed
                    anchors.horizontalCenter: parent.horizontalCenter
                    onClicked: retryBackend()
                }

                Label {
                    visible: connState === "relogin_required" || connState === "secrets_error"
                    x: Theme.horizontalPageMargin
                    width: parent.width - 2*x
                    text: lastError
                    wrapMode: Text.Wrap
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.highlightColor
                }

                Button {
                    text: "Reset & pair again"
                    visible: connState === "relogin_required"
                    anchors.horizontalCenter: parent.horizontalCenter
                    onClicked: resetRemorse.execute("Deleting local database", function() {
                        var xhr = new XMLHttpRequest()
                        xhr.open("GET", "http://127.0.0.1:" + backendPort + "/reset")
                        xhr.onreadystatechange = function() {
                            if (xhr.readyState === 4) {
                                connState = "starting"
                                lastError = ""
                                paired = false
                                restartTimer.start()
                            }
                        }
                        xhr.send()
                    })
                }

                RemorsePopup { id: resetRemorse }

                Timer {
                    id: restartTimer
                    interval: 1200
                    repeat: false
                    onTriggered: retryBackend()
                }

                Label {
                    visible: globalNotice !== ""
                    x: Theme.horizontalPageMargin
                    width: parent.width - 2*x
                    text: globalNotice
                    wrapMode: Text.Wrap
                    font.pixelSize: Theme.fontSizeSmall
                    color: globalNotice.indexOf("failed") >= 0 ? Theme.errorColor : Theme.highlightColor
                }

                Column {
                    visible: !connected && !paired
                             && connState !== "relogin_required"
                             && connState !== "secrets_error"
                             && connState !== "starting"
                    width: parent.width
                    spacing: Theme.paddingLarge

                    TextField {
                        id: phoneField
                        width: parent.width
                        label: "Phone number (with country code)"
                        placeholderText: "43664..."
                        text: ""
                        inputMethodHints: Qt.ImhDigitsOnly
                    }

                    Label {
                        visible: pairErrorMsg !== ""
                        width: parent.width - 2*Theme.horizontalPageMargin
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: pairErrorMsg
                        wrapMode: Text.Wrap
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.errorColor
                    }

                    Button {
                        text: "Start pairing"
                        anchors.horizontalCenter: parent.horizontalCenter
                        onClicked: {
                            var xhr = new XMLHttpRequest()
                            var normalizedPhone = phoneField.text.replace(/[^0-9]/g, "").replace(/^00/, "")
                            xhr.open("GET", "http://127.0.0.1:" + backendPort + "/pair?phone=" + normalizedPhone)
                            xhr.onreadystatechange = function() {
                                if (xhr.readyState === 4) {
                                    if (xhr.status === 200) {
                                        pairErrorMsg = ""
                                        pairCode = JSON.parse(xhr.responseText).code
                                    } else {
                                        pairCode = ""
                                        pairErrorMsg = xhr.status === 0
                                            ? "Backend is restarting - please try again in a few seconds"
                                            : (xhr.status === 503
                                               ? "Backend is still starting - please try again in a moment"
                                               : "Pairing failed (" + xhr.status + "): " + xhr.responseText)
                                    }
                                }
                            }
                            xhr.send()
                        }
                    }

                    BackgroundItem {
                        visible: pairCode !== ""
                        width: parent.width
                        height: codeColumn.height + Theme.paddingLarge * 2
                        
                        onClicked: {
                            Clipboard.text = pairCode
                            copiedNotice.opacity = 1
                            copiedTimer.restart()
                        }

                        Column {
                            id: codeColumn
                            width: parent.width
                            anchors.centerIn: parent
                            spacing: Theme.paddingSmall

                            Label {
                                width: parent.width
                                text: pairCode
                                font.pixelSize: Theme.fontSizeHuge
                                font.bold: true
                                font.letterSpacing: 8
                                horizontalAlignment: Text.AlignHCenter
                                color: Theme.highlightColor
                            }

                            Label {
                                id: copiedNotice
                                width: parent.width
                                text: "✓ Copied to clipboard"
                                font.pixelSize: Theme.fontSizeSmall
                                horizontalAlignment: Text.AlignHCenter
                                color: Theme.highlightColor
                                opacity: 0
                                Behavior on opacity { FadeAnimation { duration: 200 } }
                            }

                            Timer {
                                id: copiedTimer
                                interval: 2000
                                onTriggered: copiedNotice.opacity = 0
                            }

                            Label {
                                width: parent.width
                                text: "Tap code to copy"
                                font.pixelSize: Theme.fontSizeExtraSmall
                                horizontalAlignment: Text.AlignHCenter
                                color: Theme.secondaryColor
                                opacity: copiedNotice.opacity > 0 ? 0 : 1
                            }
                        }
                    }

                    Label {
                        visible: pairCode !== ""
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*x
                        wrapMode: Text.Wrap
                        horizontalAlignment: Text.AlignHCenter
                        text: "Open WhatsApp on your phone:\nSettings → Linked Devices → Link a Device\n→ Link with phone number instead"
                        color: Theme.secondaryColor
                        font.pixelSize: Theme.fontSizeSmall
                    }
                }
            }

            delegate: ListItem {
                contentHeight: Theme.itemSizeMedium
                onClicked: pageStack.push(chatPage, { 
                    chatJid: modelData.jid, 
                    chatName: getDisplayName(modelData.jid, modelData.name),
                    chatAvatar: modelData.avatar || "",
                    isChannel: modelData.isChannel === true
                })

                function chatSetting(action) {
                    var xhr = new XMLHttpRequest()
                    xhr.open("GET", "http://127.0.0.1:" + backendPort + "/chatsetting?chat=" + modelData.jid + "&action=" + action)
                    xhr.onreadystatechange = function() {
                        if (xhr.readyState === 4) loadChats()
                    }
                    xhr.send()
                }

                menu: ContextMenu {
                    MenuItem {
                        text: modelData.pinned ? "Unpin" : "Pin"
                        visible: modelData.jid !== "status"
                        onClicked: chatSetting(modelData.pinned ? "unpin" : "pin")
                    }
                    MenuItem {
                        text: modelData.muted ? "Unmute" : "Mute"
                        visible: modelData.jid !== "status"
                        onClicked: chatSetting(modelData.muted ? "unmute" : "mute")
                    }
                    MenuItem {
                        text: modelData.archived ? "Unarchive" : "Archive"
                        visible: modelData.jid !== "status"
                        onClicked: chatSetting(modelData.archived ? "unarchive" : "archive")
                    }
                }

                Row {
                    x: Theme.horizontalPageMargin
                    width: parent.width - 2*x
                    height: parent.height
                    spacing: Theme.paddingMedium

                    Loader {
                        sourceComponent: avatarComponent
                        width: Theme.itemSizeSmall
                        height: width
                        anchors.verticalCenter: parent.verticalCenter
                        onLoaded: {
                            item.jid = modelData.jid
                            item.name = modelData.name
                            item.isGroup = modelData.isGroup
                        }
                    }

                    Column {
                        width: parent.width - Theme.itemSizeSmall - timeLabel.width - Theme.paddingMedium * 2
                        anchors.verticalCenter: parent.verticalCenter
                        
                        Label {
                            text: (modelData.pinned ? "📌 " : "")
                                  + getDisplayName(modelData.jid, modelData.name)
                                  + (modelData.muted ? " 🔇" : "")
                                  + (modelData.archived ? " · archived" : "")
                            font.pixelSize: Theme.fontSizeMedium
                            truncationMode: TruncationMode.Fade
                            width: parent.width
                            opacity: modelData.archived ? Theme.opacityLow : 1.0
                        }
                        Label {
                            // keep this strictly single-line: multi-line last
                            // messages used to overflow the fixed-height list
                            // item and paint over the next chat entry
                            text: modelData.lastMessage ? ((modelData.fromMe ? "You: " : "") + modelData.lastMessage.replace(/\n/g, " ")) : ""
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.secondaryColor
                            truncationMode: TruncationMode.Fade
                            maximumLineCount: 1
                            width: parent.width
                        }
                    }

                    Label {
                        id: timeLabel
                        text: formatTime(modelData.lastTime)
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.secondaryColor
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }

            ViewPlaceholder {
                enabled: connected && chats.length === 0
                text: "No chats"
                hintText: "Pull down to start a new chat"
            }
        }
    }

    Component {
        id: profilePhotoPicker
        ImagePickerPage {
            onSelectedContentPropertiesChanged: {
                var xhr = new XMLHttpRequest()
                xhr.open("GET", "http://127.0.0.1:" + backendPort + "/setphoto?file="
                         + encodeURIComponent(selectedContentProperties.filePath))
                xhr.onreadystatechange = function() {
                    if (xhr.readyState === 4) {
                        profileStatus = xhr.status === 200 ? "Photo updated"
                                       : "Photo failed: " + xhr.responseText
                    }
                }
                xhr.send()
            }
        }
    }

    Component {
        id: settingsPage
        Page {
            property var downloadPrefs: ({})
            property var storageInfo: ({})

            function loadStorage() {
                var xhr = new XMLHttpRequest()
                xhr.open("GET", "http://127.0.0.1:" + backendPort + "/storage")
                xhr.onreadystatechange = function() {
                    if (xhr.readyState === 4 && xhr.status === 200) {
                        storageInfo = JSON.parse(xhr.responseText) || {}
                    }
                }
                xhr.send()
            }

            Component.onCompleted: {
                loadStorage()
                var xhr = new XMLHttpRequest()
                xhr.open("GET", "http://127.0.0.1:" + backendPort + "/prefs")
                xhr.onreadystatechange = function() {
                    if (xhr.readyState === 4 && xhr.status === 200) {
                        downloadPrefs = JSON.parse(xhr.responseText) || {}
                    }
                }
                xhr.send()
            }

            SilicaFlickable {
                anchors.fill: parent
                contentHeight: setCol.height

                Column {
                    id: setCol
                    width: parent.width
                    spacing: Theme.paddingMedium

                    PageHeader { title: "Settings" }

                    TextSwitch {
                        text: "Address book suggestions"
                        description: "Show contacts from your Sailfish address book "
                                   + "on the New chat page and in group creation. "
                                   + "When disabled, the app never reads the contact database."
                        checked: contactsOptIn
                        automaticCheck: false
                        onClicked: {
                            contactsOptIn = !contactsOptIn
                            setPref("contactSuggestions", contactsOptIn ? "1" : "0")
                        }
                    }

                    SectionHeader { text: "Automatic downloads" }

                    Label {
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*x
                        text: "Applies to incoming messages. Tapping a placeholder always downloads, regardless of these settings."
                        font.pixelSize: Theme.fontSizeExtraSmall
                        color: Theme.secondaryColor
                        wrapMode: Text.Wrap
                    }

                    Repeater {
                        model: [
                            { key: "image",    label: "Images",           def: "always" },
                            { key: "sticker",  label: "Stickers",         def: "always" },
                            { key: "video",    label: "Videos",           def: "wifi" },
                            { key: "audio",    label: "Audio",            def: "wifi" },
                            { key: "document", label: "Documents",        def: "wifi" },
                            { key: "avatar",   label: "Profile pictures", def: "always" }
                        ]
                        ComboBox {
                            width: setCol.width
                            label: modelData.label
                            property string prefKey: "autodl_" + modelData.key
                            currentIndex: {
                                var v = downloadPrefs[prefKey] || modelData.def
                                return v === "always" ? 0 : (v === "wifi" ? 1 : 2)
                            }
                            menu: ContextMenu {
                                MenuItem { text: "Always" }
                                MenuItem { text: "Wi-Fi only" }
                                MenuItem { text: "Never" }
                            }
                            onCurrentIndexChanged: {
                                var v = currentIndex === 0 ? "always" : (currentIndex === 1 ? "wifi" : "never")
                                if (downloadPrefs[prefKey] !== v) {
                                    var p = downloadPrefs
                                    p[prefKey] = v
                                    downloadPrefs = p
                                    setPref(prefKey, v)
                                }
                            }
                        }
                    }

                    SectionHeader { text: "Storage" }

                    Repeater {
                        id: storageRepeater
                        model: [
                            { key: "images",    label: "Images & stickers" },
                            { key: "videos",    label: "Videos" },
                            { key: "audio",     label: "Audio" },
                            { key: "documents", label: "Documents" },
                            { key: "avatars",   label: "Profile pictures" }
                        ]
                        ListItem {
                            width: setCol.width
                            contentHeight: Theme.itemSizeSmall
                            menu: ContextMenu {
                                MenuItem {
                                    text: "Delete all " + modelData.label.toLowerCase()
                                    onClicked: remorseAction("Deleting " + modelData.label.toLowerCase(), function() {
                                        var xhr = new XMLHttpRequest()
                                        xhr.open("GET", "http://127.0.0.1:" + backendPort + "/storage/clear?type=" + modelData.key)
                                        xhr.onreadystatechange = function() {
                                            if (xhr.readyState === 4) loadStorage()
                                        }
                                        xhr.send()
                                    })
                                }
                            }
                            Label {
                                x: Theme.horizontalPageMargin
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.label
                            }
                            Label {
                                anchors.right: parent.right
                                anchors.rightMargin: Theme.horizontalPageMargin
                                anchors.verticalCenter: parent.verticalCenter
                                text: storageInfo[modelData.key]
                                      ? formatSize(storageInfo[modelData.key].bytes) + " (" + storageInfo[modelData.key].files + ")"
                                      : "…"
                                color: Theme.secondaryColor
                                font.pixelSize: Theme.fontSizeSmall
                            }
                        }
                    }

                    Label {
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*x
                        text: "Long-press a row to delete. Deleted chat media shows the download placeholder again and can be re-downloaded."
                        font.pixelSize: Theme.fontSizeExtraSmall
                        color: Theme.secondaryColor
                        wrapMode: Text.Wrap
                    }

                    SectionHeader { text: "Sailjail permissions" }

                    Label {
                        id: permStatus
                        property bool granted: false
                        property bool mediaGranted: false
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*x
                        text: "Contacts permission: " + (granted ? "granted" : "not granted")
                              + "\nMedia storage permission: " + (mediaGranted ? "granted" : "not granted")
                        color: Theme.highlightColor
                        font.pixelSize: Theme.fontSizeSmall
                        wrapMode: Text.Wrap

                        Component.onCompleted: {
                            var xhr = new XMLHttpRequest()
                            xhr.open("GET", "http://127.0.0.1:" + backendPort + "/permcheck")
                            xhr.onreadystatechange = function() {
                                if (xhr.readyState === 4 && xhr.status === 200) {
                                    var p = JSON.parse(xhr.responseText)
                                    granted = p.contactsPermission === true
                                    mediaGranted = p.mediaPermission === true
                                }
                            }
                            xhr.send()
                        }
                    }

                    Label {
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*x
                        text: "Sailfish OS has no runtime permission dialogs, and the app "
                            + "cannot edit its own desktop file from inside the sandbox. "
                            + "The app therefore ships with MINIMAL permissions (Internet, "
                            + "Secrets). Tap a command below to copy it, run it in Terminal, "
                            + "then restart the app. Updates will not overwrite your choice.\n\n"
                            + "Without media storage permission, received media is saved "
                            + "inside the app's private data folder (not visible in Gallery) "
                            + "and the image/file pickers will appear empty."
                        font.pixelSize: Theme.fontSizeExtraSmall
                        color: Theme.secondaryColor
                        wrapMode: Text.Wrap
                    }

                    BackgroundItem {
                        width: parent.width
                        height: grantLabel.height + 2*Theme.paddingMedium
                        onClicked: {
                            Clipboard.text = "devel-su sed -i '/^Permissions=/{s/;*$/;/; /Contacts;/!s/$/Contacts;/; /Privileged;/!s/$/Privileged;/}' /usr/share/applications/harbour-whatsapp.desktop"
                            copiedHint.text = "Grant command copied - paste in Terminal"
                        }
                        Label {
                            id: grantLabel
                            x: Theme.horizontalPageMargin
                            width: parent.width - 2*x
                            anchors.verticalCenter: parent.verticalCenter
                            text: "▸ Copy command to GRANT contacts permission"
                            color: Theme.highlightColor
                            font.pixelSize: Theme.fontSizeSmall
                        }
                    }

                    BackgroundItem {
                        width: parent.width
                        height: revokeLabel.height + 2*Theme.paddingMedium
                        onClicked: {
                            Clipboard.text = "devel-su sed -i '/^Permissions=/{s/Contacts;//g; s/Privileged;//g}' /usr/share/applications/harbour-whatsapp.desktop"
                            copiedHint.text = "Revoke command copied - paste in Terminal"
                        }
                        Label {
                            id: revokeLabel
                            x: Theme.horizontalPageMargin
                            width: parent.width - 2*x
                            anchors.verticalCenter: parent.verticalCenter
                            text: "▸ Copy command to REVOKE contacts permission"
                            color: Theme.secondaryHighlightColor
                            font.pixelSize: Theme.fontSizeSmall
                        }
                    }

                    BackgroundItem {
                        width: parent.width
                        height: grantMediaLabel.height + 2*Theme.paddingMedium
                        onClicked: {
                            Clipboard.text = "devel-su sed -i '/^Permissions=/{s/;*$/;/; /UserDirs;/!s/$/UserDirs;/; /MediaIndexing;/!s/$/MediaIndexing;/; /RemovableMedia;/!s/$/RemovableMedia;/}' /usr/share/applications/harbour-whatsapp.desktop"
                            copiedHint.text = "Media grant command copied - paste in Terminal"
                        }
                        Label {
                            id: grantMediaLabel
                            x: Theme.horizontalPageMargin
                            width: parent.width - 2*x
                            anchors.verticalCenter: parent.verticalCenter
                            text: "▸ Copy command to GRANT media storage permission"
                            color: Theme.highlightColor
                            font.pixelSize: Theme.fontSizeSmall
                        }
                    }

                    BackgroundItem {
                        width: parent.width
                        height: revokeMediaLabel.height + 2*Theme.paddingMedium
                        onClicked: {
                            Clipboard.text = "devel-su sed -i '/^Permissions=/{s/UserDirs;//g; s/MediaIndexing;//g; s/RemovableMedia;//g}' /usr/share/applications/harbour-whatsapp.desktop"
                            copiedHint.text = "Media revoke command copied - paste in Terminal"
                        }
                        Label {
                            id: revokeMediaLabel
                            x: Theme.horizontalPageMargin
                            width: parent.width - 2*x
                            anchors.verticalCenter: parent.verticalCenter
                            text: "▸ Copy command to REVOKE media storage permission"
                            color: Theme.secondaryHighlightColor
                            font.pixelSize: Theme.fontSizeSmall
                        }
                    }

                    BackgroundItem {
                        width: parent.width
                        height: grantLocLabel.height + 2*Theme.paddingMedium
                        onClicked: {
                            Clipboard.text = "devel-su sed -i '/^Permissions=/{s/;*$/;/; /Location;/!s/$/Location;/}' /usr/share/applications/harbour-whatsapp.desktop"
                            copiedHint.text = "Location grant command copied - paste in Terminal, then restart the app"
                        }
                        Label {
                            id: grantLocLabel
                            x: Theme.horizontalPageMargin
                            width: parent.width - 2*x
                            anchors.verticalCenter: parent.verticalCenter
                            text: "\u25b8 Copy command to GRANT location permission (for sending your position)"
                            color: Theme.highlightColor
                            font.pixelSize: Theme.fontSizeSmall
                        }
                    }

                    BackgroundItem {
                        width: parent.width
                        height: revokeLocLabel.height + 2*Theme.paddingMedium
                        onClicked: {
                            Clipboard.text = "devel-su sed -i '/^Permissions=/{s/Location;//g}' /usr/share/applications/harbour-whatsapp.desktop"
                            copiedHint.text = "Location revoke command copied - paste in Terminal"
                        }
                        Label {
                            id: revokeLocLabel
                            x: Theme.horizontalPageMargin
                            width: parent.width - 2*x
                            anchors.verticalCenter: parent.verticalCenter
                            text: "\u25b8 Copy command to REVOKE location permission"
                            color: Theme.secondaryHighlightColor
                            font.pixelSize: Theme.fontSizeSmall
                        }
                    }

                    Label {
                        id: copiedHint
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*x
                        text: ""
                        visible: text !== ""
                        color: Theme.highlightColor
                        font.pixelSize: Theme.fontSizeExtraSmall
                        wrapMode: Text.Wrap
                    }
                }
            }
        }
    }

    property string profileStatus: ""

    Component {
        id: profilePage
        Page {
            property bool loaded: false

            property string avatarPath: ""

            Component.onCompleted: {
                var xhr = new XMLHttpRequest()
                xhr.open("GET", "http://127.0.0.1:" + backendPort + "/profile")
                xhr.onreadystatechange = function() {
                    if (xhr.readyState === 4 && xhr.status === 200) {
                        var d = JSON.parse(xhr.responseText)
                        nameField.text = d.name || ""
                        aboutField.text = d.about || ""
                        avatarPath = d.avatar || ""
                        loaded = true
                    }
                }
                xhr.send()
                profileStatus = ""
            }

            SilicaFlickable {
                anchors.fill: parent
                contentHeight: profCol.height

                Column {
                    id: profCol
                    width: parent.width
                    spacing: Theme.paddingLarge

                    PageHeader { title: "Profile" }

                    Image {
                        visible: avatarPath !== ""
                        width: Theme.itemSizeExtraLarge * 1.5
                        height: width
                        anchors.horizontalCenter: parent.horizontalCenter
                        fillMode: Image.PreserveAspectCrop
                        cache: false
                        source: avatarPath !== "" ? "file://" + avatarPath : ""

                        BusyIndicator {
                            anchors.centerIn: parent
                            running: parent.status === Image.Loading
                        }
                    }

                    TextField {
                        id: nameField
                        width: parent.width
                        label: "Name"
                        placeholderText: "Your name"
                    }

                    TextField {
                        id: aboutField
                        width: parent.width
                        label: "About"
                        placeholderText: "Hey there! I am using WhatsApp."
                    }

                    Button {
                        text: "Save"
                        anchors.horizontalCenter: parent.horizontalCenter
                        enabled: loaded && nameField.text !== ""
                        onClicked: {
                            profileStatus = ""
                            var xhr = new XMLHttpRequest()
                            xhr.open("GET", "http://127.0.0.1:" + backendPort + "/setprofile?name="
                                     + encodeURIComponent(nameField.text)
                                     + "&hasAbout=1&about=" + encodeURIComponent(aboutField.text))
                            xhr.onreadystatechange = function() {
                                if (xhr.readyState === 4) {
                                    profileStatus = xhr.status === 200 ? "Profile saved"
                                                   : "Failed: " + xhr.responseText
                                }
                            }
                            xhr.send()
                        }
                    }

                    Button {
                        text: "Change profile photo"
                        anchors.horizontalCenter: parent.horizontalCenter
                        onClicked: pageStack.push(profilePhotoPicker)
                    }

                    Label {
                        visible: profileStatus !== ""
                        text: profileStatus
                        anchors.horizontalCenter: parent.horizontalCenter
                        color: profileStatus.indexOf("Failed") === 0 || profileStatus.indexOf("Photo failed") === 0
                               ? Theme.errorColor : Theme.highlightColor
                    }

                    Label {
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*x
                        text: "Name and photo are visible to your contacts. Changes may take a moment to propagate."
                        font.pixelSize: Theme.fontSizeExtraSmall
                        color: Theme.secondaryColor
                        wrapMode: Text.Wrap
                    }
                }
            }
        }
    }

    Component {
        id: createPollPage
        Dialog {
            id: cpDialog
            property string targetChat: ""
            property var optionTexts: ["", ""]
            canAccept: {
                if (cpName.text.trim() === "") return false
                var filled = 0
                for (var i = 0; i < optionTexts.length; i++) {
                    if (optionTexts[i].trim() !== "") filled++
                }
                return filled >= 2
            }

            onAccepted: {
                var opts = []
                for (var i = 0; i < optionTexts.length; i++) {
                    if (optionTexts[i].trim() !== "") opts.push(optionTexts[i].trim())
                }
                var xhr = new XMLHttpRequest()
                xhr.open("GET", "http://127.0.0.1:" + backendPort + "/poll/create?chat=" + targetChat
                         + "&name=" + encodeURIComponent(cpName.text.trim())
                         + "&options=" + encodeURIComponent(opts.join("||"))
                         + "&multiple=" + (cpMulti.checked ? "1" : "0"))
                xhr.onreadystatechange = function() {
                    if (xhr.readyState === 4 && xhr.status !== 200) {
                        globalNotice = "Poll creation failed: " + xhr.responseText
                    }
                }
                xhr.send()
            }

            SilicaFlickable {
                anchors.fill: parent
                contentHeight: cpCol.height

                Column {
                    id: cpCol
                    width: parent.width

                    DialogHeader { title: "Create poll" }

                    TextField {
                        id: cpName
                        width: parent.width
                        label: "Question"
                        placeholderText: "Ask something…"
                    }

                    Repeater {
                        model: cpDialog.optionTexts.length
                        TextField {
                            width: cpCol.width
                            label: "Option " + (index + 1)
                            placeholderText: "Option " + (index + 1)
                            text: cpDialog.optionTexts[index]
                            onTextChanged: {
                                var a = cpDialog.optionTexts
                                if (a[index] !== text) {
                                    a[index] = text
                                    cpDialog.optionTexts = a
                                }
                            }
                        }
                    }

                    Button {
                        text: "Add option"
                        anchors.horizontalCenter: parent.horizontalCenter
                        enabled: cpDialog.optionTexts.length < 12
                        onClicked: {
                            var a = cpDialog.optionTexts
                            a.push("")
                            cpDialog.optionTexts = a
                        }
                    }

                    TextSwitch {
                        id: cpMulti
                        text: "Allow multiple answers"
                    }
                }
            }
        }
    }

    Component {
        id: addParticipantsPage
        Dialog {
            id: apDialog
            property string groupJid: ""
            property var existingNumbers: ({})
            property var onDone: null
            property var selected: ({})
            property string apSearch: ""
            canAccept: selectedCount() > 0

            function selectedCount() {
                var n = 0
                for (var k in selected) if (selected[k]) n++
                return n
            }

            function candidates() {
                var all = mergedContacts()
                var q = apSearch.toLowerCase()
                var result = []
                for (var i = 0; i < all.length; i++) {
                    var c = all[i]
                    if (existingNumbers[c.jid]) continue   // schon in der Gruppe
                    if (apSearch !== ""
                        && c.name.toLowerCase().indexOf(q) < 0
                        && c.jid.indexOf(q) < 0) continue
                    result.push(c)
                }
                return result
            }

            onAccepted: {
                var nums = []
                for (var k in selected) if (selected[k]) nums.push(k)
                if (nums.length === 0) return
                var xhr = new XMLHttpRequest()
                xhr.open("GET", "http://127.0.0.1:" + backendPort + "/group/participants?chat="
                         + groupJid + "&action=add&numbers=" + nums.join(","))
                xhr.onreadystatechange = function() {
                    if (xhr.readyState === 4) {
                        if (xhr.status !== 200) globalNotice = "Add failed: " + xhr.responseText
                        if (onDone) onDone()
                    }
                }
                xhr.send()
            }

            Column {
                id: apHeader
                width: parent.width
                DialogHeader { title: "Add participants" }
                SearchField {
                    id: apSearchField
                    width: parent.width
                    placeholderText: "Search contacts"
                    onTextChanged: apDialog.apSearch = text
                }
                SectionHeader {
                    text: apDialog.selectedCount() > 0
                          ? "Selected: " + apDialog.selectedCount()
                          : "Tap to select"
                }
            }

            SilicaListView {
                anchors.top: apHeader.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                clip: true
                model: apDialog.candidates()

                delegate: TextSwitch {
                    text: modelData.name || ("+" + modelData.jid)
                    description: "+" + modelData.jid
                    checked: apDialog.selected[modelData.jid] === true
                    automaticCheck: false
                    onClicked: {
                        var sel = apDialog.selected
                        sel[modelData.jid] = !sel[modelData.jid]
                        apDialog.selected = sel
                        checked = sel[modelData.jid]
                    }
                }

                ViewPlaceholder {
                    enabled: apDialog.candidates().length === 0
                    text: contactsOptIn ? "No contacts" : "Address book suggestions are off"
                    hintText: contactsOptIn ? "" : "Enable them in Settings, or use the number field"
                }
            }
        }
    }

    Component {
        id: groupPhotoPicker
        ImagePickerPage {
            property string groupJid: ""
            onSelectedContentPropertiesChanged: {
                var xhr = new XMLHttpRequest()
                xhr.open("GET", "http://127.0.0.1:" + backendPort + "/group/photo?chat=" + groupJid
                         + "&file=" + encodeURIComponent(selectedContentProperties.filePath))
                xhr.send()
            }
        }
    }

    Component {
        id: groupInfoPage
        Page {
            id: giPage
            property string groupJid: ""
            property string groupName: ""
            property var participants: []
            property string inviteLink: ""
            property string giStatus: ""
            property var subgroups: []

            function loadInfo() {
                var xhr = new XMLHttpRequest()
                xhr.open("GET", "http://127.0.0.1:" + backendPort + "/group/info?chat=" + groupJid)
                xhr.onreadystatechange = function() {
                    if (xhr.readyState === 4 && xhr.status === 200) {
                        var d = JSON.parse(xhr.responseText)
                        groupName = d.name || ""
                        participants = d.participants || []
                        gnameField.text = groupName
                    } else if (xhr.readyState === 4) {
                        giStatus = xhr.responseText
                    }
                }
                xhr.send()
            }

            function groupCall(params, cb) {
                var xhr = new XMLHttpRequest()
                xhr.open("GET", "http://127.0.0.1:" + backendPort + params)
                xhr.onreadystatechange = function() {
                    if (xhr.readyState === 4) {
                        giStatus = xhr.status === 200 ? "OK" : xhr.responseText
                        if (cb) cb(xhr)
                        loadInfo()
                    }
                }
                xhr.send()
            }

            Component.onCompleted: {
                loadInfo()
                var xhr = new XMLHttpRequest()
                xhr.open("GET", "http://127.0.0.1:" + backendPort + "/group/subgroups?chat=" + groupJid)
                xhr.onreadystatechange = function() {
                    if (xhr.readyState === 4 && xhr.status === 200) {
                        subgroups = JSON.parse(xhr.responseText) || []
                    }
                }
                xhr.send()
            }

            SilicaFlickable {
                anchors.fill: parent
                contentHeight: giCol.height

                PullDownMenu {
                    MenuItem {
                        text: "Leave group"
                        onClicked: leaveRemorse.execute("Leaving group", function() {
                            groupCall("/group/leave?chat=" + groupJid, function() { pageStack.pop(pageStack.previousPage()) })
                        })
                    }
                    MenuItem {
                        text: "Change group photo"
                        onClicked: pageStack.push(groupPhotoPicker, { groupJid: groupJid })
                    }
                    MenuItem {
                        text: "Get invite link"
                        onClicked: groupCall("/group/invitelink?chat=" + groupJid, function(xhr) {
                            if (xhr.status === 200) {
                                inviteLink = JSON.parse(xhr.responseText).link
                                Clipboard.text = inviteLink
                                giStatus = "Invite link copied to clipboard"
                            }
                        })
                    }
                    MenuItem {
                        text: "Join requests"
                        onClicked: pageStack.push(joinRequestsPage, { groupJid: groupJid })
                    }
                    MenuItem {
                        text: "Set description\u2026"
                        onClicked: {
                            var dlg = pageStack.push(groupDescDialog)
                            dlg.accepted.connect(function() {
                                groupCall("/group/desc?jid=" + groupJid + "&text=" + encodeURIComponent(dlg.descText))
                            })
                        }
                    }
                }

                RemorsePopup { id: leaveRemorse }

                Column {
                    id: giCol
                    width: parent.width
                    spacing: Theme.paddingMedium

                    PageHeader { title: groupName || "Group info" }

                    Row {
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*x
                        spacing: Theme.paddingMedium

                        TextField {
                            id: gnameField
                            width: parent.width - renameBtn.width - Theme.paddingMedium
                            label: "Group name"
                        }
                        IconButton {
                            id: renameBtn
                            icon.source: "image://theme/icon-m-accept"
                            anchors.verticalCenter: parent.verticalCenter
                            enabled: gnameField.text !== "" && gnameField.text !== groupName
                            onClicked: groupCall("/group/rename?chat=" + groupJid + "&name=" + encodeURIComponent(gnameField.text))
                        }
                    }

                    Label {
                        visible: inviteLink !== ""
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*x
                        text: inviteLink
                        font.pixelSize: Theme.fontSizeExtraSmall
                        color: Theme.highlightColor
                        wrapMode: Text.WrapAnywhere
                    }

                    Label {
                        visible: giStatus !== "" && giStatus !== "OK"
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*x
                        text: giStatus
                        font.pixelSize: Theme.fontSizeExtraSmall
                        color: Theme.secondaryHighlightColor
                        wrapMode: Text.Wrap
                    }

                    Row {
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*x
                        spacing: Theme.paddingMedium

                        TextField {
                            id: addField
                            width: parent.width - addBtn.width - Theme.paddingMedium
                            label: "Add participant"
                            placeholderText: "436641234567"
                            inputMethodHints: Qt.ImhDigitsOnly
                        }
                        IconButton {
                            id: addBtn
                            icon.source: "image://theme/icon-m-add"
                            anchors.verticalCenter: parent.verticalCenter
                            enabled: addField.text.length > 6
                            onClicked: {
                                groupCall("/group/participants?chat=" + groupJid + "&action=add&numbers=" + addField.text)
                                addField.text = ""
                            }
                        }
                    }

                    Button {
                        text: "Add from contacts"
                        anchors.horizontalCenter: parent.horizontalCenter
                        onClicked: {
                            var existing = {}
                            for (var i = 0; i < participants.length; i++) {
                                existing[participants[i].number] = true
                            }
                            pageStack.push(addParticipantsPage, {
                                groupJid: giPage.groupJid,
                                existingNumbers: existing,
                                onDone: function() { loadInfo() }
                            })
                        }
                    }

                    SectionHeader {
                        visible: subgroups.length > 0
                        text: "Community groups (" + subgroups.length + ")"
                    }

                    Repeater {
                        model: subgroups
                        ListItem {
                            width: giCol.width
                            contentHeight: Theme.itemSizeSmall
                            onClicked: pageStack.replace(chatPage, { chatJid: modelData.jid, chatName: modelData.name })
                            Label {
                                x: Theme.horizontalPageMargin
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.name
                                color: Theme.highlightColor
                            }
                        }
                    }

                    SectionHeader { text: "Participants (" + participants.length + ")" }

                    Repeater {
                        model: participants
                        ListItem {
                            width: giCol.width
                            contentHeight: Theme.itemSizeMedium
                            menu: ContextMenu {
                                MenuItem {
                                    text: "Call +" + modelData.number
                                    onClicked: Qt.openUrlExternally("tel:+" + modelData.number)
                                }
                                MenuItem {
                                    text: modelData.isAdmin ? "Remove admin rights" : "Make admin"
                                    onClicked: groupCall("/group/participants?chat=" + giPage.groupJid
                                               + "&action=" + (modelData.isAdmin ? "demote" : "promote")
                                               + "&numbers=" + modelData.number)
                                }
                                MenuItem {
                                    text: "Remove from group"
                                    onClicked: groupCall("/group/participants?chat=" + giPage.groupJid + "&action=remove&numbers=" + modelData.number)
                                }
                            }
                            Column {
                                x: Theme.horizontalPageMargin
                                anchors.verticalCenter: parent.verticalCenter
                                Label {
                                    text: (getDisplayName(modelData.number, modelData.name))
                                          + (modelData.isAdmin ? " · admin" : "")
                                }
                                Label {
                                    text: "+" + modelData.number
                                    font.pixelSize: Theme.fontSizeExtraSmall
                                    color: Theme.secondaryColor
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    Component {
        id: statusPostDialog
        Dialog {
            property string statusText: textArea.text
            property string statusBg: bgRepeater.model[bgRow.selected]
            canAccept: textArea.text.trim().length > 0
            Column {
                width: parent.width
                DialogHeader { title: "Post status" }
                TextArea {
                    id: textArea
                    width: parent.width
                    placeholderText: "Your status update\u2026"
                    label: "Visible according to your WhatsApp status privacy"
                }
                Label {
                    x: Theme.horizontalPageMargin
                    text: "Background"
                    color: Theme.secondaryHighlightColor
                    font.pixelSize: Theme.fontSizeSmall
                }
                Row {
                    id: bgRow
                    property int selected: 0
                    x: Theme.horizontalPageMargin
                    spacing: Theme.paddingMedium
                    Repeater {
                        id: bgRepeater
                        // AARRGGBB, an WhatsApps Text-Status-Palette angelehnt
                        model: ["FF075E54", "FF128C7E", "FF3949AB", "FF8E24AA",
                                "FFD81B60", "FFE65100", "FF546E7A", "FF212121"]
                        Rectangle {
                            width: Theme.itemSizeExtraSmall
                            height: Theme.itemSizeExtraSmall
                            radius: width / 2
                            color: "#" + modelData.substring(2)
                            border.width: bgRow.selected === index ? 4 : 0
                            border.color: Theme.highlightColor
                            MouseArea { anchors.fill: parent; onClicked: bgRow.selected = index }
                        }
                    }
                }
                Item { width: 1; height: Theme.paddingLarge }
            }
        }
    }

    Component {
        id: statusPage
        Page {
            id: stPage
            property var statuses: []
            property string downloadingId: ""

            function loadStatuses() {
                var xhr = new XMLHttpRequest()
                xhr.open("GET", "http://127.0.0.1:" + backendPort + "/messages?jid=status")
                xhr.onreadystatechange = function() {
                    if (xhr.readyState === 4 && xhr.status === 200) {
                        var list = JSON.parse(xhr.responseText) || []
                        list = list.filter(function(m) { return !m.revoked })
                        list.sort(function(a, b) { return b.timestamp - a.timestamp })
                        statuses = list
                    }
                }
                xhr.send()
            }

            function downloadStatus(msgId) {
                downloadingId = msgId
                var xhr = new XMLHttpRequest()
                xhr.open("GET", "http://127.0.0.1:" + backendPort + "/download?id=" + encodeURIComponent(msgId))
                xhr.onreadystatechange = function() {
                    if (xhr.readyState === 4) {
                        downloadingId = ""
                        loadStatuses()
                    }
                }
                xhr.send()
            }

            RemorsePopup { id: deleteRemorse }

            function sendStatusMedia(path, caption) {
                var xhr = new XMLHttpRequest()
                xhr.open("POST", "http://127.0.0.1:" + backendPort
                         + "/sendmedia?to=status&file=" + encodeURIComponent(path)
                         + "&caption=" + encodeURIComponent(caption || ""))
                xhr.onreadystatechange = function() {
                    if (xhr.readyState === 4) loadStatuses()
                }
                xhr.send()
            }

            Component {
                id: statusMediaPicker
                ContentPickerPage {
                    title: "Select image or video"
                    onSelectedContentPropertiesChanged: {
                        // Erst Caption abfragen, dann posten - wie bei WhatsApp
                        var dlg = pageStack.push(statusCaptionDialog,
                                                 { mediaPath: selectedContentProperties.filePath })
                        dlg.accepted.connect(function() {
                            stPage.sendStatusMedia(dlg.mediaPath, dlg.captionText)
                        })
                    }
                }
            }

            Component {
                id: statusCaptionDialog
                Dialog {
                    property string mediaPath: ""
                    property string captionText: captionArea.text
                    canAccept: true // Caption ist optional
                    Column {
                        width: parent.width
                        DialogHeader {
                            title: "Post to status"
                            acceptText: "Post"
                        }
                        Image {
                            x: Theme.horizontalPageMargin
                            width: parent.width - 2*Theme.horizontalPageMargin
                            height: Math.min(width * 0.6, Screen.height * 0.3)
                            source: mediaPath
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                        }
                        TextArea {
                            id: captionArea
                            width: parent.width
                            placeholderText: "Add a caption\u2026 (optional)"
                            label: "Caption"
                        }
                    }
                }
            }

            onStatusChanged: if (status === PageStatus.Active) loadStatuses()
            Component.onCompleted: loadStatuses()

            SilicaListView {
                anchors.fill: parent
                model: statuses

                PullDownMenu {
                    MenuItem { text: "Refresh"; onClicked: loadStatuses() }
                    MenuItem {
                        text: "Post image or video"
                        onClicked: pageStack.push(statusMediaPicker)
                    }
                    MenuItem {
                        text: "Post status"
                        onClicked: {
                            var dlg = pageStack.push(statusPostDialog)
                            dlg.accepted.connect(function() {
                                var xhr = new XMLHttpRequest()
                                xhr.open("GET", "http://127.0.0.1:" + backendPort
                                         + "/status/post?text=" + encodeURIComponent(dlg.statusText)
                                         + "&bg=" + dlg.statusBg)
                                xhr.onreadystatechange = function() {
                                    if (xhr.readyState === 4) loadStatuses()
                                }
                                xhr.send()
                            })
                        }
                    }
                }

                header: PageHeader { title: "Status updates" }

                delegate: Column {
                    width: parent.width
                    spacing: Theme.paddingSmall

                    Item { width: 1; height: Theme.paddingMedium }

                    Row {
                        x: Theme.horizontalPageMargin
                        spacing: Theme.paddingMedium
                        Label {
                            text: getDisplayName(modelData.sender, "")
                            color: Theme.highlightColor
                            font.bold: true
                        }
                        Label {
                            text: formatTime(modelData.timestamp)
                            color: Theme.secondaryColor
                            font.pixelSize: Theme.fontSizeExtraSmall
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        IconButton {
                            visible: modelData.fromMe === true
                            icon.source: "image://theme/icon-s-clear-opaque-cross"
                            width: Theme.itemSizeExtraSmall * 0.7
                            height: width
                            anchors.verticalCenter: parent.verticalCenter
                            onClicked: deleteRemorse.execute("Deleting status", function() {
                                var xhr = new XMLHttpRequest()
                                xhr.open("GET", "http://127.0.0.1:" + backendPort
                                         + "/status/delete?id=" + encodeURIComponent(modelData.id))
                                xhr.onreadystatechange = function() {
                                    if (xhr.readyState === 4) loadStatuses()
                                }
                                xhr.send()
                            })
                        }
                    }

                    Label {
                        visible: modelData.text && modelData.text !== "" && modelData.mediaType !== "poll"
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*Theme.horizontalPageMargin
                        text: modelData.text
                        wrapMode: Text.Wrap
                    }

                    Rectangle {
                        visible: modelData.mediaType === "image" || modelData.mediaType === "video"
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*Theme.horizontalPageMargin
                        height: visible ? (modelData.localPath && modelData.mediaType === "image"
                                           ? Math.min(feedImage.implicitHeight > 0 && feedImage.implicitWidth > 0
                                                      ? width * feedImage.implicitHeight / feedImage.implicitWidth
                                                      : width * 0.6,
                                                      Screen.height * 0.6)
                                           : width * 0.6) : 0
                        color: modelData.localPath ? "black" : Theme.rgba(Theme.primaryColor, 0.1)
                        radius: Theme.paddingMedium

                        Image {
                            id: feedImage
                            anchors.fill: parent
                            anchors.margins: 2
                            fillMode: Image.PreserveAspectFit
                            asynchronous: true
                            source: modelData.localPath && modelData.mediaType === "image"
                                    ? "file://" + modelData.localPath : ""
                        }
                        Label {
                            anchors.centerIn: parent
                            visible: !modelData.localPath && stPage.downloadingId !== modelData.id
                            text: (modelData.mediaType === "video" ? "🎬" : "🖼") + " tap to download"
                            color: Theme.secondaryColor
                        }
                        BusyIndicator {
                            anchors.centerIn: parent
                            running: stPage.downloadingId === modelData.id
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                if (!modelData.localPath) {
                                    stPage.downloadStatus(modelData.id)
                                } else if (modelData.mediaType === "image") {
                                    pageStack.push(statusFullscreen,
                                                   { imagePath: modelData.localPath,
                                                     caption: modelData.text || "" })
                                } else {
                                    Qt.openUrlExternally("file://" + modelData.localPath)
                                }
                            }
                        }
                    }
                }

                ViewPlaceholder {
                    enabled: statuses.length === 0
                    text: "No status updates"
                    hintText: "Status updates from your contacts appear here for 24 hours"
                }
            }
        }
    }

    Component {
        id: statusFullscreen
        Page {
            property string imagePath: ""
            property string caption: ""
            allowedOrientations: Orientation.All
            backgroundColor: "black"

            SilicaFlickable {
                anchors.fill: parent
                contentWidth: width
                contentHeight: height

                Image {
                    anchors.fill: parent
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    source: "file://" + imagePath
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: pageStack.pop()
                }
            }

            Label {
                visible: caption !== ""
                anchors.bottom: parent.bottom
                anchors.bottomMargin: Theme.paddingLarge
                x: Theme.horizontalPageMargin
                width: parent.width - 2*Theme.horizontalPageMargin
                text: caption
                wrapMode: Text.Wrap
                color: "white"
                horizontalAlignment: Text.AlignHCenter
                style: Text.Outline
                styleColor: "black"
            }
        }
    }

    Component {
        id: searchPage
        Page {
            id: spPage
            property var results: []
            property string scopeJid: ""
            property string scopeName: ""

            function doSearch() {
                if (spField.text.trim().length < 2) {
                    results = []
                    return
                }
                var xhr = new XMLHttpRequest()
                xhr.open("GET", "http://127.0.0.1:" + backendPort + "/search?q=" + encodeURIComponent(spField.text.trim())
                         + (scopeJid !== "" ? "&chat=" + scopeJid : ""))
                xhr.onreadystatechange = function() {
                    if (xhr.readyState === 4) {
                        results = xhr.status === 200 ? (JSON.parse(xhr.responseText) || []) : []
                    }
                }
                xhr.send()
            }

            Timer {
                id: searchDebounce
                interval: 300
                repeat: false
                onTriggered: doSearch()
            }

            Column {
                id: spHeader
                width: parent.width
                PageHeader { title: scopeName !== "" ? "Search in " + scopeName : "Search" }
                SearchField {
                    id: spField
                    width: parent.width
                    placeholderText: scopeName !== "" ? "Search in this chat" : "Search chats and messages"
                    focus: true
                    onTextChanged: searchDebounce.restart()
                }
            }

            SilicaListView {
                anchors.top: spHeader.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                clip: true
                model: results

                delegate: ListItem {
                    contentHeight: Theme.itemSizeMedium
                    onClicked: {
                        if (spPage.scopeJid !== "" && modelData.msgId) {
                            // zurueck zum Chat und zur Nachricht springen
                            var prev = pageStack.previousPage(spPage)
                            if (prev && prev.scrollToMsg) prev.scrollToMsg(modelData.msgId)
                            pageStack.pop()
                        } else {
                            pageStack.push(chatPage, {
                                chatJid: modelData.chatJid,
                                chatName: modelData.chatName
                            })
                        }
                    }
                    Column {
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*Theme.horizontalPageMargin
                        anchors.verticalCenter: parent.verticalCenter
                        Row {
                            spacing: Theme.paddingSmall
                            width: parent.width
                            Label {
                                text: modelData.chatName
                                font.pixelSize: Theme.fontSizeMedium
                                color: Theme.highlightColor
                            }
                            Label {
                                text: formatTime(modelData.timestamp)
                                font.pixelSize: Theme.fontSizeExtraSmall
                                color: Theme.secondaryColor
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                        Label {
                            width: parent.width
                            text: modelData.snippet || ""
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.secondaryColor
                            truncationMode: TruncationMode.Fade
                            maximumLineCount: 1
                        }
                    }
                }

                ViewPlaceholder {
                    enabled: results.length === 0
                    text: spField.text.trim().length < 2 ? "Search" : "No results"
                    hintText: spField.text.trim().length < 2
                              ? "Type at least two characters" : "Try different keywords"
                }
            }
        }
    }

    Component {
        id: channelsPage
        Page {
            property var channels: []
            property string chStatus: ""

            function loadChannels() {
                var xhr = new XMLHttpRequest()
                xhr.open("GET", "http://127.0.0.1:" + backendPort + "/channels")
                xhr.onreadystatechange = function() {
                    if (xhr.readyState === 4) {
                        if (xhr.status === 200) channels = JSON.parse(xhr.responseText) || []
                        else chStatus = xhr.responseText
                    }
                }
                xhr.send()
            }

            Component.onCompleted: loadChannels()

            SilicaListView {
                anchors.fill: parent
                model: channels

                header: Column {
                    width: parent ? parent.width : Screen.width
                    PageHeader { title: "Channels" }
                    Label {
                        visible: chStatus !== ""
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*x
                        text: chStatus
                        color: Theme.errorColor
                        font.pixelSize: Theme.fontSizeExtraSmall
                        wrapMode: Text.Wrap
                    }
                }

                delegate: ListItem {
                    contentHeight: Theme.itemSizeMedium
                    onClicked: {
                        var xhr = new XMLHttpRequest()
                        xhr.open("GET", "http://127.0.0.1:" + backendPort + "/channel/messages?jid=" + modelData.jid)
                        xhr.onreadystatechange = function() {
                            if (xhr.readyState === 4) {
                                loadChats()
                                pageStack.push(chatPage, { chatJid: modelData.jid, chatName: modelData.name, isChannel: true })
                            }
                        }
                        xhr.send()
                    }
                    menu: ContextMenu {
                        MenuItem {
                            text: "Unfollow"
                            onClicked: {
                                var xhr = new XMLHttpRequest()
                                xhr.open("GET", "http://127.0.0.1:" + backendPort + "/channel/unfollow?jid=" + modelData.jid)
                                xhr.onreadystatechange = function() {
                                    if (xhr.readyState === 4) loadChannels()
                                }
                                xhr.send()
                            }
                        }
                    }
                    Column {
                        x: Theme.horizontalPageMargin
                        anchors.verticalCenter: parent.verticalCenter
                        Label { text: modelData.name }
                        Label {
                            text: modelData.subscribers + " subscribers"
                            font.pixelSize: Theme.fontSizeExtraSmall
                            color: Theme.secondaryColor
                        }
                    }
                }

                ViewPlaceholder {
                    enabled: channels.length === 0 && chStatus === ""
                    text: "No channels"
                    hintText: "Follow a channel via 'Join via link'"
                }
            }
        }
    }

    Component {
        id: joinLinkPage
        Dialog {
            id: jlDialog
            canAccept: linkField.text.indexOf("chat.whatsapp.com") >= 0
                       || linkField.text.indexOf("whatsapp.com/channel") >= 0
            property string jlStatus: ""

            onAccepted: {
                var isChannel = linkField.text.indexOf("/channel/") >= 0
                var ep = isChannel ? "/channel/follow?link=" : "/group/join?link="
                var xhr = new XMLHttpRequest()
                xhr.open("GET", "http://127.0.0.1:" + backendPort + ep + encodeURIComponent(linkField.text.trim()))
                xhr.onreadystatechange = function() {
                    if (xhr.readyState === 4) {
                        loadChats()
                        loadWAContacts()
                    }
                }
                xhr.send()
            }

            Column {
                width: parent.width
                DialogHeader { title: "Join group or channel" }
                TextField {
                    id: linkField
                    width: parent.width
                    label: "Invite link"
                    placeholderText: "https://chat.whatsapp.com/… or https://whatsapp.com/channel/…"
                    inputMethodHints: Qt.ImhNoAutoUppercase | Qt.ImhNoPredictiveText
                    Component.onCompleted: {
                        // Zwischenablage vorbefuellen, wenn sie einen Link enthaelt
                        if (Clipboard.hasText && (Clipboard.text.indexOf("whatsapp.com") >= 0)) {
                            text = Clipboard.text
                        }
                    }
                }
                Label {
                    x: Theme.horizontalPageMargin
                    width: parent.width - 2*x
                    text: "Paste a group invite link (chat.whatsapp.com/…) or a channel link (whatsapp.com/channel/…). Tip: scan QR codes with a scanner app and copy the link."
                    font.pixelSize: Theme.fontSizeExtraSmall
                    color: Theme.secondaryColor
                    wrapMode: Text.Wrap
                }
            }
        }
    }

    Component {
        id: newGroupPage
        Dialog {
            id: ngDialog
            property var selected: ({})
            property string ngSearch: ""
            canAccept: ngNameText !== "" && selectedCount() > 0
            property string ngNameText: ""

            function ngFiltered() {
                var all = mergedContacts()
                if (ngSearch === "") return all
                var q = ngSearch.toLowerCase()
                var result = []
                for (var i = 0; i < all.length; i++) {
                    if (all[i].name.toLowerCase().indexOf(q) >= 0
                        || all[i].jid.indexOf(q) >= 0) {
                        result.push(all[i])
                    }
                }
                return result
            }

            function selectedCount() {
                var n = 0
                for (var k in selected) if (selected[k]) n++
                return n
            }

            onAccepted: {
                var nums = []
                for (var k in selected) if (selected[k]) nums.push(k)
                globalNotice = "Creating group…"
                var xhr = new XMLHttpRequest()
                xhr.open("GET", "http://127.0.0.1:" + backendPort + "/group/create?name="
                         + encodeURIComponent(ngNameText) + "&participants=" + nums.join(","))
                xhr.onreadystatechange = function() {
                    if (xhr.readyState === 4) {
                        globalNotice = xhr.status === 200
                            ? "Group \"" + ngNameText + "\" created"
                            : "Group creation failed: " + xhr.responseText
                        loadChats()
                    }
                }
                xhr.send()
            }

            // Kopfbereich fest ausserhalb des ListView, damit ein Modellwechsel
            // beim Tippen weder Felder noch Tastaturfokus zerstoert
            Column {
                id: ngHeader
                width: parent.width
                DialogHeader { title: "Create group" }
                TextField {
                    id: ngName
                    width: parent.width
                    label: "Group name"
                    placeholderText: "Group name (max 25 chars)"
                    text: ngDialog.ngNameText
                    onTextChanged: ngDialog.ngNameText = text
                }
                SearchField {
                    id: ngSearchField
                    width: parent.width
                    placeholderText: "Search contacts"
                    onTextChanged: ngDialog.ngSearch = text
                }
                SectionHeader {
                    text: "Select participants"
                          + (ngDialog.selectedCount() > 0 ? " (" + ngDialog.selectedCount() + " selected)" : "")
                }
            }

            SilicaListView {
                anchors.top: ngHeader.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                clip: true
                model: ngFiltered()

                delegate: TextSwitch {
                    text: modelData.name || ("+" + modelData.jid)
                    description: "+" + modelData.jid
                    checked: ngDialog.selected[modelData.jid] === true
                    automaticCheck: false
                    onClicked: {
                        var sel = ngDialog.selected
                        sel[modelData.jid] = !sel[modelData.jid]
                        ngDialog.selected = sel
                        checked = sel[modelData.jid]
                    }
                }
            }
        }
    }

    Component {
        id: newChatPage
        Page {
            property string searchText: ""

            function filteredContacts() {
                var all = mergedContacts()
                if (searchText === "") return all
                var result = []
                var q = searchText.toLowerCase()
                for (var i = 0; i < all.length; i++) {
                    var c = all[i]
                    if (c.name.toLowerCase().indexOf(q) >= 0 || c.jid.indexOf(q) >= 0) {
                        result.push(c)
                    }
                }
                return result
            }

            function isValidNumber() {
                return /^\d{8,15}$/.test(searchField.text)
            }

            SilicaFlickable {
                anchors.fill: parent
                contentHeight: contentCol.height

                Column {
                    id: contentCol
                    width: parent.width

                    PageHeader { title: "New Chat" }

                    SearchField {
                        id: searchField
                        width: parent.width
                        placeholderText: "Enter phone number or search contacts"
                        inputMethodHints: Qt.ImhNone
                        onTextChanged: searchText = text
                    }

                    Column {
                        width: parent.width
                        visible: isValidNumber()
                        
                        SectionHeader { text: "New conversation" }

                        BackgroundItem {
                            width: parent.width
                            height: Theme.itemSizeMedium
                            
                            onClicked: pageStack.replace(chatPage, { 
                                chatJid: searchField.text, 
                                chatName: "+" + searchField.text 
                            })

                            Row {
                                x: Theme.horizontalPageMargin
                                width: parent.width - 2*x
                                height: parent.height
                                spacing: Theme.paddingMedium

                                Rectangle {
                                    width: Theme.itemSizeSmall
                                    height: width
                                    radius: width/2
                                    color: "#25D366"
                                    anchors.verticalCenter: parent.verticalCenter

                                    Label {
                                        anchors.centerIn: parent
                                        text: "+"
                                        color: "white"
                                        font.pixelSize: Theme.fontSizeExtraLarge
                                        font.bold: true
                                    }
                                }

                                Column {
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: Theme.paddingSmall

                                    Label {
                                        text: "+" + searchField.text
                                        font.pixelSize: Theme.fontSizeMedium
                                        color: Theme.highlightColor
                                    }
                                    Label {
                                        text: "Start new chat with this number"
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.secondaryColor
                                    }
                                }
                            }
                        }
                    }

                    SectionHeader { 
                        text: "Contacts (" + filteredContacts().length + ")"
                        visible: filteredContacts().length > 0
                    }

                    Repeater {
                        model: filteredContacts()
                        delegate: ListItem {
                            contentHeight: Theme.itemSizeSmall
                            onClicked: pageStack.replace(chatPage, { 
                                chatJid: modelData.jid, 
                                chatName: modelData.name 
                            })

                            Row {
                                x: Theme.horizontalPageMargin
                                width: parent.width - 2*x
                                height: parent.height
                                spacing: Theme.paddingMedium

                                Loader {
                                    sourceComponent: avatarComponent
                                    width: Theme.iconSizeMedium
                                    height: width
                                    anchors.verticalCenter: parent.verticalCenter
                                    onLoaded: {
                                        item.jid = modelData.jid
                                        item.name = modelData.name
                                        item.isGroup = modelData.jid.length > 15
                                    }
                                }

                                Column {
                                    anchors.verticalCenter: parent.verticalCenter
                                    
                                    Row {
                                        spacing: Theme.paddingSmall
                                        Label { text: modelData.name || "Unknown" }
                                        Label {
                                            visible: modelData.source === "whatsapp"
                                            text: "WhatsApp"
                                            font.pixelSize: Theme.fontSizeExtraSmall
                                            color: "#25D366"
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                    }
                                    Label {
                                        text: modelData.jid.length > 15 ? "Group" : "+" + modelData.jid
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.secondaryColor
                                    }
                                }
                            }
                        }
                    }

                    Label {
                        visible: searchText === "" && filteredContacts().length === 0
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*x
                        text: !contactsOptIn
                              ? "Enter a phone number with country code\n(e.g. 436641234567) to start a chat.\nTip: enable address book suggestions\nin Settings."
                              : ((peopleLoader.item && peopleLoader.item.count === 0)
                                 ? "No contacts accessible.\nEnter a phone number with country code\n(e.g. 436641234567) to start a chat."
                                 : "Enter a phone number with country code\n(e.g. 436641234567)\nto start a new conversation")
                        wrapMode: Text.Wrap
                        horizontalAlignment: Text.AlignHCenter
                        color: Theme.secondaryColor
                        topPadding: Theme.paddingLarge * 2
                    }
                }
            }
        }
    }

    Component {
        id: chatPage
        Page {
            id: chatPageItem
            property string chatJid: ""
            property string chatName: ""
            property string chatAvatar: ""
            property var msgs: []
            property bool isChannel: false
            property bool isGroupChat: chatJid.length > 15 && !isChannel
            property string replyToId: ""
            property string replyToText: ""
            property string replyToSender: ""

            property string editingId: ""
            property string highlightMsgId: ""
            property string downloadingId: ""
            property string downloadError: ""
            property string lastDownloadFailId: ""

            function downloadMediaFor(msgId) {
                if (downloadingId !== "") {
                    // nie stumm bleiben: laufenden Download anzeigen
                    downloadError = "Another download is still running\u2026"
                    lastDownloadFailId = msgId
                    return
                }
                downloadingId = msgId
                downloadError = ""
                var xhr = new XMLHttpRequest()
                // Ohne Timeout kann ein einziger haengender Request
                // downloadingId fuer immer blockieren - dann verschluckt
                // die Wache oben jeden weiteren Tap kommentarlos
                xhr.timeout = 60000
                xhr.ontimeout = function() {
                    downloadingId = ""
                    downloadError = "Download timed out - backend may be stuck, see backend.log"
                    lastDownloadFailId = msgId
                }
                xhr.open("GET", "http://127.0.0.1:" + backendPort + "/download?id=" + encodeURIComponent(msgId))
                xhr.onreadystatechange = function() {
                    if (xhr.readyState === 4) {
                        downloadingId = ""
                        if (xhr.status === 200) {
                            load()
                        } else {
                            // Status 0 = Backend nicht erreichbar; leere
                            // Antworten duerfen nicht "nichts" anzeigen
                            downloadError = xhr.responseText && xhr.responseText !== ""
                                ? xhr.responseText
                                : (xhr.status === 0
                                   ? "Backend not reachable (download request failed) - check backend.log"
                                   : "Download failed (HTTP " + xhr.status + ")")
                            lastDownloadFailId = msgId
                        }
                    }
                }
                xhr.send()
            }

            property var groupParticipants: []   // [{number, name}] fuer @-Vorschlaege
            property var mentionMap: ({})        // Name -> Nummer (gewaehlte Erwaehnungen)
            property string mentionToken: ""     // aktuell getipptes @-Fragment

            function ensureParticipants() {
                if (!isGroupChat || groupParticipants.length > 0) return
                var xhr = new XMLHttpRequest()
                xhr.open("GET", "http://127.0.0.1:" + backendPort + "/group/info?chat=" + chatJid)
                xhr.onreadystatechange = function() {
                    if (xhr.readyState === 4 && xhr.status === 200) {
                        var d = JSON.parse(xhr.responseText)
                        var ps = d.participants || []
                        var out = []
                        for (var i = 0; i < ps.length; i++) {
                            var num = ps[i].number || ps[i].jid || ps[i]
                            if (typeof num === "string" && num.indexOf("@") > 0) num = num.split("@")[0]
                            out.push({ number: num, name: senderDisplay(num) })
                        }
                        groupParticipants = out
                    }
                }
                xhr.send()
            }

            function updateMentionToken() {
                if (!isGroupChat) { mentionToken = ""; return }
                var t = input.text
                var at = t.lastIndexOf("@")
                if (at < 0 || (at > 0 && t.charAt(at-1) !== " " && t.charAt(at-1) !== "\n")) {
                    mentionToken = ""
                    return
                }
                var frag = t.substring(at + 1)
                if (frag.indexOf(" ") >= 0 || frag.length > 25) { mentionToken = ""; return }
                mentionToken = frag
                ensureParticipants()
            }

            function mentionSuggestions() {
                if (mentionToken === "" && input.text.charAt(input.text.length-1) !== "@") return []
                var f = mentionToken.toLowerCase()
                var out = []
                for (var i = 0; i < groupParticipants.length && out.length < 5; i++) {
                    var p = groupParticipants[i]
                    if (f === "" || p.name.toLowerCase().indexOf(f) === 0 || p.number.indexOf(f) === 0) {
                        out.push(p)
                    }
                }
                return out
            }

            function pickMention(p) {
                var t = input.text
                var at = t.lastIndexOf("@")
                input.text = t.substring(0, at) + "@" + p.name + " "
                var mm = mentionMap
                mm[p.name] = p.number
                mentionMap = mm
                mentionToken = ""
                input.forceActiveFocus()
                input.cursorPosition = input.text.length
            }

            // @Name -> @Nummer fuers Protokoll uebersetzen
            function resolveMentionsForSend(t) {
                for (var name in mentionMap) {
                    t = t.split("@" + name).join("@" + mentionMap[name])
                }
                return t
            }

            // @Nummer -> @Name fuer die Anzeige
            function mentionsToNames(t) {
                if (!t || t.indexOf("@") < 0) return t
                return t.replace(/@(\d{5,15})/g, function(m, num) { return "@" + senderDisplay(num) })
            }

            function scrollToMsg(msgId) {
                for (var i = 0; i < msgs.length; i++) {
                    if (msgs[i].id === msgId) {
                        msgList.positionViewAtIndex(i, ListView.Center)
                        highlightMsgId = msgId
                        highlightClear.restart()
                        return
                    }
                }
            }

            Timer {
                id: highlightClear
                interval: 2000
                repeat: false
                onTriggered: highlightMsgId = ""
            }

            function blockAction(action) {
                var xhr = new XMLHttpRequest()
                xhr.open("GET", "http://127.0.0.1:" + backendPort + "/block?jid=" + chatJid + "&action=" + action)
                xhr.send()
            }

            function reactTo(msgId, msgSender, emoji) {
                var xhr = new XMLHttpRequest()
                xhr.open("GET", "http://127.0.0.1:" + backendPort + "/react?chat=" + chatJid
                         + "&id=" + encodeURIComponent(msgId)
                         + "&sender=" + encodeURIComponent(msgSender)
                         + "&emoji=" + encodeURIComponent(emoji))
                xhr.onreadystatechange = function() {
                    if (xhr.readyState === 4) load()
                }
                xhr.send()
            }

            function revokeMessage(msgId) {
                var xhr = new XMLHttpRequest()
                xhr.open("GET", "http://127.0.0.1:" + backendPort + "/revoke?chat=" + chatJid
                         + "&id=" + encodeURIComponent(msgId))
                xhr.onreadystatechange = function() {
                    if (xhr.readyState === 4) load()
                }
                xhr.send()
            }

            function reactionText(reactions) {
                if (!reactions) return ""
                var counts = {}
                for (var who in reactions) {
                    var e = reactions[who]
                    counts[e] = (counts[e] || 0) + 1
                }
                var parts = []
                for (var emoji in counts) {
                    parts.push(counts[emoji] > 1 ? emoji + counts[emoji] : emoji)
                }
                return parts.join(" ")
            }

            function senderDisplay(number) {
                if (!number) return ""
                var n = findLocalContactName(number)
                if (n) return n
                if (waContactsMap[number]) return waContactsMap[number]
                return "+" + number
            }

            function senderColor(number) {
                var palette = ["#e57373", "#64b5f6", "#81c784", "#ffb74d",
                               "#ba68c8", "#4dd0e1", "#f06292", "#a1887f"]
                var h = 0
                for (var i = 0; i < number.length; i++) h = (h * 31 + number.charCodeAt(i)) & 0x7fffffff
                return palette[h % palette.length]
            }

            function load() {
                var xhr = new XMLHttpRequest()
                xhr.open("GET", "http://127.0.0.1:" + backendPort + "/messages?jid=" + chatJid)
                xhr.onreadystatechange = function() {
                    if (xhr.readyState === 4 && xhr.status === 200) {
                        msgs = JSON.parse(xhr.responseText) || []
                    }
                }
                xhr.send()
            }

            function send() {
                if (input.text === "") return
                var url
                if (editingId !== "") {
                    url = "http://127.0.0.1:" + backendPort + "/edit?chat=" + chatJid
                        + "&id=" + encodeURIComponent(editingId)
                        + "&text=" + encodeURIComponent(input.text)
                } else {
                    var outText = resolveMentionsForSend(input.text)
                    url = "http://127.0.0.1:" + backendPort + "/send?to=" + chatJid
                        + "&text=" + encodeURIComponent(outText)
                    // @<nummer> im Text -> Erwaehnungen
                    var mm = outText.match(/@(\d{5,15})/g)
                    if (mm && mm.length > 0) {
                        var nums = []
                        for (var mi = 0; mi < mm.length; mi++) nums.push(mm[mi].substring(1))
                        url += "&mentions=" + nums.join(",")
                    }
                    if (replyToId !== "") {
                        url += "&quoteId=" + encodeURIComponent(replyToId)
                            + "&quoteSender=" + encodeURIComponent(replyToSender)
                            + "&quoteText=" + encodeURIComponent(replyToText)
                    }
                }
                var xhr = new XMLHttpRequest()
                xhr.open("GET", url)
                xhr.onreadystatechange = function() {
                    if (xhr.readyState === 4 && xhr.status === 200) {
                        input.text = ""
                        editingId = ""
                        replyToId = ""; replyToText = ""; replyToSender = ""
                        load()
                        loadChats()
                    }
                }
                xhr.send()
            }

            function sendFile(path) {
                var xhr = new XMLHttpRequest()
                xhr.open("POST", "http://127.0.0.1:" + backendPort + "/sendmedia?to=" + chatJid + "&file=" + encodeURIComponent(path) + "&caption=")
                xhr.onreadystatechange = function() {
                    if (xhr.readyState === 4) {
                        load()
                        loadChats()
                    }
                }
                xhr.send()
            }

            Timer { interval: 2000; running: true; repeat: true; onTriggered: load() }
            Component.onCompleted: load()

            Component {
                id: imagePicker
                ImagePickerPage {
                    onSelectedContentPropertiesChanged: {
                        chatPageItem.sendFile(selectedContentProperties.filePath)
                    }
                }
            }

            Component {
                id: filePicker
                FilePickerPage {
                    onSelectedContentPropertiesChanged: {
                        chatPageItem.sendFile(selectedContentProperties.filePath)
                    }
                }
            }

            SilicaListView {
                id: msgList
                anchors.fill: parent
                anchors.topMargin: pinnedBar.visible ? pageHead.height + pinnedBar.height : 0
                anchors.bottomMargin: inputCol.height
                model: msgs
                verticalLayoutDirection: ListView.TopToBottom
                clip: true
                // positionViewAtEnd() directly in onCountChanged/onCompleted does not
                // work reliably: the view is not laid out yet at that point.
                // Delay via Timer so the last chat bubble is always visible.
                Timer {
                    id: positionTimer
                    interval: 200
                    repeat: false
                    onTriggered: msgList.positionViewAtIndex(msgList.count - 1, ListView.End)
                }
                onCountChanged: positionTimer.start()
                Component.onCompleted: positionTimer.start()

                PullDownMenu {
                    MenuItem {
                        text: "Refresh channel"
                        visible: isChannel
                        onClicked: {
                            var xhr = new XMLHttpRequest()
                            xhr.open("GET", "http://127.0.0.1:" + backendPort + "/channel/messages?jid=" + chatJid)
                            xhr.onreadystatechange = function() {
                                if (xhr.readyState === 4) load()
                            }
                            xhr.send()
                        }
                    }
                    MenuItem {
                        text: "Unfollow channel"
                        visible: isChannel
                        onClicked: blockRemorse.execute("Unfollowing channel", function() {
                            var xhr = new XMLHttpRequest()
                            xhr.open("GET", "http://127.0.0.1:" + backendPort + "/channel/unfollow?jid=" + chatJid)
                            xhr.send()
                        })
                    }
                    MenuItem {
                        text: "Search in chat"
                        onClicked: pageStack.push(searchPage, { scopeJid: chatJid, scopeName: chatName })
                    }
                    MenuItem {
                        text: "Share live location\u2026"
                        visible: chatJid !== "status" && !isChannel && !(liveActive && liveChatJid === chatJid)
                        onClicked: {
                            var dlg = pageStack.push(liveDurationDialog)
                            dlg.accepted.connect(function() {
                                startLiveShare(chatJid, [15, 60, 480][dlg.durationIndex])
                            })
                        }
                    }
                    MenuItem {
                        text: "Stop live location"
                        visible: liveActive && liveChatJid === chatJid
                        onClicked: stopLiveShare()
                    }
                    MenuItem {
                        text: "Send location\u2026"
                        visible: chatJid !== "status" && !isChannel
                        onClicked: {
                            var dlg = pageStack.push(locationDialog)
                            dlg.accepted.connect(function() {
                                var xhr = new XMLHttpRequest()
                                xhr.open("GET", "http://127.0.0.1:" + backendPort + "/send/location?to=" + chatJid
                                         + "&lat=" + dlg.lat + "&lon=" + dlg.lon
                                         + "&name=" + encodeURIComponent(dlg.locName))
                                xhr.onreadystatechange = function() {
                                    if (xhr.readyState === 4) load()
                                }
                                xhr.send()
                            })
                        }
                    }
                    MenuItem {
                        text: "Disappearing messages\u2026"
                        visible: chatJid !== "status" && !isChannel
                        onClicked: {
                            var dlg = pageStack.push(disappearingDialog, { chatJid: chatJid })
                        }
                    }
                    MenuItem {
                        text: "Clear chat"
                        visible: chatJid !== "status"
                        onClicked: blockRemorse.execute("Clearing chat", function() {
                            var xhr = new XMLHttpRequest()
                            xhr.open("GET", "http://127.0.0.1:" + backendPort + "/chat/clear?jid=" + chatJid)
                            xhr.onreadystatechange = function() {
                                if (xhr.readyState === 4) load()
                            }
                            xhr.send()
                        })
                    }
                    MenuItem {
                        text: "Delete chat"
                        visible: chatJid !== "status" && !isChannel
                        onClicked: blockRemorse.execute("Deleting chat", function() {
                            var xhr = new XMLHttpRequest()
                            xhr.open("GET", "http://127.0.0.1:" + backendPort + "/chat/delete?jid=" + chatJid)
                            xhr.onreadystatechange = function() {
                                if (xhr.readyState === 4) pageStack.pop()
                            }
                            xhr.send()
                        })
                    }
                    MenuItem {
                        text: "Load older messages"
                        visible: chatJid !== "status" && !isChannel && !isChannel
                        onClicked: {
                            var xhr = new XMLHttpRequest()
                            xhr.open("GET", "http://127.0.0.1:" + backendPort + "/loadolder?chat=" + chatJid)
                            xhr.onreadystatechange = function() {
                                if (xhr.readyState === 4) {
                                    downloadError = xhr.responseText
                                    lastDownloadFailId = ""
                                    if (xhr.status === 200) reloadTimer.start()
                                }
                            }
                            xhr.send()
                        }
                    }
                    MenuItem {
                        text: "Create poll"
                        visible: chatJid !== "status" && !isChannel
                        onClicked: pageStack.push(createPollPage, { targetChat: chatJid })
                    }
                    MenuItem {
                        text: "Group info"
                        visible: isGroupChat
                        onClicked: pageStack.push(groupInfoPage, { groupJid: chatJid })
                    }
                    MenuItem {
                        text: "Block contact"
                        visible: !isGroupChat && chatJid !== "status" && !isChannel
                        onClicked: blockRemorse.execute("Blocking +" + chatJid, function() { blockAction("block") })
                    }
                    MenuItem {
                        text: "Unblock contact"
                        visible: !isGroupChat && chatJid !== "status" && !isChannel
                        onClicked: blockAction("unblock")
                    }
                    MenuItem {
                        text: "Call +" + chatJid
                        visible: !isGroupChat && chatJid !== "status" && !isChannel
                        onClicked: Qt.openUrlExternally("tel:+" + chatJid)
                    }
                    MenuItem { text: "Send file"; visible: chatJid !== "status" && !isChannel; onClicked: pageStack.push(filePicker) }
                    MenuItem { text: "Send image"; visible: chatJid !== "status" && !isChannel; onClicked: pageStack.push(imagePicker) }
                    MenuItem { text: "Refresh"; onClicked: load() }
                }

                RemorsePopup { id: blockRemorse }

                Timer {
                    id: reloadTimer
                    interval: 4000
                    repeat: false
                    onTriggered: { load(); loadChats() }
                }

                header: Item { height: Theme.paddingLarge }


                delegate: ListItem {
                    width: parent.width
                    contentHeight: msgContent.height + Theme.paddingSmall
                    highlighted: down || menuOpen || modelData.id === highlightMsgId
                            property var voters: modelData.pollVoters || ({})
                    property var myVotes: voters[phone] || []

                    function voteCount(opt) {
                        var n = 0
                        for (var who in voters) {
                            if (voters[who].indexOf(opt) >= 0) n++
                        }
                        return n
                    }

                    function totalVoters() {
                        var n = 0
                        for (var who in voters) n++
                        return n
                    }
                    function sendVote(opt) {
                        var sel
                        if (modelData.pollMultiple) {
                            sel = myVotes.slice()
                            var idx = sel.indexOf(opt)
                            if (idx >= 0) sel.splice(idx, 1)
                            else sel.push(opt)
                        } else {
                            sel = (myVotes.indexOf(opt) >= 0) ? [] : [opt]
                        }
                        var xhr = new XMLHttpRequest()
                        xhr.open("GET", "http://127.0.0.1:" + backendPort + "/pollvote?chat=" + chatJid
                                 + "&id=" + encodeURIComponent(modelData.id)
                                 + "&options=" + encodeURIComponent(sel.join("||")))
                        xhr.onreadystatechange = function() {
                            if (xhr.readyState === 4) {
                                if (xhr.status !== 200) {
                                    downloadError = xhr.responseText
                                    lastDownloadFailId = modelData.id
                                }
                                load()
                            }
                        }
                        xhr.send()
                    }

                    
                    menu: ContextMenu {
                        MenuItem {
                            text: "Reply"
                            visible: !modelData.revoked
                            onClicked: {
                                replyToId = modelData.id
                                replyToText = (modelData.text || (modelData.mediaType ? "[" + modelData.mediaType + "]" : "")).substring(0, 120)
                                replyToSender = modelData.fromMe ? "" : modelData.sender
                            }
                        }
                        Row {
                            id: reactRow
                            height: Theme.itemSizeExtraSmall
                            anchors.horizontalCenter: parent.horizontalCenter
                            spacing: Theme.paddingLarge
                            visible: !modelData.revoked
                            property string targetId: modelData.id
                            property string targetSender: modelData.fromMe ? phone : modelData.sender
                            Repeater {
                                model: ["👍", "❤️", "😂", "😮", "😢", "🙏"]
                                Label {
                                    text: modelData
                                    font.pixelSize: Theme.fontSizeLarge
                                    anchors.verticalCenter: parent.verticalCenter
                                    MouseArea {
                                        anchors.fill: parent
                                        anchors.margins: -Theme.paddingSmall
                                        onClicked: reactTo(reactRow.targetId, reactRow.targetSender, text)
                                    }
                                }
                            }
                        }
                        MenuItem {
                            text: "Edit"
                            visible: modelData.fromMe && !modelData.revoked && !modelData.mediaType && modelData.text !== ""
                            onClicked: {
                                editingId = modelData.id
                                input.text = modelData.text
                                input.forceActiveFocus()
                            }
                        }
                        MenuItem {
                            text: "Delete for everyone"
                            visible: modelData.fromMe && !modelData.revoked
                            onClicked: revokeMessage(modelData.id)
                        }
                        MenuItem {
                            text: "Call back +" + modelData.sender
                            visible: modelData.text && modelData.text.indexOf("\ud83d\udcde") === 0 && !modelData.fromMe
                            onClicked: Qt.openUrlExternally("tel:+" + modelData.sender)
                        }
                        MenuItem {
                            text: "Open"
                            visible: !!modelData.localPath
                            onClicked: Qt.openUrlExternally("file://" + modelData.localPath)
                        }
                        MenuItem {
                            text: "Copy text"
                            visible: modelData.text && modelData.text !== ""
                            onClicked: Clipboard.text = modelData.text
                        }
                        MenuItem {
                            text: "Forward\u2026"
                            visible: !modelData.revoked && !modelData.pollName
                            onClicked: pageStack.push(forwardPage, { forwardId: modelData.id })
                        }
                        MenuItem {
                            text: modelData.pinnedInChat ? "Unpin" : "Pin"
                            visible: !modelData.revoked && chatPageItem.chatJid !== "status" && !chatPageItem.isChannel
                            onClicked: {
                                var xhr = new XMLHttpRequest()
                                xhr.open("GET", "http://127.0.0.1:" + backendPort + "/msg/pin?chat=" + chatPageItem.chatJid
                                         + "&id=" + modelData.id
                                         + "&sender=" + (modelData.fromMe ? "" : modelData.sender)
                                         + "&fromMe=" + (modelData.fromMe ? "1" : "0")
                                         + (modelData.pinnedInChat ? "&unpin=1" : ""))
                                xhr.onreadystatechange = function() {
                                    if (xhr.readyState === 4) loadMessages()
                                }
                                xhr.send()
                            }
                        }
                        MenuItem {
                            text: "Join group"
                            visible: modelData.inviteCode !== undefined && modelData.inviteCode !== "" && !modelData.fromMe
                            onClicked: {
                                var xhr = new XMLHttpRequest()
                                xhr.open("GET", "http://127.0.0.1:" + backendPort + "/group/joininvite?id=" + modelData.id)
                                xhr.onreadystatechange = function() {
                                    if (xhr.readyState === 4) {
                                        globalNotice = xhr.status === 200 ? "Joined group" : ("Join failed: " + xhr.responseText)
                                    }
                                }
                                xhr.send()
                            }
                        }
                    }

                    Column {
                        id: msgContent
                        width: parent.width * 0.8
                        anchors.right: modelData.fromMe ? parent.right : undefined
                        anchors.left: modelData.fromMe ? undefined : parent.left
                        anchors.margins: Theme.horizontalPageMargin
                        spacing: Theme.paddingSmall

                        Column {
                            visible: modelData.mediaType === "poll"
                            width: parent.width
                            spacing: Theme.paddingSmall



                            Label {
                                text: "📊 " + (modelData.pollName || "Poll")
                                font.bold: true
                                wrapMode: Text.Wrap
                                width: parent.width
                            }

                            Repeater {
                                model: modelData.pollOptions || []
                                BackgroundItem {
                                    width: parent.width
                                    height: Theme.itemSizeExtraSmall
                                    onClicked: parent.sendVote(modelData)

                                    property bool mine: parent.myVotes.indexOf(modelData) >= 0
                                    property int votes: parent.voteCount(modelData)

                                    Rectangle {
                                        anchors.fill: parent
                                        radius: Theme.paddingSmall
                                        color: Theme.rgba(mine ? "#25D366" : Theme.primaryColor, mine ? 0.25 : 0.08)
                                    }
                                    Label {
                                        x: Theme.paddingMedium
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: parent.width - voteLbl.width - 3*Theme.paddingMedium
                                        text: (mine ? "✓ " : "") + modelData
                                        truncationMode: TruncationMode.Fade
                                        font.pixelSize: Theme.fontSizeSmall
                                    }
                                    Label {
                                        id: voteLbl
                                        anchors.right: parent.right
                                        anchors.rightMargin: Theme.paddingMedium
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: votes
                                        color: Theme.secondaryColor
                                        font.pixelSize: Theme.fontSizeSmall
                                    }
                                }
                            }

                            Label {
                                text: totalVoters() + (totalVoters() === 1 ? " vote" : " votes")
                                      + (modelData.pollMultiple ? " · multiple answers allowed" : "")
                                font.pixelSize: Theme.fontSizeExtraSmall
                                color: Theme.secondaryColor
                            }
                        }

                        Rectangle {
                            visible: modelData.mediaType === "location"
                            width: parent.width
                            height: visible ? Theme.itemSizeMedium : 0
                            color: Theme.rgba(Theme.primaryColor, 0.1)
                            radius: Theme.paddingMedium

                            Row {
                                anchors.centerIn: parent
                                spacing: Theme.paddingMedium
                                Label { text: "📍"; font.pixelSize: Theme.fontSizeExtraLarge }
                                Column {
                                    anchors.verticalCenter: parent.verticalCenter
                                    Label { text: "Location"; font.pixelSize: Theme.fontSizeSmall }
                                    Label {
                                        text: "Tap to open in maps"
                                        font.pixelSize: Theme.fontSizeExtraSmall
                                        color: Theme.secondaryColor
                                    }
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                onClicked: Qt.openUrlExternally("geo:" + modelData.latitude + "," + modelData.longitude)
                            }
                        }

                        Rectangle {
                            visible: modelData.quotedId ? true : false
                            width: parent.width
                            height: visible ? quoteCol.height + 2*Theme.paddingSmall : 0
                            color: Theme.rgba(Theme.highlightColor, 0.15)
                            radius: Theme.paddingSmall
                            border.width: 0

                            Rectangle {
                                width: 4
                                height: parent.height
                                color: "#25D366"
                                radius: 2
                            }

                            Column {
                                id: quoteCol
                                anchors.verticalCenter: parent.verticalCenter
                                x: Theme.paddingMedium
                                width: parent.width - 2*Theme.paddingMedium

                                Label {
                                    visible: modelData.quotedSender ? true : false
                                    text: modelData.quotedSender ? senderDisplay(modelData.quotedSender) : ""
                                    font.pixelSize: Theme.fontSizeExtraSmall
                                    font.bold: true
                                    color: Theme.highlightColor
                                }
                                Label {
                                    width: parent.width
                                    text: modelData.quotedText || ""
                                    font.pixelSize: Theme.fontSizeExtraSmall
                                    color: Theme.secondaryColor
                                    wrapMode: Text.Wrap
                                    maximumLineCount: 2
                                    elide: Text.ElideRight
                                }
                            }
                        }

                        Label {
                            property bool mentionsMe: {
                                if (!modelData.mentions) return false
                                for (var i = 0; i < modelData.mentions.length; i++)
                                    if (modelData.mentions[i] === phone) return true
                                return false
                            }
                            visible: modelData.forwarded === true || modelData.pinnedInChat === true
                                     || modelData.live === true || mentionsMe
                                     || (modelData.ephemeral !== undefined && modelData.ephemeral > 0)
                            text: (modelData.forwarded ? "\u21aa Forwarded  " : "")
                                  + (modelData.pinnedInChat ? "\ud83d\udccc Pinned  " : "")
                                  + (modelData.live ? "\ud83d\udd34 Live  " : "")
                                  + (mentionsMe ? "\ud83d\udd14 Mentioned you  " : "")
                                  + ((modelData.ephemeral !== undefined && modelData.ephemeral > 0) ? "\u23f3" : "")
                            font.pixelSize: Theme.fontSizeTiny
                            color: Theme.secondaryHighlightColor
                        }

                        Label {
                            visible: isGroupChat && !modelData.fromMe
                            text: visible ? senderDisplay(modelData.sender) : ""
                            font.pixelSize: Theme.fontSizeExtraSmall
                            font.bold: true
                            color: visible ? senderColor(modelData.sender) : Theme.primaryColor
                        }

                        Rectangle {
                            visible: modelData.mediaType === "image"
                            width: parent.width
                            height: visible ? width * 0.75 : 0
                            color: Theme.rgba(Theme.primaryColor, 0.1)
                            radius: Theme.paddingMedium

                            Image {
                                anchors.fill: parent
                                anchors.margins: 2
                                fillMode: Image.PreserveAspectFit
                                source: modelData.localPath ? "file://" + modelData.localPath : ""
                                // Datei wurde geloescht (Storage-Clear etc.):
                                // Backend verwirft den toten Pfad und laedt neu
                                onStatusChanged: {
                                    if (status === Image.Error && modelData.localPath) {
                                        downloadMediaFor(modelData.id)
                                    }
                                }
                                BusyIndicator {
                                    anchors.centerIn: parent
                                    running: parent.status === Image.Loading
                                            || downloadingId === modelData.id
                                    size: BusyIndicatorSize.Medium
                                }
                            }

                            Column {
                                anchors.centerIn: parent
                                visible: !modelData.localPath && downloadingId !== modelData.id
                                spacing: Theme.paddingSmall
                                Image {
                                    source: "image://theme/icon-l-image"
                                    anchors.horizontalCenter: parent.horizontalCenter
                                }
                                Label {
                                    text: "Tap to download" + (modelData.fileSize ? " (" + formatSize(modelData.fileSize) + ")" : "")
                                    font.pixelSize: Theme.fontSizeExtraSmall
                                    color: Theme.secondaryColor
                                    anchors.horizontalCenter: parent.horizontalCenter
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                onClicked: modelData.localPath
                                           ? Qt.openUrlExternally("file://" + modelData.localPath)
                                           : downloadMediaFor(modelData.id)
                            }
                        }

                        Rectangle {
                            visible: modelData.mediaType === "video"
                            width: parent.width
                            height: visible ? Theme.itemSizeLarge : 0
                            color: Theme.rgba(Theme.primaryColor, 0.1)
                            radius: Theme.paddingMedium

                            Row {
                                anchors.centerIn: parent
                                spacing: Theme.paddingMedium
                                Label { text: "🎬"; font.pixelSize: Theme.fontSizeExtraLarge }
                                Column {
                                    anchors.verticalCenter: parent.verticalCenter
                                    Label { text: modelData.fileName || "Video"; font.pixelSize: Theme.fontSizeSmall }
                                    Label { text: formatSize(modelData.fileSize) + (modelData.localPath ? "" : " · tap to download"); font.pixelSize: Theme.fontSizeExtraSmall; color: Theme.secondaryColor }
                                }
                            }

                            BusyIndicator {
                                anchors.right: parent.right
                                anchors.rightMargin: Theme.paddingMedium
                                anchors.verticalCenter: parent.verticalCenter
                                running: downloadingId === modelData.id
                                size: BusyIndicatorSize.Small
                            }

                            MouseArea {
                                anchors.fill: parent
                                onClicked: modelData.localPath
                                           ? Qt.openUrlExternally("file://" + modelData.localPath)
                                           : downloadMediaFor(modelData.id)
                            }
                        }

                        Rectangle {
                            visible: modelData.mediaType === "audio"
                            width: parent.width
                            height: visible ? Theme.itemSizeSmall : 0
                            color: Theme.rgba(Theme.primaryColor, 0.1)
                            radius: Theme.paddingMedium

                            Row {
                                anchors.centerIn: parent
                                spacing: Theme.paddingMedium
                                Label { text: "🎵"; font.pixelSize: Theme.fontSizeLarge }
                                Label { text: "Audio · " + formatSize(modelData.fileSize) + (modelData.localPath ? "" : " · tap to download"); font.pixelSize: Theme.fontSizeSmall; color: Theme.secondaryColor }
                            }

                            BusyIndicator {
                                anchors.right: parent.right
                                anchors.rightMargin: Theme.paddingMedium
                                anchors.verticalCenter: parent.verticalCenter
                                running: downloadingId === modelData.id
                                size: BusyIndicatorSize.Small
                            }

                            MouseArea {
                                anchors.fill: parent
                                onClicked: modelData.localPath
                                           ? Qt.openUrlExternally("file://" + modelData.localPath)
                                           : downloadMediaFor(modelData.id)
                            }
                        }

                        Rectangle {
                            visible: modelData.mediaType === "document"
                            width: parent.width
                            height: visible ? Theme.itemSizeSmall : 0
                            color: Theme.rgba(Theme.primaryColor, 0.1)
                            radius: Theme.paddingMedium

                            Row {
                                anchors.centerIn: parent
                                spacing: Theme.paddingMedium
                                Label { text: "📄"; font.pixelSize: Theme.fontSizeLarge }
                                Column {
                                    Label { text: modelData.fileName || "Document"; font.pixelSize: Theme.fontSizeSmall }
                                    Label { text: formatSize(modelData.fileSize) + (modelData.localPath ? "" : " · tap to download"); font.pixelSize: Theme.fontSizeExtraSmall; color: Theme.secondaryColor }
                                }
                            }

                            BusyIndicator {
                                anchors.right: parent.right
                                anchors.rightMargin: Theme.paddingMedium
                                anchors.verticalCenter: parent.verticalCenter
                                running: downloadingId === modelData.id
                                size: BusyIndicatorSize.Small
                            }

                            MouseArea {
                                anchors.fill: parent
                                onClicked: modelData.localPath
                                           ? Qt.openUrlExternally("file://" + modelData.localPath)
                                           : downloadMediaFor(modelData.id)
                            }
                        }

                        Image {
                            visible: modelData.mediaType === "sticker"
                            width: Theme.itemSizeLarge
                            height: width
                            fillMode: Image.PreserveAspectFit
                            source: modelData.localPath ? "file://" + modelData.localPath : ""
                            Label {
                                anchors.centerIn: parent
                                visible: !modelData.localPath
                                text: downloadingId === modelData.id ? "…" : "🙂⬇"
                                font.pixelSize: Theme.fontSizeLarge
                            }
                            MouseArea {
                                anchors.fill: parent
                                enabled: !modelData.localPath
                                onClicked: downloadMediaFor(modelData.id)
                            }
                        }

                        Rectangle {
                            visible: modelData.text && modelData.text !== "" && modelData.mediaType !== "poll"
                            width: Math.min(msgTxt.implicitWidth + Theme.paddingLarge * 2, parent.width)
                            height: visible ? msgTxt.height + Theme.paddingMedium * 2 : 0
                            color: modelData.fromMe ? Theme.highlightBackgroundColor : Theme.rgba(Theme.primaryColor, 0.1)
                            radius: Theme.paddingMedium

                            Label {
                                id: msgTxt
                                anchors.centerIn: parent
                                width: parent.width - Theme.paddingLarge * 2
                                text: mentionsToNames(modelData.text)
                                wrapMode: Text.Wrap
                            }
                        }

                        Label {
                            visible: reactionText(modelData.reactions) !== ""
                            text: reactionText(modelData.reactions)
                            font.pixelSize: Theme.fontSizeSmall
                            anchors.right: modelData.fromMe ? parent.right : undefined
                        }

                        Label {
                            text: formatTime(modelData.timestamp) + (modelData.edited ? " · edited" : "")
                            font.pixelSize: Theme.fontSizeExtraSmall
                            color: Theme.secondaryColor
                            anchors.right: modelData.fromMe ? parent.right : undefined
                        }

                        Label {
                            visible: downloadError !== "" && downloadingId === "" && modelData.id === lastDownloadFailId
                            width: parent.width
                            text: downloadError
                            wrapMode: Text.Wrap
                            font.pixelSize: Theme.fontSizeExtraSmall
                            color: Theme.errorColor
                        }
                    }
                }

                ViewPlaceholder {
                    enabled: msgs.length === 0
                    text: "No messages yet"
                    hintText: "Send a message to start the conversation"
                }
            }

            Column {
                id: inputCol
                width: parent.width
                anchors.bottom: parent.bottom
                visible: chatJid !== "status" && !isChannel

                // Banner: Antworten auf / Bearbeiten von
                Rectangle {
                    visible: replyToId !== "" || editingId !== ""
                    width: parent.width
                    height: visible ? Theme.itemSizeExtraSmall : 0
                    color: Theme.rgba(Theme.highlightColor, 0.15)

                    Rectangle { width: 4; height: parent.height; color: "#25D366" }

                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        x: Theme.paddingMedium
                        width: parent.width - Theme.itemSizeSmall - 2*Theme.paddingMedium

                        Label {
                            text: editingId !== "" ? "Edit message"
                                  : (replyToSender ? "Reply to " + senderDisplay(replyToSender) : "Reply")
                            font.pixelSize: Theme.fontSizeExtraSmall
                            font.bold: true
                            color: Theme.highlightColor
                        }
                        Label {
                            visible: replyToId !== ""
                            width: parent.width
                            text: replyToText
                            font.pixelSize: Theme.fontSizeExtraSmall
                            color: Theme.secondaryColor
                            elide: Text.ElideRight
                            maximumLineCount: 1
                        }
                    }

                    IconButton {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        icon.source: "image://theme/icon-m-clear"
                        onClicked: {
                            replyToId = ""; replyToText = ""; replyToSender = ""
                            if (editingId !== "") { editingId = ""; input.text = "" }
                        }
                    }
                }

                Column {
                    width: parent.width
                    visible: mentionToken !== "" || (input.text.length > 0 && input.text.charAt(input.text.length-1) === "@")
                    Repeater {
                        model: mentionSuggestions()
                        BackgroundItem {
                            width: parent.width
                            height: Theme.itemSizeSmall
                            onClicked: pickMention(modelData)
                            Label {
                                x: Theme.horizontalPageMargin
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.name + (modelData.name !== "+" + modelData.number ? "  (+" + modelData.number + ")" : "")
                                color: Theme.highlightColor
                                font.pixelSize: Theme.fontSizeSmall
                            }
                        }
                    }
                }

                Row {
                    width: parent.width

                    IconButton {
                        icon.source: "image://theme/icon-m-attach"
                        onClicked: pageStack.push(filePicker)
                    }

                    TextField {
                        id: input
                        width: parent.width - sendBtn.width - parent.children[0].width
                        placeholderText: "Message..."
                        EnterKey.onClicked: send()
                        backgroundStyle: TextEditor.NoBackground
                        onTextChanged: updateMentionToken()
                    }

                    IconButton {
                        id: sendBtn
                        icon.source: "image://theme/icon-m-send"
                        onClicked: send()
                    }
                }
            }

            PageHeader { id: pageHead; title: chatName }

            Rectangle {
                id: pinnedBar
                property var pinnedMsg: {
                    for (var i = msgs.length - 1; i >= 0; i--) {
                        if (msgs[i].pinnedInChat) return msgs[i]
                    }
                    return null
                }
                visible: pinnedMsg !== null
                anchors.top: pageHead.bottom
                width: parent.width
                height: visible ? pinLabel.height + 2*Theme.paddingMedium : 0
                color: Theme.rgba(Theme.highlightBackgroundColor, 0.2)
                z: 10

                Label {
                    id: pinLabel
                    x: Theme.horizontalPageMargin
                    width: parent.width - 2*x
                    anchors.verticalCenter: parent.verticalCenter
                    text: pinnedBar.pinnedMsg
                          ? "\ud83d\udccc " + mentionsToNames(pinnedBar.pinnedMsg.text || ("[" + (pinnedBar.pinnedMsg.mediaType || "media") + "]"))
                          : ""
                    font.pixelSize: Theme.fontSizeSmall
                    elide: Text.ElideRight
                    maximumLineCount: 1
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: if (pinnedBar.pinnedMsg) scrollToMsg(pinnedBar.pinnedMsg.id)
                }
            }
        }
    }

    Component {
        id: forwardPage
        Page {
            property string forwardId: ""
            SilicaListView {
                anchors.fill: parent
                header: PageHeader { title: "Forward to\u2026" }
                model: chats.filter(function(c) { return c.jid !== "status" && !c.isChannel })
                delegate: ListItem {
                    Label {
                        x: Theme.horizontalPageMargin
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.name || ("+" + modelData.jid)
                    }
                    onClicked: {
                        var xhr = new XMLHttpRequest()
                        xhr.open("GET", "http://127.0.0.1:" + backendPort + "/msg/forward?to=" + modelData.jid
                                 + "&id=" + encodeURIComponent(forwardId))
                        xhr.onreadystatechange = function() {
                            if (xhr.readyState === 4) {
                                globalNotice = xhr.status === 200 ? "Forwarded" : ("Forward failed: " + xhr.responseText)
                                pageStack.pop()
                            }
                        }
                        xhr.send()
                    }
                }
                VerticalScrollDecorator {}
            }
        }
    }

    Component {
        id: disappearingDialog
        Dialog {
            property string chatJid: ""
            property int chosen: -1
            Column {
                width: parent.width
                spacing: Theme.paddingMedium
                DialogHeader { title: "Disappearing messages" }
                ComboBox {
                    id: ephemeralCombo
                    label: "Timer"
                    menu: ContextMenu {
                        MenuItem { text: "Off" }
                        MenuItem { text: "24 hours" }
                        MenuItem { text: "7 days" }
                        MenuItem { text: "90 days" }
                    }
                }
                Label {
                    x: Theme.horizontalPageMargin
                    width: parent.width - 2*x
                    wrapMode: Text.Wrap
                    font.pixelSize: Theme.fontSizeExtraSmall
                    color: Theme.secondaryColor
                    text: "New messages in this chat will disappear after the selected time, for everyone."
                }
            }
            onDone: {
                if (result === DialogResult.Accepted) {
                    var secs = [0, 86400, 604800, 7776000][ephemeralCombo.currentIndex]
                    var xhr = new XMLHttpRequest()
                    xhr.open("GET", "http://127.0.0.1:" + backendPort + "/chat/disappearing?jid=" + chatJid + "&seconds=" + secs)
                    xhr.send()
                }
            }
        }
    }

    Component {
        id: groupDescDialog
        Dialog {
            property string descText: descArea.text
            Column {
                width: parent.width
                DialogHeader { title: "Group description" }
                TextArea {
                    id: descArea
                    width: parent.width
                    placeholderText: "Description"
                }
            }
        }
    }

    Component {
        id: joinRequestsPage
        Page {
            property string groupJid: ""
            property var requests: []
            property string reqStatus: ""

            function loadRequests() {
                var xhr = new XMLHttpRequest()
                xhr.open("GET", "http://127.0.0.1:" + backendPort + "/group/requests?jid=" + groupJid)
                xhr.onreadystatechange = function() {
                    if (xhr.readyState === 4) {
                        if (xhr.status === 200) {
                            requests = JSON.parse(xhr.responseText) || []
                            reqStatus = requests.length === 0 ? "No pending requests" : ""
                        } else {
                            reqStatus = xhr.responseText
                        }
                    }
                }
                xhr.send()
            }
            function decide(number, action) {
                var xhr = new XMLHttpRequest()
                xhr.open("GET", "http://127.0.0.1:" + backendPort + "/group/requests/update?jid=" + groupJid
                         + "&numbers=" + number + "&action=" + action)
                xhr.onreadystatechange = function() {
                    if (xhr.readyState === 4) loadRequests()
                }
                xhr.send()
            }
            Component.onCompleted: loadRequests()

            SilicaListView {
                anchors.fill: parent
                header: Column {
                    width: parent.width
                    PageHeader { title: "Join requests" }
                    Label {
                        visible: reqStatus !== ""
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*x
                        text: reqStatus
                        wrapMode: Text.Wrap
                        color: Theme.secondaryColor
                    }
                }
                model: requests
                delegate: ListItem {
                    contentHeight: Theme.itemSizeMedium
                    Column {
                        x: Theme.horizontalPageMargin
                        anchors.verticalCenter: parent.verticalCenter
                        Label { text: (modelData.name || "") !== "" ? modelData.name : ("+" + modelData.number) }
                        Label {
                            text: "+" + modelData.number
                            visible: (modelData.name || "") !== ""
                            font.pixelSize: Theme.fontSizeExtraSmall
                            color: Theme.secondaryColor
                        }
                    }
                    menu: ContextMenu {
                        MenuItem { text: "Approve"; onClicked: decide(modelData.number, "approve") }
                        MenuItem { text: "Reject";  onClicked: decide(modelData.number, "reject") }
                    }
                }
                VerticalScrollDecorator {}
            }
        }
    }

    Component {
        id: locationDialog
        Dialog {
            id: locDlg
            property string lat: latField.text
            property string lon: lonField.text
            property string locName: nameField.text
            canAccept: latField.text !== "" && lonField.text !== ""

            PositionSource {
                id: posSrc
                active: true
                updateInterval: 2000
                onPositionChanged: {
                    if (position.latitudeValid && position.longitudeValid) {
                        latField.text = position.coordinate.latitude.toFixed(6)
                        lonField.text = position.coordinate.longitude.toFixed(6)
                        gpsHint.text = "Position from GPS (\u00b1" +
                            (position.horizontalAccuracyValid ? Math.round(position.horizontalAccuracy) + " m)" : "?)")
                    }
                }
            }

            Column {
                width: parent.width
                spacing: Theme.paddingMedium
                DialogHeader { title: "Send location" }
                Label {
                    id: gpsHint
                    x: Theme.horizontalPageMargin
                    width: parent.width - 2*x
                    text: posSrc.valid ? "Waiting for GPS fix\u2026 (or enter manually)"
                                       : "No positioning available - enter coordinates manually. Grant the Location permission in Settings if GPS should work."
                    wrapMode: Text.Wrap
                    font.pixelSize: Theme.fontSizeExtraSmall
                    color: Theme.secondaryColor
                }
                TextField {
                    id: latField
                    width: parent.width
                    label: "Latitude"
                    placeholderText: "48.2082"
                    inputMethodHints: Qt.ImhFormattedNumbersOnly
                }
                TextField {
                    id: lonField
                    width: parent.width
                    label: "Longitude"
                    placeholderText: "16.3738"
                    inputMethodHints: Qt.ImhFormattedNumbersOnly
                }
                TextField {
                    id: nameField
                    width: parent.width
                    label: "Label (optional)"
                    placeholderText: "e.g. Meeting point"
                }
            }
        }
    }

    Component {
        id: liveDurationDialog
        Dialog {
            property int durationIndex: durCombo.currentIndex
            Column {
                width: parent.width
                spacing: Theme.paddingMedium
                DialogHeader { title: "Share live location" }
                ComboBox {
                    id: durCombo
                    label: "Duration"
                    menu: ContextMenu {
                        MenuItem { text: "15 minutes" }
                        MenuItem { text: "1 hour" }
                        MenuItem { text: "8 hours" }
                    }
                }
                Label {
                    x: Theme.horizontalPageMargin
                    width: parent.width - 2*x
                    wrapMode: Text.Wrap
                    font.pixelSize: Theme.fontSizeExtraSmall
                    color: Theme.secondaryColor
                    text: "Your position is sent every ~20 s while the app keeps running (background/cover is fine, like Pure Maps). Closing the app ends the share. Requires the Location permission (see Settings)."
                }
            }
        }
    }
}
