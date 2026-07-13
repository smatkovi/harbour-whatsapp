import QtQuick 2.0
import Sailfish.Silica 1.0
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
                    console.log("Backend ready on port " + backendPort)
                    checkStatus()
                    loadPrefs()
                } else {
                    console.log("Backend failed to start")
                    pairErrorMsg = "Backend failed to start. Please check " +
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

    Loader {
        id: peopleLoader
        active: contactsOptIn
        sourceComponent: PeopleModel {
            filterType: PeopleModel.FilterAll
            requiredProperty: PeopleModel.PhoneNumberRequired
        }
    }

    function loadPrefs() {
        var xhr = new XMLHttpRequest()
        xhr.open("GET", "http://127.0.0.1:" + backendPort + "/prefs")
        xhr.onreadystatechange = function() {
            if (xhr.readyState === 4 && xhr.status === 200) {
                var p = JSON.parse(xhr.responseText) || {}
                contactsOptIn = p.contactSuggestions === "1"
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


    function checkStatus() {
        var xhr = new XMLHttpRequest()
        xhr.open("GET", "http://127.0.0.1:" + backendPort + "/status")
        xhr.onreadystatechange = function() {
            if (xhr.readyState === 4 && xhr.status === 200) {
                var data = JSON.parse(xhr.responseText)
                var wasConnected = connected
                connected = data.connected
                pairCode = data.pairCode || ""
                phone = data.phone || ""
                connState = data.state || ""
                lastError = data.lastError || ""
                paired = data.paired === true
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

        SilicaListView {
            anchors.fill: parent
            model: connected ? chats : null

            PullDownMenu {
                MenuItem {
                    text: "Logout"
                    visible: connected
                    onClicked: logoutRemorse.execute("Logging out", doLogout)
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

                Column {
                    visible: !connected && !paired
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
                                        pairErrorMsg = "Pairing failed (" + xhr.status + "): " + xhr.responseText
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

                    SectionHeader { text: "Sailjail permissions" }

                    Label {
                        id: permStatus
                        property bool granted: false
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*x
                        text: granted
                              ? "Contacts permission: granted (remove it below if unwanted)"
                              : "Contacts permission: not granted - suggestions stay empty until you grant it below and restart the app"
                        color: granted ? Theme.highlightColor : Theme.secondaryHighlightColor
                        font.pixelSize: Theme.fontSizeSmall
                        wrapMode: Text.Wrap

                        Component.onCompleted: {
                            var xhr = new XMLHttpRequest()
                            xhr.open("GET", "http://127.0.0.1:" + backendPort + "/permcheck")
                            xhr.onreadystatechange = function() {
                                if (xhr.readyState === 4 && xhr.status === 200) {
                                    granted = JSON.parse(xhr.responseText).contactsPermission === true
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
                            + "The app therefore ships WITHOUT the Contacts permission. "
                            + "To grant or revoke it, tap a command below to copy it, then "
                            + "run it in Terminal and restart the app. Updates will not "
                            + "overwrite your choice."
                        font.pixelSize: Theme.fontSizeExtraSmall
                        color: Theme.secondaryColor
                        wrapMode: Text.Wrap
                    }

                    BackgroundItem {
                        width: parent.width
                        height: grantLabel.height + 2*Theme.paddingMedium
                        onClicked: {
                            Clipboard.text = "devel-su sh -c \"grep -q 'Contacts;' /usr/share/applications/harbour-whatsapp.desktop || sed -i '/^Permissions=/s/Permissions=/Permissions=Contacts;Privileged;/' /usr/share/applications/harbour-whatsapp.desktop\""
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
                            Clipboard.text = "devel-su sed -i 's/Contacts;Privileged;//' /usr/share/applications/harbour-whatsapp.desktop"
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
                            contentHeight: Theme.itemSizeSmall
                            menu: ContextMenu {
                                MenuItem {
                                    text: "Remove from group"
                                    onClicked: groupCall("/group/participants?chat=" + giPage.groupJid + "&action=remove&numbers=" + modelData.number)
                                }
                            }
                            Label {
                                x: Theme.horizontalPageMargin
                                anchors.verticalCenter: parent.verticalCenter
                                text: (getDisplayName(modelData.number, modelData.name))
                                      + (modelData.isAdmin ? " · admin" : "")
                            }
                        }
                    }
                }
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
                var xhr = new XMLHttpRequest()
                xhr.open("GET", "http://127.0.0.1:" + backendPort + "/group/create?name="
                         + encodeURIComponent(ngNameText) + "&participants=" + nums.join(","))
                xhr.onreadystatechange = function() {
                    if (xhr.readyState === 4) loadChats()
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
                    url = "http://127.0.0.1:" + backendPort + "/send?to=" + chatJid
                        + "&text=" + encodeURIComponent(input.text)
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

                property string downloadingId: ""
                property string downloadError: ""
                property string lastDownloadFailId: ""

                function downloadMediaFor(msgId) {
                    if (downloadingId !== "") return
                    downloadingId = msgId
                    downloadError = ""
                    var xhr = new XMLHttpRequest()
                    xhr.open("GET", "http://127.0.0.1:" + backendPort + "/download?id=" + encodeURIComponent(msgId))
                    xhr.onreadystatechange = function() {
                        if (xhr.readyState === 4) {
                            downloadingId = ""
                            if (xhr.status === 200) {
                                load()
                            } else {
                                downloadError = xhr.responseText
                                lastDownloadFailId = msgId
                            }
                        }
                    }
                    xhr.send()
                }

                delegate: ListItem {
                    width: parent.width
                    contentHeight: msgContent.height + Theme.paddingSmall
                    highlighted: down || menuOpen || modelData.id === highlightMsgId
                    
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
                            visible: modelData.localPath && modelData.localPath !== ""
                            onClicked: Qt.openUrlExternally("file://" + modelData.localPath)
                        }
                        MenuItem {
                            text: "Copy text"
                            visible: modelData.text && modelData.text !== ""
                            onClicked: Clipboard.text = modelData.text
                        }
                    }

                    Column {
                        id: msgContent
                        width: parent.width * 0.8
                        anchors.right: modelData.fromMe ? parent.right : undefined
                        anchors.left: modelData.fromMe ? undefined : parent.left
                        anchors.margins: Theme.horizontalPageMargin
                        spacing: Theme.paddingSmall

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
                            visible: modelData.text && modelData.text !== ""
                            width: Math.min(msgTxt.implicitWidth + Theme.paddingLarge * 2, parent.width)
                            height: visible ? msgTxt.height + Theme.paddingMedium * 2 : 0
                            color: modelData.fromMe ? Theme.highlightBackgroundColor : Theme.rgba(Theme.primaryColor, 0.1)
                            radius: Theme.paddingMedium

                            Label {
                                id: msgTxt
                                anchors.centerIn: parent
                                width: parent.width - Theme.paddingLarge * 2
                                text: modelData.text
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
                    }

                    IconButton {
                        id: sendBtn
                        icon.source: "image://theme/icon-m-send"
                        onClicked: send()
                    }
                }
            }

            PageHeader { title: chatName }
        }
    }
}
