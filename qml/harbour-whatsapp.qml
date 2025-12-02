import QtQuick 2.0
import Sailfish.Silica 1.0
import Sailfish.Pickers 1.0
import org.nemomobile.contacts 1.0
import Nemo.DBus 2.0

ApplicationWindow {
    id: app
    initialPage: mainPage
    cover: undefined

    property bool connected: false
    property string pairCode: ""
    property string phone: ""
    property var chats: []
    property var waContacts: []

    // Systemd D-Bus interface to start backend
    DBusInterface {
        id: systemd
        bus: DBus.SessionBus
        service: "org.freedesktop.systemd1"
        path: "/org/freedesktop/systemd1"
        iface: "org.freedesktop.systemd1.Manager"
    }
    
    function ensureBackend() {
        systemd.call("StartUnit", ["harbour-whatsapp-backend.service", "replace"])
    }
    
    // Sailfish Contacts
    PeopleModel {
        id: peopleModel
        filterType: PeopleModel.FilterAll
        requiredProperty: PeopleModel.PhoneNumberRequired
    }
    
    // Find contact name from Sailfish contacts by phone number
    function findLocalContactName(phoneNumber) {
        if (!phoneNumber) return ""
        // Normalize: remove +, spaces, dashes
        var normalized = phoneNumber.replace(/[\s\-\+]/g, '').replace(/^0+/, '')
        
        for (var i = 0; i < peopleModel.count; i++) {
            var person = peopleModel.get(i)
            if (person && person.phoneDetails) {
                for (var j = 0; j < person.phoneDetails.length; j++) {
                    var pn = person.phoneDetails[j].normalizedNumber || person.phoneDetails[j].number
                    pn = pn.replace(/[\s\-\+]/g, '').replace(/^0+/, '')
                    if (pn === normalized || pn.endsWith(normalized) || normalized.endsWith(pn)) {
                        return person.displayLabel || ""
                    }
                }
            }
        }
        return ""
    }
    
    // Get display name: prefer local contact, then WhatsApp name, then number
    function getDisplayName(jid, waName) {
        var localName = findLocalContactName(jid)
        if (localName) return localName
        if (waName) return waName
        return "+" + jid
    }


    function checkStatus() {
        var xhr = new XMLHttpRequest()
        xhr.open("GET", "http://localhost:8085/status")
        xhr.onreadystatechange = function() {
            if (xhr.readyState === 4 && xhr.status === 200) {
                var data = JSON.parse(xhr.responseText)
                var wasConnected = connected
                connected = data.connected
                pairCode = data.pairCode || ""
                phone = data.phone || ""
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
        xhr.open("GET", "http://localhost:8085/chats")
        xhr.onreadystatechange = function() {
            if (xhr.readyState === 4 && xhr.status === 200) {
                chats = JSON.parse(xhr.responseText) || []
            }
        }
        xhr.send()
    }

    function loadWAContacts() {
        var xhr = new XMLHttpRequest()
        xhr.open("GET", "http://localhost:8085/contacts")
        xhr.onreadystatechange = function() {
            if (xhr.readyState === 4 && xhr.status === 200) {
                var data = JSON.parse(xhr.responseText) || {}
                var list = []
                for (var jid in data) {
                    list.push({ jid: jid, name: data[jid] })
                }
                list.sort(function(a, b) { return a.name.localeCompare(b.name) })
                waContacts = list
            }
        }
        xhr.send()
    }

    function doLogout() {
        var xhr = new XMLHttpRequest()
        xhr.open("GET", "http://localhost:8085/logout")
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

    Component.onCompleted: { ensureBackend(); checkStatus() }

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
                source: jid ? "http://localhost:8085/avatar/" + jid : ""
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
                        xhr.open("GET", "http://localhost:8085/reload")
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
                    description: connected ? "+" + phone : "Not connected"
                }

                Column {
                    visible: !connected
                    width: parent.width
                    spacing: Theme.paddingLarge

                    TextField {
                        id: phoneField
                        width: parent.width
                        label: "Phone number (with country code)"
                        placeholderText: "436766517141"
                        text: "436766517141"
                        inputMethodHints: Qt.ImhDigitsOnly
                    }

                    Button {
                        text: "Start pairing"
                        anchors.horizontalCenter: parent.horizontalCenter
                        onClicked: {
                            var xhr = new XMLHttpRequest()
                            xhr.open("GET", "http://localhost:8085/pair?phone=" + phoneField.text)
                            xhr.onreadystatechange = function() {
                                if (xhr.readyState === 4 && xhr.status === 200) {
                                    pairCode = JSON.parse(xhr.responseText).code
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
                    chatAvatar: modelData.avatar || ""
                })

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
                            text: getDisplayName(modelData.jid, modelData.name)
                            font.pixelSize: Theme.fontSizeMedium
                            truncationMode: TruncationMode.Fade
                            width: parent.width
                        }
                        Label {
                            text: modelData.lastMessage ? ((modelData.fromMe ? "You: " : "") + modelData.lastMessage) : ""
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.secondaryColor
                            truncationMode: TruncationMode.Fade
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
        id: newChatPage
        Page {
            property string searchText: ""

            function filteredContacts() {
                if (!waContacts) return []
                if (searchText === "") return waContacts
                var s = searchText.toLowerCase()
                var result = []
                for (var i = 0; i < waContacts.length; i++) {
                    var c = waContacts[i]
                    if (c.name.toLowerCase().indexOf(s) >= 0 || c.jid.indexOf(s) >= 0) {
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
                                    
                                    Label { text: modelData.name || "Unknown" }
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
                        visible: searchText === "" && waContacts.length === 0
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*x
                        text: "Enter a phone number with country code\n(e.g. 436641234567)\nto start a new conversation"
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

            function load() {
                var xhr = new XMLHttpRequest()
                xhr.open("GET", "http://localhost:8085/messages?jid=" + chatJid)
                xhr.onreadystatechange = function() {
                    if (xhr.readyState === 4 && xhr.status === 200) {
                        msgs = JSON.parse(xhr.responseText) || []
                    }
                }
                xhr.send()
            }

            function send() {
                if (input.text === "") return
                var xhr = new XMLHttpRequest()
                xhr.open("GET", "http://localhost:8085/send?to=" + chatJid + "&text=" + encodeURIComponent(input.text))
                xhr.onreadystatechange = function() {
                    if (xhr.readyState === 4 && xhr.status === 200) {
                        input.text = ""
                        load()
                        loadChats()
                    }
                }
                xhr.send()
            }

            function sendFile(path) {
                var xhr = new XMLHttpRequest()
                xhr.open("POST", "http://localhost:8085/sendmedia?to=" + chatJid + "&file=" + encodeURIComponent(path) + "&caption=")
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
                onCountChanged: positionViewAtEnd()
                Component.onCompleted: positionViewAtEnd()

                PullDownMenu {
                    MenuItem { text: "Send file"; onClicked: pageStack.push(filePicker) }
                    MenuItem { text: "Send image"; onClicked: pageStack.push(imagePicker) }
                    MenuItem { text: "Refresh"; onClicked: load() }
                }

                header: Item { height: Theme.paddingLarge }

                delegate: ListItem {
                    width: parent.width
                    contentHeight: msgContent.height + Theme.paddingSmall
                    
                    menu: ContextMenu {
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
                                    size: BusyIndicatorSize.Medium
                                }
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
                                    Label { text: formatSize(modelData.fileSize); font.pixelSize: Theme.fontSizeExtraSmall; color: Theme.secondaryColor }
                                }
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
                                Label { text: "Audio · " + formatSize(modelData.fileSize); font.pixelSize: Theme.fontSizeSmall; color: Theme.secondaryColor }
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
                                    Label { text: formatSize(modelData.fileSize); font.pixelSize: Theme.fontSizeExtraSmall; color: Theme.secondaryColor }
                                }
                            }
                        }

                        Image {
                            visible: modelData.mediaType === "sticker"
                            width: Theme.itemSizeLarge
                            height: width
                            fillMode: Image.PreserveAspectFit
                            source: modelData.localPath ? "file://" + modelData.localPath : ""
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
                            text: formatTime(modelData.timestamp)
                            font.pixelSize: Theme.fontSizeExtraSmall
                            color: Theme.secondaryColor
                            anchors.right: modelData.fromMe ? parent.right : undefined
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
