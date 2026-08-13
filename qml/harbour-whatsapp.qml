import QtQuick 2.0
import "translations.js" as TR
import QtMultimedia 5.6
import QtSensors 5.0
import Nemo.DBus 2.0
import Nemo.KeepAlive 1.2
import Nemo.Notifications 1.0
import Sailfish.Silica 1.0
import QtPositioning 5.2
import Sailfish.Pickers 1.0
import "js/twemoji.js" as Twemoji
import org.nemomobile.contacts 1.0
import io.thp.pyotherside 1.5

ApplicationWindow {
    id: app
    initialPage: archPageItem
    cover: undefined

    // Bisher war alles ausser den Vollbild-Ansichten fest im Hochformat.
    // Diese Vorgabe erben alle Seiten, die nichts eigenes setzen - die
    // drei Medien-Seiten (Avatar, Status, Video) bleiben bewusst bei
    // Orientation.All: ein Video quer anzusehen ist der Zweck der Sache,
    // auch wenn die Oberflaeche sonst fest stehen soll
    allowedOrientations: orientationMask()
    // Hinweis: allowedOrientations am Fenster ERLAUBT die Drehung nur -
    // jede Seite entscheidet fuer sich und steht ohne eigene Angabe auf
    // Hochformat. Deshalb traegt unten jede Page/Dialog-Komponente die
    // Maske ausdruecklich. Silicas interne _defaultPageOrientations waere
    // kuerzer, ist aber undokumentiert: fehlt sie in einer SFOS-Version,
    // startet die App gar nicht mehr
    property string orientationPref: "dynamic"
    function orientationMask() {
        if (orientationPref === "portrait") return Orientation.Portrait
        if (orientationPref === "landscape") return Orientation.Landscape
        return Orientation.All
    }

    property bool connected: false
    property string pairCode: ""
    property string pairErrorMsg: ""
    property string connState: ""
    property string lastError: ""
    // Spendenziele - leer lassen blendet den jeweiligen Knopf aus
    property string donatePaypalUrl: "https://www.paypal.me/smatkovi"
    property string donateLiberapayUrl: "https://liberapay.com/smatkovi"
    property bool paired: false
    property bool backendFailed: false

    onConnectedChanged: {
        if (mainPage) mainPage.updateAttachedStatus()
        if (connected) pollEvents()
    }

    // Long-Polling statt 2-Sekunden-Blindpoll: /events haengt im Backend,
    // bis etwas passiert. Nachrichten kommen sofort, bei Stille fliesst
    // nichts - weniger Akkulast trotz schnellerer Anzeige.
    property int evSeq: 0
    property int evBackoff: 1000
    property bool evPolling: false
    signal eventTick()

    function pollEvents() {
        if (evPolling || !connected) return
        evPolling = true
        var xhr = new XMLHttpRequest()
        xhr.open("GET", "http://127.0.0.1:" + backendPort + "/events?since=" + evSeq)
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== 4) return
            evPolling = false
            if (xhr.status === 200) {
                evBackoff = 1000
                try {
                    var s = JSON.parse(xhr.responseText).seq
                    if (s !== evSeq) {
                        evSeq = s
                        loadChats()
                        eventTick()
                    }
                } catch (e) {}
                pollEvents()
            } else {
                // Backend weg oder Neustart: mit Backoff wiederkommen
                evRetry.interval = evBackoff
                evBackoff = Math.min(evBackoff * 2, 15000)
                evRetry.start()
            }
        }
        xhr.send()
    }

    Timer {
        id: evRetry
        repeat: false
        onTriggered: pollEvents()
    }

    function retryBackend() {
        backendFailed = false
        pairErrorMsg = ""
        // call ist eine Methode des Python-Elements - unqualifiziert wirft
        // das auf Root-Ebene einen stillen ReferenceError und nichts startet
        python.call('start_backend.start', [])
    }
    property var waContactsMap: ({})
    property int backendPort: 8085
    // Zaehler laufender Medien-Uploads: solange > 0, gilt ein langsames
    // Backend als beschaeftigt, nicht als verloren
    property int uploadInFlight: 0
    property string phone: ""
    // Eigener Anzeigename und Avatar: im Kopf der Hauptseite stand bisher
    // die eigene Telefonnummer, die jeder mitlesen kann, dem man das Geraet
    // zeigt. Name und Bild sagen dasselbe aus, ohne die Nummer preiszugeben.
    // Wunsch von rdomschk.
    property string myName: ""
    property string myAvatar: ""
    function loadOwnProfile() {
        var x = new XMLHttpRequest()
        x.open("GET", "http://127.0.0.1:" + backendPort + "/profile")
        x.onreadystatechange = function() {
            if (x.readyState !== 4 || x.status !== 200) return
            try {
                var p = JSON.parse(x.responseText)
                myName = p.name || ""
                myAvatar = p.avatar || ""
            } catch (e) {}
        }
        x.send()
    }

    // Anzeigename der App. rdomschk hat ihn sich selbst gepatcht, weil der
    // Benachrichtigungszaehler im Fensterwechsler mit der offiziellen
    // WhatsApp-App kollidiert. Besser als ein Patch, den jedes Update
    // ueberschreibt: eine Einstellung.
    property string appDisplayName: "WhatsApp"
    property var chats: []
    property var waContacts: []

    // Python backend starter
    // Wurzelrechte aus der App heraus gehen NICHT: der Versuch mit pkexec
    // (Vorschlag von rdomschk) scheitert an der Sandbox mit
    // PermissionError(13) - nachgewiesen auf dem Geraet, obwohl pkexec,
    // polkitd und der Sailfish-Polkit-Agent alle laufen. Sein Beispiel
    // stammt aus einem Patchmanager-Patch, und Patches laufen ausserhalb
    // von Sailjail. Der Daemon hilft auch nicht: er wird selbst mit
    // sailjail gestartet, weil nur so die Secrets-Sammlung zugaenglich ist.
    // Es bleibt beim Befehl zum Kopieren.

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
                pythonReady = true
                call('start_backend.start', [])
                call('start_backend.installed_version', [], function(v) {
                    installedVersion = v || ""
                })
            })
            importWatchdog.start()
            reportTimer.start()
        }
        
        Component.onDestruction: {
            call('start_backend.stop', [])
        }
        
        onError: {
            console.log("Python error:", traceback)
            // Nicht sofort urteilen: fruehe Aufrufe koennen den async-Import
            // ueberholen (harmlose Race auf langsamen Geraeten). Der Waechter
            // zeigt den letzten Fehler, falls der Import wirklich scheitert.
            if (!pythonReady) lastPythonError = traceback
        }
    }

    property string lastPythonError: ""

    Component {
        id: languagePage
        Page {
            allowedOrientations: orientationMask()
            SilicaListView {
                anchors.fill: parent
                header: PageHeader { title: loc.language }
                model: TR.languages

                delegate: BackgroundItem {
                    width: ListView.view.width
                    height: Theme.itemSizeSmall
                    onClicked: {
                        appLanguage = modelData.code
                        setPref("app_language", modelData.code)
                        // Der Antworten-Knopf der Benachrichtigung wird im
                        // Go-Backend beschriftet - dorthin gibt es nur diesen
                        // Weg; der Katalog bleibt einzige Wahrheitsquelle
                        setPref("notif_reply_label", TR.catalog(modelData.code).reply)
                    }
                    Label {
                        x: Theme.horizontalPageMargin
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.name || loc[modelData.key]
                        color: (appLanguage === modelData.code)
                               ? Theme.highlightColor
                               : (highlighted ? Theme.highlightColor : Theme.primaryColor)
                    }
                }
            }
        }
    }

    Component {
        id: aboutAppPage
        Page {
            allowedOrientations: orientationMask()
            SilicaFlickable {
                anchors.fill: parent
                contentHeight: aboutCol.height + Theme.paddingLarge * 2

                Column {
                    id: aboutCol
                    width: parent.width
                    spacing: Theme.paddingMedium

                    PageHeader { title: loc.aboutApp }

                    Image {
                        anchors.horizontalCenter: parent.horizontalCenter
                        source: "/usr/share/icons/hicolor/128x128/apps/harbour-whatsapp.png"
                        width: Theme.iconSizeLauncher
                        height: Theme.iconSizeLauncher
                        smooth: true
                    }

                    Label {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "WhatsApp " + (backendVersion !== "" ? backendVersion : "")
                        font.pixelSize: Theme.fontSizeLarge
                        color: Theme.highlightColor
                    }

                    Label {
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2 * Theme.horizontalPageMargin
                        text: loc.aboutSubtitle
                        wrapMode: Text.Wrap
                        horizontalAlignment: Text.AlignHCenter
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.secondaryColor
                    }

                    Label {
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2 * Theme.horizontalPageMargin
                        text: loc.aboutDeveloper
                        wrapMode: Text.Wrap
                        horizontalAlignment: Text.AlignHCenter
                        font.pixelSize: Theme.fontSizeSmall
                    }

                    Item { width: 1; height: Theme.paddingMedium }

                    Button {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: loc.aboutSource
                        onClicked: Qt.openUrlExternally("https://github.com/smatkovi/harbour-whatsapp")
                    }

                    Button {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: loc.aboutIssues
                        onClicked: Qt.openUrlExternally("https://github.com/smatkovi/harbour-whatsapp/issues")
                    }

                    SectionHeader {
                        text: loc.aboutDonate
                        visible: donatePaypalUrl !== "" || donateLiberapayUrl !== ""
                    }

                    Button {
                        anchors.horizontalCenter: parent.horizontalCenter
                        visible: donatePaypalUrl !== ""
                        text: loc.aboutDonatePaypal
                        onClicked: Qt.openUrlExternally(donatePaypalUrl)
                    }

                    Button {
                        anchors.horizontalCenter: parent.horizontalCenter
                        visible: donateLiberapayUrl !== ""
                        text: loc.aboutDonateLiberapay
                        onClicked: Qt.openUrlExternally(donateLiberapayUrl)
                    }

                    Item { width: 1; height: Theme.paddingMedium }

                    Label {
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2 * Theme.horizontalPageMargin
                        text: loc.aboutThanks
                        wrapMode: Text.Wrap
                        font.pixelSize: Theme.fontSizeExtraSmall
                        color: Theme.secondaryColor
                    }

                    Label {
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2 * Theme.horizontalPageMargin
                        text: loc.aboutPowered
                        wrapMode: Text.Wrap
                        font.pixelSize: Theme.fontSizeExtraSmall
                        color: Theme.secondaryColor
                    }

                    Item { width: 1; height: Theme.paddingLarge }
                }
                VerticalScrollDecorator {}
            }
        }
    }

    Component {
        id: extraSettingsPage
        Page {
            allowedOrientations: orientationMask()
            SilicaFlickable {
                anchors.fill: parent
                contentHeight: extraCol.height

                Column {
                    id: extraCol
                    width: parent.width

                    PageHeader { title: loc.moreSettings }

                    ComboBox {
                        label: loc.tilesPerRow
                        description: loc.gridOnly
                        currentIndex: gridColumns - 2
                        menu: ContextMenu {
                            MenuItem { text: "2"; onClicked: { gridColumns = 2; setPref("grid_columns", "2") } }
                            MenuItem { text: "3"; onClicked: { gridColumns = 3; setPref("grid_columns", "3") } }
                            MenuItem { text: "4"; onClicked: { gridColumns = 4; setPref("grid_columns", "4") } }
                            MenuItem { text: "5"; onClicked: { gridColumns = 5; setPref("grid_columns", "5") } }
                            MenuItem { text: "6"; onClicked: { gridColumns = 6; setPref("grid_columns", "6") } }
                        }
                    }

                    Slider {
                        width: parent.width
                        label: loc.tileSpacing
                        minimumValue: 0
                        maximumValue: 30
                        stepSize: 1
                        value: tileGap
                        valueText: value
                        onSliderValueChanged: {
                            tileGap = value
                            setPref("tile_gap", String(value))
                        }
                    }

                    TextField {
                        id: appNameField
                        width: parent.width
                        label: loc.appNameSetting
                        placeholderText: "WhatsApp"
                        text: appDisplayName
                        description: loc.appNameSettingDesc
                        EnterKey.iconSource: "image://theme/icon-m-enter-accept"
                        EnterKey.onClicked: focus = false
                        onActiveFocusChanged: {
                            if (activeFocus || !prefsLoaded) return
                            var v = text.trim() === "" ? "WhatsApp" : text.trim()
                            if (appDisplayName !== v) {
                                appDisplayName = v
                                setPref("app_name", v)
                            }
                        }
                    }

                    // Der Name unter dem Startsymbol steht in der
                    // Desktop-Datei und wird gelesen, bevor die App laeuft -
                    // aendern kann ihn nur root. Die Datei ist aber
                    // %config(noreplace) und %post fasst Name= nicht an,
                    // deshalb ueberlebt die Aenderung jedes Update.
                    BackgroundItem {
                        width: parent.width
                        height: renameCmdLabel.height + 2*Theme.paddingMedium
                        onClicked: {
                            var n = appNameField.text.trim()
                            if (n === "") n = "WhatsSail"
                            Clipboard.text = "devel-su sed -i 's/^Name=.*/Name=" + n
                                             + "/' /usr/share/applications/harbour-whatsapp.desktop"
                            renameHint.text = loc.commandCopied
                        }
                        Label {
                            id: renameCmdLabel
                            x: Theme.horizontalPageMargin
                            width: parent.width - 2*x
                            wrapMode: Text.Wrap
                            anchors.verticalCenter: parent.verticalCenter
                            text: "\u25b8 " + loc.copyRenameCmd
                            color: Theme.highlightColor
                            font.pixelSize: Theme.fontSizeSmall
                        }
                    }


                    Label {
                        id: renameHint
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*x
                        text: ""
                        visible: text !== ""
                        wrapMode: Text.Wrap
                        color: Theme.highlightColor
                        font.pixelSize: Theme.fontSizeExtraSmall
                    }

                    Label {
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*x
                        wrapMode: Text.Wrap
                        font.pixelSize: Theme.fontSizeExtraSmall
                        color: Theme.secondaryColor
                        text: loc.renameIconHint
                    }

                    TextSwitch {
                        text: loc.hideOnline
                        description: loc.hideOnlineDesc
                        checked: hideOnline
                        onClicked: {
                            hideOnline = checked
                            setPref("hide_online", checked ? "1" : "0")
                            globalNotice = loc.hideOnlineRestart
                        }
                    }

                    TextSwitch {
                        text: loc.statusByPerson
                        description: loc.statusByPersonDesc
                        checked: statusByPerson
                        onClicked: {
                            statusByPerson = checked
                            setPref("status_by_person", checked ? "1" : "0")
                        }
                    }

                    TextSwitch {
                        text: loc.statusGrouping
                        description: loc.statusGroupingDesc
                        checked: statusGrouping
                        onClicked: {
                            statusGrouping = checked
                            setPref("status_grouping", checked ? "1" : "0")
                        }
                    }

                    ComboBox {
                        id: navBarBox
                        width: parent.width
                        label: loc.navBarSize
                        description: loc.navBarSizeDesc
                        property bool synced: false
                        function syncFromPrefs() {
                            currentIndex = navBarSize === "small" ? 0
                                         : (navBarSize === "medium" ? 1 : 2)
                            synced = true
                        }
                        Component.onCompleted: syncFromPrefs()
                        onCurrentIndexChanged: {
                            // Erst nach dem Abgleich schreiben - sonst setzt
                            // schon das Oeffnen der Seite den Wert auf den
                            // ersten Eintrag der Liste
                            if (!prefsLoaded || !synced) return
                            var v = currentIndex === 0 ? "small"
                                  : (currentIndex === 1 ? "medium" : "large")
                            if (navBarSize !== v) {
                                navBarSize = v
                                setPref("navbar_size", v)
                            }
                        }
                        menu: ContextMenu {
                            MenuItem { text: loc.navBarSmall }
                            MenuItem { text: loc.navBarMedium }
                            MenuItem { text: loc.navBarLarge }
                        }
                    }

                    TextSwitch {
                        text: loc.forwardStay
                        description: loc.forwardStayDesc
                        checked: forwardStay
                        onClicked: {
                            forwardStay = checked
                            setPref("forward_stay", checked ? "1" : "0")
                        }
                    }

                    TextSwitch {
                        text: loc.lineMode
                        description: loc.lineModeDesc
                        checked: lineMode
                        onClicked: {
                            lineMode = checked
                            setPref("line_mode", checked ? "1" : "0")
                        }

                    }

                    TextSwitch {
                        text: loc.colorEmoji
                        description: loc.colorEmojiDesc
                        checked: emojiEnabled
                        onClicked: {
                            emojiEnabled = checked
                            setPref("emoji", checked ? "1" : "0")
                        }
                    }

                    ComboBox {
                        id: orientationBox
                        width: parent.width
                        label: loc.orientation
                        description: loc.orientationDesc
                        function syncFromPrefs() {
                            currentIndex = orientationPref === "portrait" ? 1
                                         : (orientationPref === "landscape" ? 2 : 0)
                        }
                        property bool synced: false
                        Component.onCompleted: { syncFromPrefs(); synced = true }
                        onCurrentIndexChanged: {
                            if (!prefsLoaded || !synced) return
                            var v = currentIndex === 1 ? "portrait"
                                  : (currentIndex === 2 ? "landscape" : "dynamic")
                            if (orientationPref !== v) {
                                orientationPref = v
                                setPref("orientation", v)
                            }
                        }
                        menu: ContextMenu {
                            MenuItem { text: loc.orientationDynamic }
                            MenuItem { text: loc.orientationPortrait }
                            MenuItem { text: loc.orientationLandscape }
                        }
                    }

                    ComboBox {
                        id: attachBox
                        width: parent.width
                        label: loc.attachPicker
                        description: loc.attachPickerDesc
                        // Kein Binding auf currentIndex: Silicas ComboBox
                        // weist ihn intern imperativ zu (s. Auto-Download-
                        // Boxen) - deshalb synchron setzen, sobald die
                        // Prefs da sind
                        function syncFromPrefs() {
                            currentIndex = attachPicker === "content" ? 1
                                         : (attachPicker === "file" ? 2 : 0)
                        }
                        property bool synced: false
                        Component.onCompleted: { syncFromPrefs(); synced = true }
                        onCurrentIndexChanged: {
                            if (!prefsLoaded || !synced) return
                            var v = currentIndex === 1 ? "content"
                                  : (currentIndex === 2 ? "file" : "ask")
                            if (attachPicker !== v) {
                                attachPicker = v
                                setPref("attach_picker", v)
                            }
                        }
                        menu: ContextMenu {
                            MenuItem { text: loc.attachPickerAsk }
                            MenuItem { text: loc.attachPickerContent }
                            MenuItem { text: loc.attachPickerFile }
                        }
                    }

                    TextSwitch {
                        text: loc.topSwitcher
                        description: loc.topSwitcherDesc
                        checked: showViewSwitcher
                        automaticCheck: false
                        onClicked: {
                            showViewSwitcher = !showViewSwitcher
                            setPref("top_switcher", showViewSwitcher ? "1" : "0")
                        }
                    }

                    TextSwitch {
                        text: loc.bottomBar
                        description: loc.bottomBarDesc
                        checked: showNavBar
                        automaticCheck: false
                        onClicked: {
                            showNavBar = !showNavBar
                            setPref("bottom_bar", showNavBar ? "1" : "0")
                        }
                    }

                    TextSwitch {
                        text: loc.chatGrid
                        description: loc.chatGridDesc
                        checked: chatGridView
                        automaticCheck: false
                        onClicked: {
                            // KEIN downloadPrefs hier: das gehoert der
                            // Haupt-Settings-Seite - von dieser Root-Ebene
                            // aus warf der Zugriff einen stillen
                            // ReferenceError NACH dem visuellen Umschalten
                            // und VOR setPref: Grid an, Save nie gesendet
                            chatGridView = !chatGridView
                            setPref("chat_grid", chatGridView ? "1" : "0")
                        }
                    }
                }
            }
        }
    }

    property bool pythonReady: false

    Timer {
        id: importWatchdog
        interval: 6000
        repeat: false
        onTriggered: {
            if (!pythonReady && pairErrorMsg === "") {
                backendFailed = true
                pairErrorMsg = lastPythonError !== ""
                    ? ("Python module failed to load:\n" + lastPythonError
                       + "\nPlease report this text.")
                    : ("Python module start_backend did not load "
                       + "(no error reported). Check that "
                       + "/usr/share/harbour-whatsapp/start_backend.py "
                       + "exists and report your Sailfish OS version.")
            }
        }
    }


    
    
    // Sailfish Contacts: nur instanziiert, wenn der Opt-in aktiv ist -
    // ohne Einstellung wird die Kontaktdatenbank nie angefasst
    property bool contactsOptIn: false
    property bool notificationsEnabled: false
    property bool sendByEnter: false
    property bool chatGridView: false
    property int gridColumns: 3
    // Kachelabstand in Halb-paddingSmall-Schritten; 1 = bisheriges Aussehen
    property int tileGap: 1
    property bool showViewSwitcher: true
    property string appLanguage: ""
    readonly property string langCode: appLanguage !== "" ? appLanguage
                                       : Qt.locale().name.substring(0, 2)
    property var loc: TR.catalog(langCode)
    property bool showNavBar: true

    // Tippen auf eine Benachrichtigung: lipstick ruft openChat(jid) am
    // kanonischen Busnamen (harbour.harbour-whatsapp) - laeuft die App
    // nicht, startet sailjaild sie via ExecDBus und der Aufruf kommt
    // nach dem Start hier an
    DBusAdaptor {
        service: "harbour.harbour-whatsapp"
        path: "/"
        iface: "harbour.whatsapp.Gui"
        function openChat(jid) {
            openChatExternal(jid)
        }
        function replyFromNotification(jid, text) {
            // lipstick haengt den getippten Text als zweites Argument an;
            // Senden ueber /send (identisches Local-Echo), /chat/opened
            // schliesst die Benachrichtigung und markiert gelesen
            if (!text) return
            var xhr = new XMLHttpRequest()
            xhr.open("GET", "http://127.0.0.1:" + backendPort + "/send?to=" + jid
                     + "&text=" + encodeURIComponent(text))
            xhr.onreadystatechange = function() {
                if (xhr.readyState !== 4) return
                var c = new XMLHttpRequest()
                c.open("GET", "http://127.0.0.1:" + backendPort + "/chat/opened?jid=" + jid)
                c.send()
            }
            xhr.send()
        }
    }

    // Ansichts-Umschalter fuer beide Header: Liste oder Grid mit 2/3/4
    // Spalten - Glyphen statt Theme-Icons (Icon-Namen variieren zwischen
    // OS-Versionen; ein unsichtbarer Knopf waere der naechste Feldbericht)
    Component {
        id: viewSwitcherComp
        Row {
            height: Theme.itemSizeExtraSmall
            // Kompakt in der MITTE: links wohnt der Favorites-Indikator,
            // rechts der Status-Glow - rechtsbuendig war genauso falsch
            // wie zu breit zentriert; schmale Knoepfe ruecken von beiden ab
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.paddingMedium

            // Unsichtbarer Platzhalter links: schiebt die echte Gruppe aus
            // der Favorites-Wischzone, ohne "4" an den Status-Rand zu
            // druecken (die Mitte wandert nur um die halbe Breite)
            Item {
                width: Theme.itemSizeExtraSmall
                height: 1
            }

            Repeater {
                model: [
                    { glyph: "\u2630", grid: false, cols: 0 },
                    { glyph: "2", grid: true, cols: 2 },
                    { glyph: "3", grid: true, cols: 3 },
                    { glyph: "4", grid: true, cols: 4 },
                    { glyph: "5", grid: true, cols: 5 },
                    { glyph: "6", grid: true, cols: 6 }
                ]
                delegate: BackgroundItem {
                    width: Theme.itemSizeExtraSmall
                    height: Theme.itemSizeExtraSmall
                    onClicked: {
                        if (modelData.grid) {
                            gridColumns = modelData.cols
                            setPref("grid_columns", "" + modelData.cols)
                            if (!chatGridView) {
                                chatGridView = true
                                setPref("chat_grid", "1")
                            }
                        } else if (chatGridView) {
                            chatGridView = false
                            setPref("chat_grid", "0")
                        }
                    }
                    Label {
                        anchors.centerIn: parent
                        text: modelData.glyph
                        font.pixelSize: Theme.fontSizeMedium
                        color: (modelData.grid
                                ? (chatGridView && gridColumns === modelData.cols)
                                : !chatGridView)
                               ? Theme.highlightColor : Theme.secondaryColor
                    }
                }
            }
        }
    }

    // Backend-Sentinels bei der Anzeige uebersetzen (das Backend kennt
    // die UI-Sprache nicht; der gespeicherte Text bleibt englisch)
    function locMsg(t) {
        if (t === "\ud83d\udeab This message was deleted")
            return "\ud83d\udeab " + loc.messageDeleted
        return t
    }

    function chatSettingFor(jid, action) {
        var xhr = new XMLHttpRequest()
        xhr.open("GET", "http://127.0.0.1:" + backendPort + "/chatsetting?chat=" + jid + "&action=" + action)
        xhr.onreadystatechange = function() {
            if (xhr.readyState === 4) loadChats()
        }
        xhr.send()
    }

    function openChatExternal(jid) {
        var name = jid
        var avatar = ""
        var channel = false
        for (var i = 0; i < chats.length; i++) {
            if (chats[i].jid === jid) {
                name = getDisplayName(jid, chats[i].name)
                avatar = chats[i].avatar || ""
                channel = chats[i].isChannel === true
                break
            }
        }
        // Bis zur Chatliste poppen (nicht null) - sonst landet der
        // Zurueck-Pfeil auf der untersten Stackseite, die nach einem
        // Bodenleisten-Sprung Favoriten/Archiv sein kann statt Chats
        pageStack.pop(mainPage, PageStackAction.Immediate)
        pageStack.push(chatPage, {
            chatJid: jid,
            chatName: name,
            chatAvatar: avatar,
            isChannel: channel
        }, PageStackAction.Immediate)
        activate()
    }
    property var  prevUnread: ({})
    property bool prevUnreadInit: false

    Notification {
        id: msgNotification
        appName: appDisplayName
        appIcon: "harbour-whatsapp"
        category: "x-nemo.messaging.im"
    }
    property string globalNotice: ""

    // Fehler sollen rot erscheinen. Bisher wurde dafuer auf das englische
    // Wort "failed" IM TEXT geprueft - mit uebersetzten Meldungen traegt
    // das nicht mehr. Jede neue Meldung startet neutral, Fehlerpfade setzen
    // das Flag direkt NACH dem Text (Reihenfolge zaehlt).
    property bool noticeIsError: false
    onGlobalNoticeChanged: noticeIsError = false

    // Rot faerben und "antippen zum Kopieren" anbieten: neues Flag ODER
    // die alte englische Heuristik, damit noch nicht umgestellte Meldungen
    // weiter als Fehler erkennbar bleiben
    function noticeLooksLikeError() {
        return noticeIsError || globalNotice.indexOf("failed") >= 0
    }

    // WhatsApp quittiert eine abgelehnte Nachricht mit einem Fehlercode im
    // <ack>; whatsmeow reicht ihn als "server returned error NNN" durch.
    // Die 4xx-Familie heisst: der Server hat die Nachricht ANGENOMMEN und
    // dann verworfen - kein Fehler im Client. Bei Erstkontakten ist das
    // typischerweise eine voruebergehende Kontobeschraenkung.
    function sendRejectCode(body) {
        var m = (body || "").match(/server returned error (\d+)/)
        if (!m) return 0
        var c = parseInt(m[1], 10)
        return (c >= 400 && c < 500) ? c : 0
    }

    function sendErrorText(status, body) {
        var code = sendRejectCode(body)
        if (code > 0) return loc.sendRejected.replace("%1", code)
        // Sandbox statt Serverfehler: das Backend darf ausserhalb seines
        // Datenordners nichts lesen, solange die Speicher-Berechtigung
        // fehlt. Der rohe "permission denied"-Text schickt die Leute auf
        // die falsche Faehrte (Dateirechte statt Sailjail)
        if ((body || "").indexOf("permission denied") >= 0) {
            var pd = (body || "").replace(/\s+$/, "")
            if (pd.length > 160) pd = pd.substring(0, 160) + "\u2026"
            // Erteilt, aber der laufende Prozess traegt noch das alte
            // Profil - sailjail wendet es beim START an. Ein App-Neustart
            // allein reicht nicht, wenn der Daemon die Datei oeffnet
            var head
            if (!mediaPermConfigured && mediaPermMissing !== ""
                    && mediaPermMissing.split(", ").length < 3) {
                // Teil-Grant: benennen, was fehlt, und sagen dass der
                // Befehl gefahrlos erneut laufen darf (er haengt nur
                // Fehlendes an)
                head = loc.sendPermissionPartial.replace("%1", mediaPermMissing)
            } else if (mediaPermConfigured && !mediaPermEffective) {
                // Wer keinen Daemon hat, dessen Backend ist Kind der App und
                // erbt deren Jail - ein App-Neustart genuegt dann wirklich
                head = daemonRunning ? loc.sendPermissionInactiveDaemon
                                     : loc.sendPermissionInactiveApp
            } else {
                head = loc.sendPermissionDenied
            }
            return head + "\n" + pd
        }
        var why = (body || "").replace(/\s+$/, "")
        if (why.length > 200) why = why.substring(0, 200) + "\u2026"
        return loc.sendFailed.replace("%1", status)
               + ": " + (why !== "" ? why : loc.sendNoBackendReply)
    }

    // ---- Live-Standort-Freigabe (app-weit, ueberlebt Seitenwechsel) ----
    property bool   daemonRunning: false
    property string backendVersion: ""
    property string installedVersion: ""
    property bool daemonUpgradeSent: false
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

    Timer {
        id: reportTimer
        interval: 3000
        repeat: false
        onTriggered: reportUiState()
    }
    function reportUiState() {
        var xhr = new XMLHttpRequest()
        xhr.open("GET", "http://127.0.0.1:" + backendPort + "/ui/state?active="
                 + (Qt.application.active ? "1" : "0"))
        xhr.send()
    }
    Connections {
        target: Qt.application
        onActiveChanged: reportUiState()
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

    // Der Daemon kann still sterben (misslungenes Selbst-Update, Unit-Datei
    // waehrend des Updates getauscht, Start-Rate-Bremse). Dann bleiben
    // Benachrichtigungen aus und NIEMAND sagt es - man merkt es zufaellig,
    // wenn man die App oeffnet. Wer ihn eingeschaltet hat, erfaehrt es jetzt.
    // Welcher Dateiwaehler am Anhang-Knopf: "ask" fragt jedes Mal,
    // "content" nimmt den nach Typ sortierten (Bilder/Videos/Musik/
    // Dokumente), "file" den Dateibaum. Wunsch von kempertom
    property string attachPicker: "ask"

    // Berechtigungslage: was in der Desktop-Datei steht (configured) und
    // was der laufende Prozess tatsaechlich darf (effective)
    property bool mediaPermConfigured: false
    property bool mediaPermEffective: false
    // Kommaliste der fehlenden Marken - ein Teil-Grant (z.B. ohne
    // RemovableMedia, also ohne SD-Karte) sah frueher aus wie "gar nichts
    // erteilt" und schickte Leute auf die Suche, die den Befehl laengst
    // ausgefuehrt hatten
    property string mediaPermMissing: ""
    function refreshPermState() {
        var x = new XMLHttpRequest()
        x.open("GET", "http://127.0.0.1:" + backendPort + "/permcheck")
        x.onreadystatechange = function() {
            if (x.readyState !== 4 || x.status !== 200) return
            try {
                var p = JSON.parse(x.responseText)
                mediaPermConfigured = p.mediaPermission === true
                mediaPermEffective = p.mediaAccessEffective === true
                mediaPermMissing = (p.mediaMissing || []).join(", ")
            } catch (e) {}
        }
        x.send()
    }
    property bool daemonAutostart: false
    property bool daemonDownWarned: false
    property int daemonMissCount: 0
    Timer {
        id: daemonWatch
        interval: 20000
        repeat: true
        running: true
        onTriggered: {
            // Erst urteilen, wenn die Prefs da sind
            if (!prefsLoaded) return
            if (!daemonAutostart) return

            if (daemonRunning) {
                // Wieder da: Zaehler zuruecksetzen, eigene Warnung
                // zuruecknehmen und kuenftig wieder warnen duerfen
                daemonMissCount = 0
                if (daemonDownWarned) {
                    daemonDownWarned = false
                    if (globalNotice === loc.daemonDownNotice) globalNotice = ""
                }
                return
            }

            // Frueher wurde EINMAL nach 20 s geprueft und dann gestoppt -
            // ausgerechnet in dem Moment, in dem der Daemon nach einem
            // Update gerade neu startet. Die Warnung stimmte im Augenblick
            // der Pruefung und blieb danach fuer immer falsch stehen.
            // Jetzt laeuft der Wecker weiter und urteilt erst nach zwei
            // Fehlversuchen in Folge, also nach etwa 40 Sekunden
            daemonMissCount++
            if (daemonMissCount >= 2 && !daemonDownWarned) {
                daemonDownWarned = true
                globalNotice = loc.daemonDownNotice
                noticeIsError = true
            }
        }
    }

    function loadPrefs() {
        var xhr = new XMLHttpRequest()
        xhr.open("GET", "http://127.0.0.1:" + backendPort + "/prefs")
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== 4) return
            if (xhr.status === 200) {
                var p = JSON.parse(xhr.responseText) || {}
                contactsOptIn = p.contactSuggestions === "1"
                notificationsEnabled = p.notifications === "1"
                sendByEnter = p.send_by_enter === "1"
                chatGridView = p.chat_grid === "1"
                gridColumns = Math.max(2, Math.min(6, parseInt(p.grid_columns || "3")))
                tileGap = Math.max(0, Math.min(30, parseInt(p.tile_gap || "1")))
                showViewSwitcher = p.top_switcher !== "0"
                showNavBar = p.bottom_bar !== "0"
                appLanguage = p.app_language || ""
                daemonAutostart = p.daemon_autostart === "1"
                refreshPermState()
                attachPicker = p.attach_picker || "ask"
                orientationPref = p.orientation || "dynamic"
                emojiEnabled = p.emoji !== "0"
                forwardStay = p.forward_stay === "1"
                navBarSize = p.navbar_size || "large"
                statusGrouping = p.status_grouping !== "0"
                hideOnline = p.hide_online !== "0"
                statusByPerson = p.status_by_person === "1"
                mutedStatus = (p.status_muted || "").split(",").filter(function(x) {
                    return x !== ""
                })
                appDisplayName = p.app_name || "WhatsApp"
                lineMode = p.line_mode === "1"
                statusLastSeen = parseFloat(p.status_last_seen || "0") || 0
                prefsLoaded = true
                // Auch fuer Bestandsinstallationen und Systemsprache setzen
                if (p.notif_reply_label !== loc.reply)
                    setPref("notif_reply_label", loc.reply)
            } else {
                globalPrefsRetry.start()
            }
        }
        xhr.send()
    }
    Timer {
        id: globalPrefsRetry
        interval: 1500
        repeat: false
        onTriggered: loadPrefs()
    }

    function setPref(key, value, attempt) {
        var n = attempt || 0
        var xhr = new XMLHttpRequest()
        xhr.open("GET", "http://127.0.0.1:" + backendPort + "/prefs/set?key=" + key
                 + "&value=" + encodeURIComponent(value))
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== 4) return
            if (xhr.status === 200) return
            // Backend laedt evtl. noch die Stores (503 "starting") - das
            // kann nach einem App-Start mehrere Sekunden dauern; ein
            // einzelner Retry verlor Einstellungen (Grid-View-Feldfund):
            // UI zeigte den Schalter an, der Save verpuffte
            if (n < 10) {
                setPrefRetry.key = key
                setPrefRetry.value = value
                setPrefRetry.attempt = n + 1
                setPrefRetry.start()
            } else {
                globalNotice = "Saving setting failed: " + xhr.responseText
            }
        }
        xhr.send()
    }
    Timer {
        id: setPrefRetry
        property string key
        property string value
        property int attempt: 0
        interval: 1500
        repeat: false
        onTriggered: setPref(key, value, attempt)
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
    // O(1)-Lookup statt Adressbuch-Linearscan pro Aufruf: das PeopleModel
    // wird EINMAL in zwei Maps destilliert (kanonische JID und 9-Ziffern-
    // Suffix fuer die Landesvorwahl-Heuristik). Vorher lief pro sichtbarem
    // Delegate eine Schleife ueber das gesamte Adressbuch - in grossen
    // Gruppen bremste das die ganze App.
    property var localNameByJid: ({})
    property var localNameBySuffix: ({})

    function rebuildLocalContactMap() {
        var byJid = {}
        var bySuffix = {}
        var pm = peopleLoader.item
        for (var i = 0; pm && i < pm.count; i++) {
            var person = pm.get(i)
            if (!person || !person.phoneDetails) continue
            var label = person.displayLabel || ""
            if (label === "") continue
            for (var j = 0; j < person.phoneDetails.length; j++) {
                var raw = person.phoneDetails[j].normalizedNumber || person.phoneDetails[j].number
                var cand = toJid(raw)
                if (cand !== "" && byJid[cand] === undefined) byJid[cand] = label
                var pn = String(raw || "").replace(/[^0-9]/g, "").replace(/^0+/, "")
                if (pn.length >= 9) {
                    var suf = pn.substring(pn.length - 9)
                    if (bySuffix[suf] === undefined) bySuffix[suf] = label
                }
            }
        }
        localNameByJid = byJid
        localNameBySuffix = bySuffix
    }

    Timer {
        // PeopleModel fuellt sich asynchron: kurz nach Aktivierung und bei
        // Aenderungen (debounced) neu destillieren
        id: contactMapTimer
        interval: 800
        repeat: false
        onTriggered: rebuildLocalContactMap()
    }
    Connections {
        target: peopleLoader.item
        ignoreUnknownSignals: true
        onCountChanged: contactMapTimer.restart()
    }

    function findLocalContactName(phoneNumber) {
        if (!phoneNumber) return ""
        var jid = String(phoneNumber).replace(/[^0-9]/g, "")
        var n = localNameByJid[jid]
        if (n !== undefined) return n
        if (jid.length >= 9) {
            n = localNameBySuffix[jid.substring(jid.length - 9)]
            if (n !== undefined) return n
        }
        return ""
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


    property int backendLossCount: 0

    function rescanBackendPort() {
        // Totalverlust (z.B. Daemon per Terminal disabled, waehrend die App
        // offen war - frueher blieb sie backendlos bis zum Neustart): nach
        // drei erfolglosen Zyklen selbst ein Kind-Backend nachstarten
        // Waehrend eines laufenden Uploads ist das Geraet beschaeftigt und
        // /status antwortet langsam - das ist KEIN Backend-Verlust
        if (uploadInFlight > 0) return
        backendLossCount++
        if (backendLossCount === 3) {
            console.log("Backend lost entirely - respawning child backend")
            python.call('start_backend.start', [], function() {})
        }
        if (backendLossCount > 12) backendLossCount = 4 // Zaehler deckeln

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
                        backendLossCount = 0
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
                backendLossCount = 0
                var data = JSON.parse(xhr.responseText)
                var wasConnected = connected
                connected = data.connected
                pairCode = data.pairCode || ""
                phone = data.phone || ""
                // Eigenes Profil einmal holen, sobald die Verbindung steht
                if (connected && myName === "") loadOwnProfile()
                connState = data.state || ""
                lastError = data.lastError || ""
                paired = data.paired === true
                daemonRunning = data.daemon === true
                backendVersion = data.version || ""
                // Daemon-Selbst-Update: nach einem RPM-Update laeuft noch der
                // alte Prozess. Einmal pro App-Sitzung /daemon/restart rufen -
                // der Daemon beendet sich mit Exit 1, systemd startet den neu
                // installierten Binary, die Port-Wiederfindung dockt neu an.
                if (daemonRunning && installedVersion !== "" && backendVersion !== ""
                        && backendVersion !== installedVersion && !daemonUpgradeSent) {
                    daemonUpgradeSent = true
                    globalNotice = "Updating background daemon to " + installedVersion + "\u2026"
                    var rx = new XMLHttpRequest()
                    rx.open("POST", "http://127.0.0.1:" + backendPort + "/daemon/restart")
                    rx.send()
                }
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

    // Der Zaehler muss auch dann stimmen, wenn die Statusseite geschlossen
    // ist - sonst sieht man ihn nie. Laeuft im selben Takt wie die Chatliste.
    function loadStatusUnread() {
        var x = new XMLHttpRequest()
        x.open("GET", "http://127.0.0.1:" + backendPort + "/messages?jid=status")
        x.onreadystatechange = function() {
            if (x.readyState !== 4 || x.status !== 200) return
            try {
                var list = (JSON.parse(x.responseText) || []).filter(function(m) {
                    return !m.revoked
                })
                recomputeStatusUnread(list)
            } catch (e) {}
        }
        x.send()
    }

    function loadChats() {
        loadStatusUnread()
        var xhr = new XMLHttpRequest()
        xhr.open("GET", "http://127.0.0.1:" + backendPort + "/chats")
        xhr.onreadystatechange = function() {
            if (xhr.readyState === 4 && xhr.status === 200) {
                chats = JSON.parse(xhr.responseText) || []
                var nu = {}
                var chatsUnreadNow = 0
                for (var i = 0; i < chats.length; i++) {
                    var c = chats[i]
                    nu[c.jid] = c.unread || 0
                    if ((c.unread || 0) > 0 && !c.archived) chatsUnreadNow++
                    // Benachrichtigungen kommen ausschliesslich vom Backend
                    // (mit Reply-Aktion, Dedup und Muted-Logik) - die alte
                    // QML-Publikation hier erzeugte eine zweite, pfeillose
                    // Benachrichtigung pro Gruppen-Nachricht
                }
                prevUnread = nu
                prevUnreadInit = true
                chatsUnread = chatsUnreadNow
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
        // Sicherheitsnetz - der Normalweg ist der /events-Long-Poll
        interval: 60000
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

    // Bodenleiste auf allen Seiten (rdomschk-Wunsch): ein Component,
    // vier Loader, aktive Seite hervorgehoben. Spruenge ueber mehrere
    // Ebenen (z.B. Archiv -> Status) laufen als Kette ueber die
    // onStatusChanged-Handler der Zwischenseiten (navJumpTarget).
    property int navJumpTarget: -1

    // URLs in Nachrichtentext klickbar machen (tom_i-Wunsch):
    // erst HTML-escapen, dann Links in <a> verpacken - StyledText
    // interpretiert sonst spitze Klammern aus dem Nachrichtentext
    function linkify(t) {
        if (!t) return ""
        t = t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
        t = t.replace(/(https?:\/\/[^\s]+|www\.[^\s]+)/g, function(u) {
            var tail = ""
            var m = u.match(/[.,;:!?)\]]+$/)
            if (m) { tail = m[0]; u = u.substring(0, u.length - tail.length) }
            var href = (u.indexOf("http") === 0) ? u : ("http://" + u)
            return "<a href=\"" + href + "\">" + u + "</a>" + tail
        })
        t = t.replace(/\n/g, "<br>")
        // Farbige Emojis: Sailfish bringt keine Farb-Emoji-Schrift mit,
        // deshalb wie Fernschreiber ueber Twemoji-SVGs. Erst HIER, nach dem
        // Maskieren von < und >, sonst wuerden die erzeugten img-Tags selbst
        // maskiert. StyledText versteht <img> - ein Wechsel auf RichText
        // waere nicht noetig. Wunsch von rdomschk.
        return emojiEnabled ? Twemoji.emojify(t, Theme.fontSizeMedium) : t
    }

    // Standardmaessig an - auf dem Geraet zeigte sich kein spuerbarer
    // Unterschied beim Scrollen. Abschaltbar bleibt es trotzdem.
    property bool emojiEnabled: true
    // Nach dem Weiterleiten in der Empfaengerliste bleiben, um dieselbe
    // Nachricht mehreren zu schicken. Aus, weil der Rueckweg in den Chat
    // das ist, was man ueblicherweise erwartet.
    property bool forwardStay: false

    // Hoehe der Bodenleiste. Feste Werte trafen es nie fuer alle: zu niedrig
    // erwischt man den letzten Listeneintrag statt der Leiste, zu hoch frisst
    // sie den Schirm. Vorgabe ist hoch, weil Danebentippen aergerlicher ist
    // als ein paar Pixel weniger Liste.
    // Statusliste nach Person gruppieren. Optional, weil manche die rein
    // zeitliche Reihenfolge wollen - dort steht das Neueste immer oben,
    // egal von wem.
    // Zeilen statt Sprechblasen, wie Element es anbietet: Nachrichten ueber
    // die volle Breite, abwechselnd dezent eingefaerbt, mit dem Absender als
    // Vorspann. Vorschlag von kempertom. Bewusst abschaltbar - ausgeschaltet
    // bleibt alles, wie es war.
    property bool lineMode: false
    // Im Status stummgeschaltete Personen. Wer ein halbes Fotoalbum am Tag
    // postet, verdeckt sonst alles andere - Wunsch von kempertom, den
    // rdomschk gleich mit oben auf seine Liste gesetzt hat. Die Beitraege
    // werden nur ausgeblendet, nicht abbestellt: fuer WhatsApp aendert sich
    // nichts, und ein Abbestellen waere auch nicht rueckgaengig zu machen.
    property var mutedStatus: []
    function isStatusMuted(jid) { return mutedStatus.indexOf(jid) >= 0 }

    // Eine Zeile je Person: neueste Person zuerst, mit Anzahl und Zeitpunkt
    // des juengsten Beitrags. Gebaut aus den ohnehin geladenen Beitraegen -
    // keine zusaetzliche Abfrage, also auch kein zusaetzliches Sperrrisiko.
    function statusPeople() {
        var by = {}, order = []
        for (var i = 0; i < statuses.length; i++) {
            var m = statuses[i]
            if (m.fromMe || !m.sender) continue
            if (!by[m.sender]) {
                by[m.sender] = { sender: m.sender, count: 0, newest: 0, isLid: m.senderIsLid === true }
                order.push(m.sender)
            }
            by[m.sender].count++
            if (m.timestamp > by[m.sender].newest) by[m.sender].newest = m.timestamp
        }
        var out = []
        for (var k = 0; k < order.length; k++) out.push(by[order[k]])
        out.sort(function(a, b) { return b.newest - a.newest })
        return out
    }
    function statusesOf(jid) {
        return statuses.filter(function(m) { return m.sender === jid && !m.fromMe })
    }
    function toggleStatusMute(jid) {
        var a = mutedStatus.slice()
        var i = a.indexOf(jid)
        if (i >= 0) a.splice(i, 1); else a.push(jid)
        mutedStatus = a
        setPref("status_muted", a.join(","))
        loadStatuses()
    }

    // Nicht als online erscheinen. Kostet die Statusbeitraege: WhatsApp
    // stellt sie nur an Geraete zu, die sich als verfuegbar melden. Der
    // Zielkonflikt steht deshalb im Beschreibungstext, nicht im Kleingedruckten.
    // Vorgabe: NICHT online erscheinen. Der Preis ist, dass ohne die
    // Verfuegbar-Meldung keine Statusbeitraege ankommen - deshalb sagt die
    // Statusseite ausdruecklich, warum sie leer ist, statt wie kaputt
    // auszusehen.
    property bool hideOnline: true
    // Eine Zeile je Person statt aller Beitraege untereinander; antippen
    // oeffnet die Beitraege dieser Person. Vorschlag von rdomschk, optional,
    // weil manche das durchgehende Blaettern lieber moegen.
    property bool statusByPerson: false
    property bool statusGrouping: true
    property string navBarSize: "large"
    function navBarHeight() {
        if (navBarSize === "small") return Theme.itemSizeSmall
        if (navBarSize === "medium") return Theme.itemSizeMedium
        return Theme.itemSizeLarge
    }

    // Ungelesene Statusmeldungen: gemerkt wird nur der Zeitstempel des
    // zuletzt Angesehenen, nicht jede einzelne Kennung - das waechst nicht
    // ins Unendliche und uebersteht einen Neustart.
    property double statusLastSeen: 0
    property int statusUnread: 0
    // Ungelesene Chats, damit die Leiste es auch dort zeigen kann
    property int chatsUnread: 0
    function recomputeStatusUnread(list) {
        var n = 0
        for (var i = 0; i < list.length; i++) {
            if (!list[i].fromMe && list[i].timestamp > statusLastSeen) n++
        }
        statusUnread = n
    }
    function markStatusSeen(list) {
        var newest = statusLastSeen
        for (var i = 0; i < list.length; i++) {
            if (!list[i].fromMe && list[i].timestamp > newest) newest = list[i].timestamp
        }
        if (newest > statusLastSeen) {
            statusLastSeen = newest
            setPref("status_last_seen", String(newest))
        }
        statusUnread = 0
    }

    function navGo(from, to) {
        if (to === from) return
        if (to < from) {
            navJumpTarget = -1
            // navigateBack in einer Schleife machte die Leiste UNBRAUCHBAR:
            // ein Fehler darin bricht den Klick-Handler ab, und dann
            // reagiert kein einziger Eintrag mehr. Zurueck zum bewaehrten
            // pop() - der Weg vom Status aus wird gesondert behandelt.
            if (to === 0) pageStack.pop(archPageItem)
            else if (to === 1) pageStack.pop(favPageItem)
            else pageStack.pop(mainPage)
        } else {
            navJumpTarget = (to - from > 1) ? to : -1
            pageStack.navigateForward(to - from > 1 ? PageStackAction.Immediate
                                                    : PageStackAction.Animated)
        }
    }

    Component {
        id: navBarComp
        Item {
            anchors.fill: parent
            // Seit der Row in diesem Item steckt, ist "item" des Loaders
            // dieses Item und nicht mehr die Row - onLoaded setzte
            // activeIndex damit ins Leere, und ueberall blieb "Chats"
            // hervorgehoben. Der Alias reicht es an die Row durch.
            property alias activeIndex: bar.activeIndex

            // Eigener Hintergrund und Trennlinie: bisher war die Leiste
            // optisch nicht von der Liste zu unterscheiden, und wo man
            // hintippt, ist bei einem unsichtbaren Streifen Glueckssache.
            // Zugleich zeigt der Hintergrund beim Testen, wo die Leiste
            // wirklich sitzt und wie hoch sie ist.
            Rectangle {
                anchors.fill: parent
                color: Theme.rgba(Theme.highlightBackgroundColor, 0.12)
            }
            Rectangle {
                anchors { left: parent.left; right: parent.right; top: parent.top }
                height: 1
                color: Theme.rgba(Theme.primaryColor, 0.2)
            }

        Row {
            id: bar
            property int activeIndex: 2
            anchors.fill: parent
            Repeater {
                model: [ loc.archive, loc.favorites, loc.chats, loc.status ]
                delegate: BackgroundItem {
                    width: bar.width / 4
                    height: bar.height
                    enabled: index !== bar.activeIndex
                    onClicked: navGo(bar.activeIndex, index)
                    Label {
                        id: barLabel
                        anchors.centerIn: parent
                        // Zahl daneben, wo etwas ungelesen ist - ohne sie
                        // weiss niemand, ob sich etwas getan hat
                        property int badge: index === 2 ? chatsUnread
                                          : (index === 3 ? statusUnread : 0)
                        text: badge > 0 ? modelData + " (" + badge + ")" : modelData
                        // Kleiner und blass war auf hellen Ambiences kaum zu
                        // entziffern: eine Stufe groesser, und die inaktiven
                        // Eintraege tragen die volle Sekundaerfarbe statt
                        // einer abgeblendeten. Wunsch von rdomschk.
                        font.pixelSize: Theme.fontSizeSmall
                        font.bold: badge > 0 || index === bar.activeIndex
                        color: index === bar.activeIndex || highlighted
                             ? Theme.highlightColor
                             : (badge > 0 ? Theme.highlightColor : Theme.primaryColor)
                    }
                }
            }
        }
        }
    }

    Page {
        allowedOrientations: orientationMask()
        id: mainPage

        // Status-Seite als attached page: Sailfish zeigt den Glow-Indikator
        // oben rechts, Wisch von rechts nach links oeffnet sie.
        // Erst anhaengen, wenn die Verbindung steht - vorher gehoert der
        // Platz dem Pairing-/Verbindungszustand.
        function updateAttachedStatus() {
            if (status === PageStatus.Active && connected) {
                pageStack.pushAttached(statusPage)
                // Kettenende: Sprung aus Archiv/Favoriten bis zum Status
                if (navJumpTarget === 3) {
                    navJumpTarget = -1
                    pageStack.navigateForward(PageStackAction.Animated)
                } else {
                    navJumpTarget = -1
                }
            }
        }
        onStatusChanged: updateAttachedStatus()

        // Bodenleiste (OpenRepos-Idee): Ein-Tipp-Navigation zu Archive,
        // Favorites und Status - die Wischgesten bleiben unveraendert.
        // Textknoepfe statt Icon-Roulette; "Chats" markiert den Standort
        Loader {
            id: navBar
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            z: 10   // vor der Liste, falls doch etwas darueber hinausragt
            // itemSizeExtraSmall war als Tippziel zu knapp - man trifft daneben
            // und landet in der Liste darueber (rdomschk). Die Beschriftung
            // ist seit 0.9.217 groesser, die Flaeche war es noch nicht
            height: (connected && showNavBar) ? navBarHeight() : 0
            visible: connected && showNavBar
            sourceComponent: navBarComp   // activeIndex 2 = Chats ist Standard
        }

        // Kachel-Ansicht als ListView aus Reihen: nur so verdraengt das
        // Langdruck-Menue die Folgereihen nativ (GridView layoutet stur
        // nach cellHeight - ListItem-Delegates wachsen und schieben)
        SilicaListView {
            id: chatGrid
            // OHNE clip zeichnet eine ListView ihre Eintraege ueber die
            // eigenen Grenzen hinaus - und diese Eintraege nehmen auch
            // Beruehrungen entgegen. Der letzte Chat lag damit HINTER der
            // Bodenleiste und fing den Tipp ab, egal wie hoch sie war.
            clip: true
            anchors { left: parent.left; right: parent.right; top: parent.top; bottom: navBar.top }
            visible: chatGridView && connected
            model: (connected && chatGridView) ? Math.ceil(chats.length / gridColumns) : 0

            header: Column {
                width: parent.width
                Loader { width: parent.width; active: showViewSwitcher; sourceComponent: viewSwitcherComp }
                BackgroundItem {
                    // Antippen kopiert - Fehlertexte sind zum Weitermelden da
                    visible: globalNotice !== ""
                    width: parent.width
                    height: visible ? noticeLbl1.height + 2*Theme.paddingSmall : 0
                    onClicked: {
                        Clipboard.text = globalNotice
                        globalNotice = loc.copiedToClipboard
                    }
                    Label {
                        id: noticeLbl1
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*x
                        anchors.verticalCenter: parent.verticalCenter
                        text: globalNotice + (noticeLooksLikeError()
                                              ? "\n" + loc.tapToCopy : "")
                        wrapMode: Text.Wrap
                        font.pixelSize: Theme.fontSizeSmall
                        color: noticeLooksLikeError() ? Theme.errorColor : Theme.highlightColor
                    }
                }
            }

            PullDownMenu {
                MenuItem {
                    text: loc.logout
                    visible: !mainPage.isLandscape && (connected)
                    onClicked: logoutRemorse.execute("Logging out", doLogout, 15000)
                }
                MenuItem {
                    text: loc.reload
                    visible: !mainPage.isLandscape && (connected)
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
                    text: loc.markAllRead
                    visible: {
                        if (mainPage.isLandscape) return false
                        for (var i = 0; i < chats.length; i++)
                            if ((chats[i].unread || 0) > 0) return true
                        return false
                    }
                    onClicked: {
                        var xhr = new XMLHttpRequest()
                        xhr.open("GET", "http://127.0.0.1:" + backendPort + "/chats/read-all")
                        xhr.onreadystatechange = function() {
                            if (xhr.readyState === 4) loadChats()
                        }
                        xhr.send()
                    }
                }
                MenuItem {
                    text: loc.settings
                    onClicked: pageStack.push(settingsPage)
                }
                MenuItem {
                    text: loc.profile
                    visible: !mainPage.isLandscape && (connected)
                    onClicked: pageStack.push(profilePage)
                }
                MenuItem {
                    text: loc.search
                    visible: connected
                    onClicked: pageStack.push(searchPage)
                }
                MenuItem {
                    text: loc.channels
                    visible: !mainPage.isLandscape && (connected)
                    onClicked: pageStack.push(channelsPage)
                }
                MenuItem {
                    // Ersetzt im Querformat die Kanaele: von hier aus
                    // sind ALLE Aktionen erreichbar, auch die, fuer die
                    // das kurze Menue keinen Platz hat
                    visible: mainPage.isLandscape
                    text: loc.allActions
                    onClicked: pageStack.push(allActionsPage)
                }
                MenuItem {
                    text: loc.joinViaLink
                    visible: connected
                    onClicked: pageStack.push(joinLinkPage)
                }
                MenuItem {
                    text: loc.newGroup
                    visible: connected
                    onClicked: pageStack.push(newGroupPage)
                }
                MenuItem {
                    text: loc.newChat
                    visible: connected
                    onClicked: pageStack.push(newChatPage)
                }
            }

            delegate: ListItem {
                id: gridRow
                width: chatGrid.width
                contentHeight: chatGrid.width / gridColumns
                property var rowChats: chats.slice(index * gridColumns, (index + 1) * gridColumns)
                property var menuChat: ({})

                menu: Component {
                    ContextMenu {
                        MenuItem {
                            text: (gridRow.menuChat.pinned ? loc.removeFav : loc.addFav)
                            onClicked: chatSettingFor(gridRow.menuChat.jid, gridRow.menuChat.pinned ? "unpin" : "pin")
                        }
                        MenuItem {
                            text: (gridRow.menuChat.muted ? loc.unmute : loc.mute)
                            onClicked: chatSettingFor(gridRow.menuChat.jid, gridRow.menuChat.muted ? "unmute" : "mute")
                        }
                        MenuItem {
                            text: (gridRow.menuChat.archived ? loc.unarchiveAction : loc.archiveAction)
                            onClicked: chatSettingFor(gridRow.menuChat.jid, gridRow.menuChat.archived ? "unarchive" : "archive")
                        }
                    }
                }

                Row {
                    anchors.top: parent.top
                    Repeater {
                        model: gridRow.rowChats
                        delegate: BackgroundItem {
                            id: gridTile
                            width: chatGrid.width / gridColumns
                            height: width
                            opacity: modelData.archived ? 0.45 : 1.0
                            onClicked: pageStack.push(chatPage, {
                                chatJid: modelData.jid,
                                chatName: getDisplayName(modelData.jid, modelData.name),
                                chatAvatar: modelData.avatar || "",
                                isChannel: modelData.isChannel === true
                            })
                            onPressAndHold: {
                                gridRow.menuChat = modelData
                                gridRow.openMenu()
                            }

                            Rectangle {
                                anchors.fill: parent
                                // Deckel bei einem Drittel der Zellbreite: darunter
                                // waeren Avatar und Namensbalken nicht mehr lesbar
                                anchors.margins: Math.min(tileGap * Theme.paddingSmall / 2,
                                                          gridTile.width / 3)
                                color: Theme.rgba(Theme.highlightBackgroundColor, 0.15)

                                Image {
                                    anchors.fill: parent
                                    source: modelData.avatar || ""
                                    fillMode: Image.PreserveAspectCrop
                                    asynchronous: true
                                }

                                Rectangle {
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.bottom: parent.bottom
                                    height: nameLbl.height + Theme.paddingSmall
                                    color: Theme.rgba("black", 0.55)

                                    Label {
                                        id: nameLbl
                                        anchors.centerIn: parent
                                        width: parent.width - Theme.paddingSmall
                                        text: getDisplayName(modelData.jid, modelData.name)
                                        truncationMode: TruncationMode.Fade
                                        horizontalAlignment: Text.AlignHCenter
                                        font.pixelSize: Theme.fontSizeExtraSmall
                                        color: "white"
                                    }
                                }

                                Rectangle {
                                    visible: (modelData.unread || 0) > 0
                                    anchors.top: parent.top
                                    anchors.right: parent.right
                                    anchors.margins: Theme.paddingSmall
                                    width: unreadLbl.width + Theme.paddingMedium
                                    height: unreadLbl.height + Theme.paddingSmall
                                    radius: height / 2
                                    color: Theme.highlightBackgroundColor

                                    Label {
                                        id: unreadLbl
                                        anchors.centerIn: parent
                                        text: modelData.unread || ""
                                        font.pixelSize: Theme.fontSizeExtraSmall
                                        font.bold: true
                                        color: Theme.primaryColor
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        SilicaListView {
            // OHNE clip zeichnet eine ListView ihre Eintraege ueber die
            // eigenen Grenzen hinaus - und diese Eintraege nehmen auch
            // Beruehrungen entgegen. Der letzte Chat lag damit HINTER der
            // Bodenleiste und fing den Tipp ab, egal wie hoch sie war.
            clip: true
            anchors { left: parent.left; right: parent.right; top: parent.top; bottom: navBar.top }
            visible: !chatGridView || !connected
            model: connected ? chats : null

            PullDownMenu {
                MenuItem {
                    text: loc.logout
                    visible: !mainPage.isLandscape && (connected)
                    onClicked: logoutRemorse.execute("Logging out", doLogout, 15000)
                }
                MenuItem {
                    text: loc.reload
                    visible: !mainPage.isLandscape && (connected)
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
                    text: loc.markAllRead
                    visible: {
                        if (mainPage.isLandscape) return false
                        for (var i = 0; i < chats.length; i++)
                            if ((chats[i].unread || 0) > 0) return true
                        return false
                    }
                    onClicked: {
                        var xhr = new XMLHttpRequest()
                        xhr.open("GET", "http://127.0.0.1:" + backendPort + "/chats/read-all")
                        xhr.onreadystatechange = function() {
                            if (xhr.readyState === 4) loadChats()
                        }
                        xhr.send()
                    }
                }
                MenuItem {
                    text: loc.settings
                    onClicked: pageStack.push(settingsPage)
                }
                MenuItem {
                    text: loc.profile
                    visible: !mainPage.isLandscape && (connected)
                    onClicked: pageStack.push(profilePage)
                }
                MenuItem {
                    text: loc.search
                    visible: connected
                    onClicked: pageStack.push(searchPage)
                }
                MenuItem {
                    text: loc.channels
                    visible: !mainPage.isLandscape && (connected)
                    onClicked: pageStack.push(channelsPage)
                }
                MenuItem {
                    // Ersetzt im Querformat die Kanaele: von hier aus
                    // sind ALLE Aktionen erreichbar, auch die, fuer die
                    // das kurze Menue keinen Platz hat
                    visible: mainPage.isLandscape
                    text: loc.allActions
                    onClicked: pageStack.push(allActionsPage)
                }
                MenuItem {
                    text: loc.joinViaLink
                    visible: connected
                    onClicked: pageStack.push(joinLinkPage)
                }
                MenuItem {
                    text: loc.newGroup
                    visible: connected
                    onClicked: pageStack.push(newGroupPage)
                }
                MenuItem {
                    text: loc.newChat
                    visible: connected
                    onClicked: pageStack.push(newChatPage)
                }
            }

            RemorsePopup { id: logoutRemorse }

            header: Column {
                width: parent.width

                Loader {
                    width: parent.width
                    active: connected && showViewSwitcher
                    sourceComponent: viewSwitcherComp
                }

                PageHeader { 
                    title: appDisplayName
                    description: {
                        // Der eigene Name statt der Nummer. Solange er noch
                        // nicht geladen ist, bleibt die Zeile LEER - die
                        // Nummer kurz aufblitzen zu lassen waere genau das,
                        // was hier vermieden werden soll.
                        if (connected) return myName
                        switch (connState) {
                        case "starting":         return loc.stStarting
                        case "connecting":       return loc.stConnecting
                        case "reconnecting":     return loc.stReconnecting
                        case "waiting_for_pair": return loc.stNotPaired
                        case "logged_out":       return loc.stLoggedOut
                        case "relogin_required": return loc.stActionRequired
                        case "secrets_error":    return loc.stSecretsProblem
                        case "error":            return lastError !== "" ? lastError : loc.stConnectionError
                        default:                 return loc.stNotConnected
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
                    text: loc.retryConnection
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

                Label {
                    visible: connState === "secrets_error"
                    x: Theme.horizontalPageMargin
                    width: parent.width - 2*x
                    wrapMode: Text.Wrap
                    font.pixelSize: Theme.fontSizeExtraSmall
                    color: Theme.secondaryColor
                    text: loc.repairNote
                }

                Button {
                    text: loc.restartBackend
                    visible: connState === "secrets_error"
                    anchors.horizontalCenter: parent.horizontalCenter
                    onClicked: {
                        var xhr = new XMLHttpRequest()
                        xhr.open("GET", "http://127.0.0.1:" + backendPort + "/quit")
                        xhr.onreadystatechange = function() {
                            if (xhr.readyState === 4) {
                                connState = "starting"
                                lastError = ""
                                restartTimer.start()
                            }
                        }
                        xhr.send()
                    }
                }

                Button {
                    text: loc.repairKeepHistory
                    visible: connState === "secrets_error"
                    anchors.horizontalCenter: parent.horizontalCenter
                    onClicked: resetRemorse.execute("Resetting pairing", function() {
                        var xhr = new XMLHttpRequest()
                        xhr.open("GET", "http://127.0.0.1:" + backendPort + "/reset")
                        xhr.onreadystatechange = function() {
                            if (xhr.readyState === 4) {
                                connState = "starting"
                                lastError = ""
                                var xq = new XMLHttpRequest()
                                xq.open("GET", "http://127.0.0.1:" + backendPort + "/quit")
                                xq.onreadystatechange = function() {
                                    if (xq.readyState === 4) restartTimer.start()
                                }
                                xq.send()
                            }
                        }
                        xhr.send()
                    })
                }

                Button {
                    text: loc.resetPairAgain
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

                BackgroundItem {
                    visible: globalNotice !== ""
                    width: parent.width
                    height: visible ? noticeLbl2.height + 2*Theme.paddingSmall : 0
                    onClicked: {
                        Clipboard.text = globalNotice
                        globalNotice = loc.copiedToClipboard
                    }
                    Label {
                        id: noticeLbl2
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*x
                        anchors.verticalCenter: parent.verticalCenter
                        text: globalNotice + (noticeLooksLikeError()
                                              ? "\n" + loc.tapToCopy : "")
                        wrapMode: Text.Wrap
                        font.pixelSize: Theme.fontSizeSmall
                        color: noticeLooksLikeError() ? Theme.errorColor : Theme.highlightColor
                    }
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
                        label: loc.phoneNumberLabel
                        placeholderText: "43664..."
                        text: ""
                        inputMethodHints: Qt.ImhDigitsOnly
                    }

                    BackgroundItem {
                        visible: pairErrorMsg !== ""
                        width: parent.width
                        height: pairErrLabel.height + 2*Theme.paddingMedium
                        onClicked: {
                            Clipboard.text = pairErrorMsg
                            globalNotice = loc.copiedToClipboard
                        }
                        Label {
                            id: pairErrLabel
                            width: parent.width - 2*Theme.horizontalPageMargin
                            anchors.centerIn: parent
                            text: pairErrorMsg + "\n" + loc.tapToCopy
                            wrapMode: Text.Wrap
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.errorColor
                        }
                    }

                    Button {
                        text: loc.startPairing
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
                                text: "\u2713 " + loc.copiedToClipboard
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
                                text: loc.tapCodeToCopy
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
                        text: loc.linkedDevicesHint
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
                        text: loc.stopLiveLocation
                        visible: liveActive && liveChatJid === modelData.jid
                        onClicked: stopLiveShare()
                    }
                    MenuItem {
                        text: modelData.pinned ? loc.removeFav : loc.addFav
                        visible: modelData.jid !== "status"
                        onClicked: chatSetting(modelData.pinned ? "unpin" : "pin")
                    }
                    MenuItem {
                        text: modelData.muted ? loc.unmute : loc.mute
                        visible: modelData.jid !== "status"
                        onClicked: chatSetting(modelData.muted ? "unmute" : "mute")
                    }
                    MenuItem {
                        text: modelData.archived ? loc.unarchiveAction : loc.archiveAction
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
                            font.bold: (modelData.unread || 0) > 0
                            color: (modelData.unread || 0) > 0 ? Theme.highlightColor : Theme.primaryColor
                            truncationMode: TruncationMode.Fade
                            width: parent.width
                            opacity: modelData.archived ? Theme.opacityLow : 1.0
                        }
                        Label {
                            // keep this strictly single-line: multi-line last
                            // messages used to overflow the fixed-height list
                            // item and paint over the next chat entry
                            text: modelData.lastMessage ? ((modelData.fromMe ? loc.you + " " : "") + locMsg(modelData.lastMessage).replace(/\n/g, " ")) : ""
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.secondaryColor
                            truncationMode: TruncationMode.Fade
                            maximumLineCount: 1
                            width: parent.width
                        }
                    }

                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.paddingSmall / 2

                        Label {
                            id: timeLabel
                            text: formatTime(modelData.lastTime)
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.secondaryColor
                            anchors.right: parent.right
                        }
                        Rectangle {
                            visible: (modelData.unread || 0) > 0
                            anchors.right: parent.right
                            width: Math.max(unreadLabel.width + Theme.paddingSmall * 2, height)
                            height: unreadLabel.height + Theme.paddingSmall
                            radius: height / 2
                            color: Theme.highlightBackgroundColor
                            Label {
                                id: unreadLabel
                                anchors.centerIn: parent
                                text: modelData.unread > 99 ? "99+" : modelData.unread
                                font.pixelSize: Theme.fontSizeExtraSmall
                                font.bold: true
                            }
                        }
                    }
                }
            }

            ViewPlaceholder {
                enabled: connected && chats.length === 0
                text: loc.noChats
                hintText: loc.noChatsHint
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
            allowedOrientations: orientationMask()
            property var downloadPrefs: ({})
            // Schreibschutz: onCurrentIndexChanged feuert schon bei der
            // Initialisierung der ComboBoxen (Index 0 -> Default) und hat
            // dabei die gespeicherten Werte mit den Defaults UEBERSCHRIEBEN,
            // solange der /prefs-Fetch noch lief - erst nach erfolgreichem
            // Laden darf gespeichert werden
            property bool prefsReady: false
            // Anzeige-Sync direkt am Eigentuemer der Property: das
            // Connections-Konstrukt in Kind-Elementen hat sich schon bei
            // den Auto-Download-Boxen als unzuverlaessig erwiesen
            onDownloadPrefsChanged: {
                notifySwitch.checked = downloadPrefs["notifications"] === "1"
                sendByEnterSwitch.checked = downloadPrefs["send_by_enter"] === "1"
                notifSoundSwitch.checked = downloadPrefs["notif_sound"] !== "0"
                notifVibrateSwitch.checked = downloadPrefs["notif_vibrate"] !== "0"
            }
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

            function loadDownloadPrefs() {
                var xhr = new XMLHttpRequest()
                xhr.open("GET", "http://127.0.0.1:" + backendPort + "/prefs")
                xhr.onreadystatechange = function() {
                    if (xhr.readyState !== 4) return
                    if (xhr.status === 200) {
                        downloadPrefs = JSON.parse(xhr.responseText) || {}
                        prefsReady = true
                    } else {
                        // Backend laedt noch (503) - gleich nochmal, sonst
                        // zeigen die ComboBoxen faelschlich die Defaults
                        prefsRetry.start()
                    }
                }
                xhr.send()
            }
            Timer {
                id: prefsRetry
                interval: 1200
                repeat: false
                onTriggered: loadDownloadPrefs()
            }

            Component.onCompleted: {
                loadStorage()
                loadDownloadPrefs()
            }

            SilicaFlickable {
                anchors.fill: parent
                contentHeight: setCol.height

                Column {
                    id: setCol
                    width: parent.width
                    spacing: Theme.paddingMedium

                    PageHeader { title: loc.settings }

                    TextSwitch {
                        text: loc.addressBook
                        description: loc.addressBookDesc
                        checked: contactsOptIn
                        automaticCheck: false
                        onClicked: {
                            contactsOptIn = !contactsOptIn
                            setPref("contactSuggestions", contactsOptIn ? "1" : "0")
                        }
                    }

                    BackgroundItem {
                        width: parent.width
                        height: Theme.itemSizeSmall
                        onClicked: pageStack.push(languagePage)
                        Label {
                            x: Theme.horizontalPageMargin
                            anchors.verticalCenter: parent.verticalCenter
                            text: loc.language + " \u203a"
                            color: highlighted ? Theme.highlightColor : Theme.primaryColor
                        }
                    }

                    BackgroundItem {
                        width: parent.width
                        height: Theme.itemSizeSmall
                        onClicked: pageStack.push(extraSettingsPage)
                        Label {
                            x: Theme.horizontalPageMargin
                            anchors.verticalCenter: parent.verticalCenter
                            text: loc.moreSettings + " \u203a"
                            color: highlighted ? Theme.highlightColor : Theme.primaryColor
                        }
                    }

                    BackgroundItem {
                        width: parent.width
                        height: Theme.itemSizeSmall
                        onClicked: pageStack.push(aboutAppPage)
                        Label {
                            x: Theme.horizontalPageMargin
                            anchors.verticalCenter: parent.verticalCenter
                            text: loc.aboutApp + " \u203a"
                            color: highlighted ? Theme.highlightColor : Theme.primaryColor
                        }
                    }

                    SectionHeader { text: loc.chatInput }

                    TextSwitch {
                        id: sendByEnterSwitch
                        text: loc.sendByEnter
                        description: loc.sendByEnterDesc
                        checked: false
                        onClicked: {
                            sendByEnter = checked
                            var p = downloadPrefs
                            p["send_by_enter"] = checked ? "1" : "0"
                            downloadPrefs = p
                            setPref("send_by_enter", checked ? "1" : "0")
                        }
                    }

                    SectionHeader {
                        text: loc.galleryVisibility
                        visible: permStatus.mediaGranted
                    }

                    Label {
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*x
                        wrapMode: Text.Wrap
                        font.pixelSize: Theme.fontSizeExtraSmall
                        color: Theme.secondaryColor
                        visible: permStatus.mediaGranted
                        text: loc.galleryDesc
                    }

                    Column {
                        id: nomediaCol
                        width: parent.width
                        visible: permStatus.mediaGranted
                        property var nomediaState: ({})
                        Component.onCompleted: {
                            python.call('start_backend.nomedia_get', [], function(st) {
                                nomediaState = st || {}
                            })
                        }

                        Repeater {
                            model: [
                                { key: "images",    label: loc.hideImages },
                                { key: "videos",    label: loc.hideVideos },
                                { key: "audio",     label: loc.hideAudio },
                                { key: "documents", label: loc.hideDocuments },
                                { key: "avatars",   label: loc.hideAvatars }
                            ]
                            delegate: TextSwitch {
                                text: modelData.label
                                checked: nomediaCol.nomediaState[modelData.key] === true
                                automaticCheck: false
                                onClicked: {
                                    python.call('start_backend.nomedia_set',
                                        [modelData.key, !(nomediaCol.nomediaState[modelData.key] === true)],
                                        function(st) { nomediaCol.nomediaState = st || {} })
                                }
                            }
                        }
                    }

                    SectionHeader { text: loc.notifications }

                    TextSwitch {
                        id: notifySwitch
                        text: loc.eventNotifs
                        description: loc.eventNotifsDesc
                        checked: false
                        Component.onCompleted: checked = downloadPrefs["notifications"] === "1"
                        onClicked: {
                            if (!prefsReady) { checked = !checked; return }
                            notificationsEnabled = checked
                            var p = downloadPrefs
                            p["notifications"] = checked ? "1" : "0"
                            downloadPrefs = p
                            setPref("notifications", checked ? "1" : "0")
                            // Regel "Daemon nur mit Benachrichtigungen" sofort
                            // durchsetzen: laufenden Daemon per /quit beenden
                            // und Kind-Backend nachstarten (systemctl ist in
                            // der Sandbox tabu)
                            if (!checked && daemonRunning) {
                                globalNotice = "Stopping background daemon\u2026"
                                python.call('start_backend.stop_daemon_via_quit', [], function() {
                                    globalNotice = "Background daemon stopped (autostart link remains - it exits by itself at next login while notifications are off)"
                                })
                            }
                        }
                    }

                    TextSwitch {
                        id: notifSoundSwitch
                        text: loc.notifSound
                        description: loc.notifSoundDesc
                        checked: true
                        visible: notifySwitch.checked
                        onClicked: {
                            var p = downloadPrefs
                            p["notif_sound"] = checked ? "1" : "0"
                            downloadPrefs = p
                            setPref("notif_sound", checked ? "1" : "0")
                        }
                    }

                    TextSwitch {
                        id: notifVibrateSwitch
                        text: loc.notifVibration
                        checked: true
                        visible: notifySwitch.checked
                        onClicked: {
                            var p = downloadPrefs
                            p["notif_vibrate"] = checked ? "1" : "0"
                            downloadPrefs = p
                            setPref("notif_vibrate", checked ? "1" : "0")
                        }
                    }

Label {
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*x
                        wrapMode: Text.Wrap
                        font.pixelSize: Theme.fontSizeSmall
                        color: daemonRunning ? Theme.highlightColor : Theme.secondaryColor
                        property bool versionLag: daemonRunning && installedVersion !== ""
                                                  && backendVersion !== "" && backendVersion !== installedVersion
                        text: loc.backgroundDaemon + ": " + (daemonRunning ? loc.daemonRunning : loc.daemonNotRunning)
                              + (versionLag ? ("\u26a0 running version " + backendVersion
                                 + ", installed is " + installedVersion
                                 + " - restart the daemon (command below)") : "")
                        visible: notifySwitch.checked || daemonRunning || downloadPrefs["daemon_autostart"] === "1"
                    }

                    Label {
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*x
                        wrapMode: Text.Wrap
                        font.pixelSize: Theme.fontSizeExtraSmall
                        color: Theme.secondaryColor
                        visible: notifySwitch.checked || daemonRunning || downloadPrefs["daemon_autostart"] === "1"
                        text: loc.daemonDesc
                    }

                    BackgroundItem {
                        width: parent.width
                        visible: notifySwitch.checked
                        height: enableCmdLabel.height + 2*Theme.paddingMedium
                        onClicked: {
                            Clipboard.text = "systemctl --user enable --now harbour-whatsapp-daemon.service"
                            globalNotice = "Enable command copied - paste in Terminal"
                            var p = downloadPrefs
                            p["daemon_autostart"] = "1"
                            downloadPrefs = p
                            setPref("daemon_autostart", "1")
                        }
                        Label {
                            id: enableCmdLabel
                            x: Theme.horizontalPageMargin
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - 2*Theme.horizontalPageMargin
                            wrapMode: Text.WrapAnywhere
                            font.pixelSize: Theme.fontSizeExtraSmall
                            font.family: "monospace"
                            color: Theme.primaryColor
                            text: "systemctl --user enable --now harbour-whatsapp-daemon.service"
                        }
                    }

                    BackgroundItem {
                        width: parent.width
                        visible: daemonRunning && installedVersion !== ""
                                 && backendVersion !== "" && backendVersion !== installedVersion
                        height: restartCmdLabel.height + 2*Theme.paddingMedium
                        onClicked: {
                            Clipboard.text = "systemctl --user restart harbour-whatsapp-daemon.service"
                            globalNotice = "Restart command copied - paste in Terminal"
                        }
                        Label {
                            id: restartCmdLabel
                            x: Theme.horizontalPageMargin
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - 2*Theme.horizontalPageMargin
                            wrapMode: Text.WrapAnywhere
                            font.pixelSize: Theme.fontSizeExtraSmall
                            font.family: "monospace"
                            color: Theme.primaryColor
                            text: "systemctl --user restart harbour-whatsapp-daemon.service"
                        }
                    }

                    Label {
                        visible: daemonRunning || downloadPrefs["daemon_autostart"] === "1"
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*Theme.horizontalPageMargin
                        text: "\u26a0 Stops autostart - notifications end after next reboot:"
                        wrapMode: Text.Wrap
                        font.pixelSize: Theme.fontSizeExtraSmall
                        color: Theme.errorColor
                    }

                    BackgroundItem {
                        width: parent.width
                        // Enabled-Zustand ist aus der Sandbox nicht pruefbar
                        // (~/.config/systemd ist verborgen) - lokales Flag
                        // "je aktiviert" irrt im Zweifel Richtung Anzeigen
                        visible: daemonRunning || downloadPrefs["daemon_autostart"] === "1"
                        height: disableCmdLabel.height + 2*Theme.paddingMedium
                        onClicked: {
                            Clipboard.text = "systemctl --user disable --now harbour-whatsapp-daemon.service"
                            globalNotice = "Disable command copied - paste in Terminal"
                            var p = downloadPrefs
                            p["daemon_autostart"] = "0"
                            downloadPrefs = p
                            setPref("daemon_autostart", "0")
                        }
                        Label {
                            id: disableCmdLabel
                            x: Theme.horizontalPageMargin
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - 2*Theme.horizontalPageMargin
                            wrapMode: Text.WrapAnywhere
                            font.pixelSize: Theme.fontSizeExtraSmall
                            font.family: "monospace"
                            color: Theme.primaryColor
                            text: "systemctl --user disable --now harbour-whatsapp-daemon.service"
                        }
                    }

                    SectionHeader { text: loc.autoDownloads }

                    Label {
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*x
                        text: loc.autoDownloadsNote
                        font.pixelSize: Theme.fontSizeExtraSmall
                        color: Theme.secondaryColor
                        wrapMode: Text.Wrap
                    }

                    BusyIndicator {
                        anchors.horizontalCenter: parent.horizontalCenter
                        running: !prefsReady
                        size: BusyIndicatorSize.Small
                    }

                    Repeater {
                        // Erst nach dem Prefs-Load instanziieren: die Boxen
                        // starten dann direkt mit den gespeicherten Werten
                        model: !prefsReady ? [] : [
                            { key: "image",    label: loc.images,           def: "always" },
                            { key: "sticker",  label: loc.stickers,         def: "always" },
                            { key: "video",    label: loc.videos,           def: "wifi" },
                            { key: "audio",    label: loc.audio,            def: "wifi" },
                            { key: "document", label: loc.documents,        def: "wifi" },
                            { key: "avatar",   label: loc.profilePictures, def: "always" }
                        ]
                        ComboBox {
                            id: adlBox
                            width: setCol.width
                            label: modelData.label
                            property string prefKey: "autodl_" + modelData.key
                            // KEIN Binding auf currentIndex: Silicas ComboBox
                            // weist currentIndex intern imperativ zu und
                            // zerstoert das Binding vor Eintreffen der async
                            // geladenen Prefs - die Anzeige blieb dann fuer
                            // immer auf dem Default haengen, obwohl das
                            // Backend den richtigen Wert hatte. Stattdessen
                            // imperative Synchronisation, sobald Daten da sind.
                            function syncFromPrefs() {
                                var v = downloadPrefs[prefKey] || modelData.def
                                currentIndex = v === "always" ? 0 : (v === "wifi" ? 1 : 2)
                            }
                            Component.onCompleted: syncFromPrefs()
                            Connections {
                                target: settingsPage
                                onDownloadPrefsChanged: adlBox.syncFromPrefs()
                            }
                            menu: ContextMenu {
                                MenuItem { text: loc.always }
                                MenuItem { text: loc.wifiOnly }
                                MenuItem { text: loc.never }
                            }
                            onCurrentIndexChanged: {
                                if (!prefsReady) return // Initialisierung/Sync, kein Nutzer-Input
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

                    SectionHeader { text: loc.storage }

                    Repeater {
                        id: storageRepeater
                        model: [
                            { key: "images",    label: loc.imagesStickers },
                            { key: "videos",    label: loc.videos },
                            { key: "audio",     label: loc.audio },
                            { key: "documents", label: loc.documents },
                            { key: "avatars",   label: loc.profilePictures }
                        ]
                        ListItem {
                            width: setCol.width
                            contentHeight: Theme.itemSizeSmall
                            menu: ContextMenu {
                                MenuItem {
                                    text: loc.deleteAll + " " + modelData.label.toLowerCase()
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
                        text: loc.storageNote
                        font.pixelSize: Theme.fontSizeExtraSmall
                        color: Theme.secondaryColor
                        wrapMode: Text.Wrap
                    }

                    SectionHeader { text: loc.sailjailHeader }

                    Label {
                        id: permStatus
                        property bool granted: false
                        property bool mediaGranted: false
                        property bool locationGranted: false
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*x
                        property bool micGranted: false
                        property bool sensorsGranted: false
                        property bool audioGranted: false
                        // Was der LAUFENDE Prozess darf - sailjail wendet
                        // ein Profil beim Start an, Datei und Wirklichkeit
                        // fallen zwischen Erteilen und Neustart auseinander
                        property bool mediaEffective: false
                        text: loc.permIntro + "\n\n"
                              + loc.contactsPerm + ": " + (granted ? loc.granted : loc.notGranted)
                              + "\n" + loc.mediaPerm + ": " + (mediaGranted ? loc.granted : loc.notGranted)
                              + "\n" + loc.locationPerm + ": " + (locationGranted ? loc.granted : loc.notGranted)
                              + "\n" + loc.micPerm + ": " + (micGranted ? loc.granted : loc.notGranted)
                              + "\n" + loc.audioPerm + ": " + (audioGranted ? loc.granted
                                    : (micGranted ? loc.includedInMic : loc.notGranted))
                              + "\n" + loc.sensorsPerm + ": " + (sensorsGranted ? loc.granted : loc.notGranted)
                              + "\n" + loc.earSpeaker + ": " + ((sensorsGranted && (audioGranted || micGranted)) ? loc.ready
                                  : (!sensorsGranted && !(audioGranted || micGranted)) ? loc.needsAudioSensors
                                  : !sensorsGranted ? loc.needsSensors : loc.needsAudio)
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
                                    locationGranted = p.locationPermission === true
                                    micGranted = p.micPermission === true
                                    sensorsGranted = p.sensorsPermission === true
                                    audioGranted = p.audioPermission === true
                                    mediaEffective = p.mediaAccessEffective === true
                                    // App-weite Kopien mitziehen, damit die
                                    // Sendefehler-Meldung denselben Stand hat
                                    mediaPermConfigured = mediaGranted
                                    mediaPermEffective = mediaEffective
                                    mediaPermMissing = (p.mediaMissing || []).join(", ")
                                }
                            }
                            xhr.send()
                        }
                    }

                    // Datei und laufender Prozess auseinander: beim Erteilen
                    // fehlt der Zugriff noch, beim Entziehen besteht er noch
                    // fort - letzteres ist der unangenehmere Fall, weil man
                    // annimmt, das Recht sei weg
                    Label {
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*x
                        visible: permStatus.mediaGranted !== permStatus.mediaEffective
                        text: permStatus.mediaGranted
                              ? loc.permPendingGrant : loc.permPendingRevoke
                        color: Theme.errorColor
                        font.pixelSize: Theme.fontSizeExtraSmall
                        wrapMode: Text.Wrap
                    }

                    BackgroundItem {
                        visible: permStatus.mediaGranted !== permStatus.mediaEffective
                                 && daemonRunning
                        width: parent.width
                        onClicked: {
                            var x = new XMLHttpRequest()
                            x.open("GET", "http://127.0.0.1:" + backendPort + "/daemon/restart")
                            x.onreadystatechange = function() {
                                if (x.readyState !== 4) return
                                globalNotice = (x.status === 200) ? loc.daemonRestarting
                                                                  : loc.daemonRestartFailed
                                if (x.status !== 200) noticeIsError = true
                            }
                            x.send()
                        }
                        Label {
                            x: Theme.horizontalPageMargin
                            anchors.verticalCenter: parent.verticalCenter
                            text: loc.restartServiceNow
                            color: parent.highlighted ? Theme.highlightColor : Theme.primaryColor
                        }
                    }

                    Label {
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*x
                        text: loc.sailjailDesc
                        font.pixelSize: Theme.fontSizeExtraSmall
                        color: Theme.secondaryColor
                        wrapMode: Text.Wrap
                    }

                    BackgroundItem {
                        width: parent.width
                        height: grantLabel.height + 2*Theme.paddingMedium
                        onClicked: {
                            Clipboard.text = "devel-su sed -i '/^Permissions=/{s/;*$/;/; /Contacts;/!s/$/Contacts;/; /Privileged;/!s/$/Privileged;/}' /usr/share/applications/harbour-whatsapp.desktop /usr/share/applications/harbour-whatsapp-daemon.desktop"
                            copiedHint.text = "Grant command copied - paste in Terminal"
                        }
                        Label {
                            id: grantLabel
                            x: Theme.horizontalPageMargin
                            width: parent.width - 2*x
                            wrapMode: Text.Wrap
                            anchors.verticalCenter: parent.verticalCenter
                            text: "\u25b8 " + loc.copyGrantContacts
                            color: Theme.highlightColor
                            font.pixelSize: Theme.fontSizeSmall
                        }
                    }

                    BackgroundItem {
                        width: parent.width
                        height: revokeLabel.height + 2*Theme.paddingMedium
                        onClicked: {
                            Clipboard.text = "devel-su sed -i '/^Permissions=/{s/Contacts;//g; s/Privileged;//g}' /usr/share/applications/harbour-whatsapp.desktop /usr/share/applications/harbour-whatsapp-daemon.desktop"
                            copiedHint.text = "Revoke command copied - paste in Terminal"
                        }
                        Label {
                            id: revokeLabel
                            x: Theme.horizontalPageMargin
                            width: parent.width - 2*x
                            wrapMode: Text.Wrap
                            anchors.verticalCenter: parent.verticalCenter
                            text: "\u25b8 " + loc.copyRevokeContacts
                            color: Theme.secondaryHighlightColor
                            font.pixelSize: Theme.fontSizeSmall
                        }
                    }

                    BackgroundItem {
                        width: parent.width
                        height: grantMediaLabel.height + 2*Theme.paddingMedium
                        onClicked: {
                            Clipboard.text = "devel-su sed -i '/^Permissions=/{s/;*$/;/; /UserDirs;/!s/$/UserDirs;/; /MediaIndexing;/!s/$/MediaIndexing;/; /RemovableMedia;/!s/$/RemovableMedia;/}' /usr/share/applications/harbour-whatsapp.desktop /usr/share/applications/harbour-whatsapp-daemon.desktop"
                            copiedHint.text = "Media grant command copied - paste in Terminal"
                        }
                        Label {
                            id: grantMediaLabel
                            x: Theme.horizontalPageMargin
                            width: parent.width - 2*x
                            wrapMode: Text.Wrap
                            anchors.verticalCenter: parent.verticalCenter
                            text: "\u25b8 " + loc.copyGrantMedia
                            color: Theme.highlightColor
                            font.pixelSize: Theme.fontSizeSmall
                        }
                    }

                    BackgroundItem {
                        width: parent.width
                        height: revokeMediaLabel.height + 2*Theme.paddingMedium
                        onClicked: {
                            Clipboard.text = "devel-su sed -i '/^Permissions=/{s/UserDirs;//g; s/MediaIndexing;//g; s/RemovableMedia;//g}' /usr/share/applications/harbour-whatsapp.desktop /usr/share/applications/harbour-whatsapp-daemon.desktop"
                            copiedHint.text = "Media revoke command copied - paste in Terminal"
                        }
                        Label {
                            id: revokeMediaLabel
                            x: Theme.horizontalPageMargin
                            width: parent.width - 2*x
                            wrapMode: Text.Wrap
                            anchors.verticalCenter: parent.verticalCenter
                            text: "\u25b8 " + loc.copyRevokeMedia
                            color: Theme.secondaryHighlightColor
                            font.pixelSize: Theme.fontSizeSmall
                        }
                    }

                    BackgroundItem {
                        width: parent.width
                        height: grantLocLabel.height + 2*Theme.paddingMedium
                        onClicked: {
                            Clipboard.text = "devel-su sed -i '/^Permissions=/{s/;*$/;/; /Location;/!s/$/Location;/}' /usr/share/applications/harbour-whatsapp.desktop /usr/share/applications/harbour-whatsapp-daemon.desktop"
                            copiedHint.text = "Location grant command copied - paste in Terminal, then restart the app"
                        }
                        Label {
                            id: grantLocLabel
                            x: Theme.horizontalPageMargin
                            width: parent.width - 2*x
                            wrapMode: Text.Wrap
                            anchors.verticalCenter: parent.verticalCenter
                            text: "\u25b8 " + loc.copyGrantLocation
                            color: Theme.highlightColor
                            font.pixelSize: Theme.fontSizeSmall
                        }
                    }

                    BackgroundItem {
                        width: parent.width
                        height: revokeLocLabel.height + 2*Theme.paddingMedium
                        onClicked: {
                            Clipboard.text = "devel-su sed -i '/^Permissions=/{s/Location;//g}' /usr/share/applications/harbour-whatsapp.desktop /usr/share/applications/harbour-whatsapp-daemon.desktop"
                            copiedHint.text = "Location revoke command copied - paste in Terminal"
                        }
                        Label {
                            id: revokeLocLabel
                            x: Theme.horizontalPageMargin
                            width: parent.width - 2*x
                            wrapMode: Text.Wrap
                            anchors.verticalCenter: parent.verticalCenter
                            text: "\u25b8 " + loc.copyRevokeLocation
                            color: Theme.secondaryHighlightColor
                            font.pixelSize: Theme.fontSizeSmall
                        }
                    }

                    BackgroundItem {
                        width: parent.width
                        height: grantMicLabel.height + 2*Theme.paddingMedium
                        onClicked: {
                            Clipboard.text = "devel-su sed -i '/^Permissions=/{s/;*$/;/; /Microphone;/!s/$/Microphone;/}' /usr/share/applications/harbour-whatsapp.desktop /usr/share/applications/harbour-whatsapp-daemon.desktop"
                            copiedHint.text = "Microphone grant command copied - paste in Terminal, then restart the app"
                        }
                        Label {
                            id: grantMicLabel
                            x: Theme.horizontalPageMargin
                            width: parent.width - 2*x
                            wrapMode: Text.Wrap
                            anchors.verticalCenter: parent.verticalCenter
                            text: "\u25b8 " + loc.copyGrantMic
                            color: Theme.highlightColor
                            font.pixelSize: Theme.fontSizeSmall
                        }
                    }

                    BackgroundItem {
                        width: parent.width
                        height: revokeMicLabel.height + 2*Theme.paddingMedium
                        onClicked: {
                            Clipboard.text = "devel-su sed -i '/^Permissions=/{s/Microphone;//g}' /usr/share/applications/harbour-whatsapp.desktop /usr/share/applications/harbour-whatsapp-daemon.desktop"
                            copiedHint.text = "Microphone revoke command copied - paste in Terminal"
                        }
                        Label {
                            id: revokeMicLabel
                            x: Theme.horizontalPageMargin
                            width: parent.width - 2*x
                            wrapMode: Text.Wrap
                            anchors.verticalCenter: parent.verticalCenter
                            text: "\u25b8 " + loc.copyRevokeMic
                            color: Theme.secondaryHighlightColor
                            font.pixelSize: Theme.fontSizeSmall
                        }
                    }

                    BackgroundItem {
                        width: parent.width
                        height: grantSensLabel.height + 2*Theme.paddingMedium
                        onClicked: {
                            Clipboard.text = "devel-su sed -i '/^Permissions=/{s/;*$/;/; /Audio;/!s/$/Audio;/; /Sensors;/!s/$/Sensors;/}' /usr/share/applications/harbour-whatsapp.desktop /usr/share/applications/harbour-whatsapp-daemon.desktop"
                            copiedHint.text = "Audio+Sensors grant command copied - paste in Terminal, then restart the app"
                        }
                        Label {
                            id: grantSensLabel
                            x: Theme.horizontalPageMargin
                            width: parent.width - 2*x
                            wrapMode: Text.Wrap
                            anchors.verticalCenter: parent.verticalCenter
                            text: "\u25b8 " + loc.copyGrantAudioSensors
                            color: Theme.highlightColor
                            font.pixelSize: Theme.fontSizeSmall
                        }
                    }

                    BackgroundItem {
                        width: parent.width
                        height: revokeSensLabel.height + 2*Theme.paddingMedium
                        onClicked: {
                            Clipboard.text = "devel-su sed -i '/^Permissions=/{s/Audio;//g; s/Sensors;//g}' /usr/share/applications/harbour-whatsapp.desktop /usr/share/applications/harbour-whatsapp-daemon.desktop"
                            copiedHint.text = "Audio+Sensors revoke command copied - paste in Terminal"
                        }
                        Label {
                            id: revokeSensLabel
                            x: Theme.horizontalPageMargin
                            width: parent.width - 2*x
                            wrapMode: Text.Wrap
                            anchors.verticalCenter: parent.verticalCenter
                            text: "\u25b8 " + loc.copyRevokeAudioSensors
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
            allowedOrientations: orientationMask()
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

                    PageHeader { title: loc.profileTitle }

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
                        label: loc.name
                        placeholderText: loc.yourName
                    }

                    TextField {
                        id: aboutField
                        width: parent.width
                        label: loc.about
                        placeholderText: loc.aboutPlaceholder
                    }

                    Button {
                        text: loc.save
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
                        text: loc.changeProfilePhoto
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
                        text: loc.profileNote
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
            allowedOrientations: orientationMask()
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

                    DialogHeader { title: loc.createPoll }

                    TextField {
                        id: cpName
                        width: parent.width
                        label: loc.question
                        placeholderText: loc.askSomething
                    }

                    Repeater {
                        model: cpDialog.optionTexts.length
                        TextField {
                            width: cpCol.width
                            label: loc.option + " " + (index + 1)
                            placeholderText: loc.option + " " + (index + 1)
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
                        text: loc.addOption
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
                        text: loc.allowMultiple
                    }
                }
            }
        }
    }

    Component {
        id: addParticipantsPage
        Dialog {
            allowedOrientations: orientationMask()
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
                DialogHeader { title: loc.addParticipants }
                SearchField {
                    id: apSearchField
                    width: parent.width
                    placeholderText: loc.searchContacts
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
                xhr.onreadystatechange = function() {
                    if (xhr.readyState !== 4) return
                    if (xhr.status === 200) {
                        globalNotice = "Group photo updated"
                    } else {
                        // Haeufigste Ursache: Sailjail verweigert dem Backend
                        // das Lesen aus ~/Pictures ohne Medien-Berechtigung
                        globalNotice = "Group photo failed: " + xhr.responseText
                                     + (xhr.responseText.indexOf("permission") >= 0 || xhr.status === 400
                                        ? " - grant the media storage permission in Settings and restart the app"
                                        : "")
                    }
                }
                xhr.send()
            }
        }
    }

    Component {
        id: groupInfoPage
        Page {
            allowedOrientations: orientationMask()
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

            SilicaListView {
                anchors.fill: parent
                model: participants
                // Delegates werden virtualisiert: nur die sichtbaren ~10
                // existieren, egal ob die Gruppe 8 oder 800 Mitglieder hat
                delegate: ListItem {
                    width: ListView.view.width
                    contentHeight: Theme.itemSizeMedium
                            // Kurzer Tipp oeffnet den Einzelchat, langer Druck
                            // das Menue - Silica trennt beides von selbst, wie
                            // bei den Favoriten laengst ueblich. Wunsch von
                            // kempertom. Die eigene Nummer ist ausdruecklich
                            // NICHT ausgenommen: "Nachricht an mich" ist ein
                            // gewollter Anwendungsfall
                            onClicked: pageStack.push(chatPage, {
                                chatJid: modelData.number,
                                chatName: getDisplayName(modelData.number, modelData.name)
                            })
                            // Menue als Component: wird erst beim Long-Press
                            // instanziiert statt 80x beim Seitenaufbau
                            menu: Component {
                                ContextMenu {
                                    MenuItem {
                                        text: loc.call + " +" + modelData.number
                                        onClicked: Qt.openUrlExternally("tel:+" + modelData.number)
                                    }
                                    MenuItem {
                                        text: modelData.isAdmin ? loc.removeAdmin : loc.makeAdmin
                                        onClicked: groupCall("/group/participants?chat=" + giPage.groupJid
                                                   + "&action=" + (modelData.isAdmin ? "demote" : "promote")
                                                   + "&numbers=" + modelData.number)
                                    }
                                    MenuItem {
                                        text: loc.removeFromGroup
                                        onClicked: groupCall("/group/participants?chat=" + giPage.groupJid + "&action=remove&numbers=" + modelData.number)
                                    }
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

                PullDownMenu {
                    MenuItem {
                        text: loc.leaveGroup
                        onClicked: leaveRemorse.execute("Leaving group", function() {
                            groupCall("/group/leave?chat=" + groupJid, function() { pageStack.pop(pageStack.previousPage()) })
                        })
                    }
                    MenuItem {
                        text: loc.changeGroupPhoto
                        onClicked: pageStack.push(groupPhotoPicker, { groupJid: groupJid })
                    }
                    MenuItem {
                        text: loc.getInviteLink
                        onClicked: groupCall("/group/invitelink?chat=" + groupJid, function(xhr) {
                            if (xhr.status === 200) {
                                inviteLink = JSON.parse(xhr.responseText).link
                                Clipboard.text = inviteLink
                                giStatus = loc.linkCopied
                            }
                        })
                    }
                    MenuItem {
                        text: loc.joinRequests
                        onClicked: pageStack.push(joinRequestsPage, { groupJid: groupJid })
                    }
                    MenuItem {
                        text: loc.setDescription
                        onClicked: {
                            var dlg = pageStack.push(groupDescDialog)
                            dlg.accepted.connect(function() {
                                groupCall("/group/desc?jid=" + groupJid + "&text=" + encodeURIComponent(dlg.descText))
                            })
                        }
                    }
                }

                RemorsePopup { id: leaveRemorse }
                VerticalScrollDecorator {}

                header: Column {
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
                            text: giPage.groupName
                            width: parent.width - renameBtn.width - Theme.paddingMedium
                            label: loc.groupName
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
                            label: loc.addParticipant
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
                        text: loc.addFromContacts
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
                        text: loc.communityGroups + " (" + subgroups.length + ")"
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

                    SectionHeader { text: loc.participantsHdr + " (" + participants.length + ")" }

                }
            }
        }
    }

    Component {
        id: statusPostDialog
        Dialog {
            allowedOrientations: orientationMask()
            property string statusText: textArea.text
            property string statusBg: bgRepeater.model[bgRow.selected]
            canAccept: textArea.text.trim().length > 0
            Column {
                width: parent.width
                DialogHeader { title: loc.postStatus }
                TextArea {
                    id: textArea
                    width: parent.width
                    placeholderText: loc.statusPlaceholder
                    label: loc.statusPrivacyNote
                }
                Label {
                    x: Theme.horizontalPageMargin
                    text: loc.background
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

    // Rechts-Wisch-Kette (Wurzel-Trick): der Stack startet mit
    // Archive -> Favorites -> Chatliste (beim Start sofort durchgeschoben).
    // Rechts wischen von der Liste = Favorites, nochmal = Archive; die
    // Seiten sind persistente Items, weil Silica beim Zurueck-Wischen
    // Component-Seiten zerstoeren wuerde. Links bleibt der Status.
    Page {
        allowedOrientations: orientationMask()
        id: favPageItem
        onStatusChanged: {
            if (status !== PageStatus.Active) return
            pageStack.pushAttached(mainPage)
            // Kettenglied fuer Spruenge aus dem Archiv Richtung Chats/Status
            if (navJumpTarget >= 2) {
                var last = (navJumpTarget === 2)
                if (last) navJumpTarget = -1
                pageStack.navigateForward(last ? PageStackAction.Animated
                                               : PageStackAction.Immediate)
            }
        }

        Loader {
            id: favNav
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            z: 10   // vor der Liste, falls doch etwas darueber hinausragt
            // itemSizeExtraSmall war als Tippziel zu knapp - man trifft daneben
            // und landet in der Liste darueber (rdomschk). Die Beschriftung
            // ist seit 0.9.217 groesser, die Flaeche war es noch nicht
            height: (connected && showNavBar) ? navBarHeight() : 0
            visible: connected && showNavBar
            sourceComponent: navBarComp
            onLoaded: item.activeIndex = 1
        }

        SilicaListView {
            // OHNE clip zeichnet eine ListView ihre Eintraege ueber die
            // eigenen Grenzen hinaus - und diese Eintraege nehmen auch
            // Beruehrungen entgegen. Der letzte Chat lag damit HINTER der
            // Bodenleiste und fing den Tipp ab, egal wie hoch sie war.
            clip: true
            anchors { left: parent.left; right: parent.right; top: parent.top; bottom: favNav.top }
            header: PageHeader { title: loc.favorites }
            model: chats.filter(function(c) { return c.pinned === true })

            ViewPlaceholder {
                enabled: parent.count === 0
                text: loc.noFavorites
                hintText: loc.noFavoritesHint
            }

            delegate: ListItem {
                width: ListView.view.width
                contentHeight: Theme.itemSizeMedium
                menu: ContextMenu {
                    MenuItem {
                        text: loc.removeFav
                        onClicked: chatSettingFor(modelData.jid, "unpin")
                    }
                    MenuItem {
                        text: (modelData.muted ? loc.unmute : loc.mute)
                        onClicked: chatSettingFor(modelData.jid, modelData.muted ? "unmute" : "mute")
                    }
                    MenuItem {
                        text: loc.archiveAction
                        onClicked: chatSettingFor(modelData.jid, "archive")
                    }
                }
                onClicked: pageStack.push(chatPage, {
                    chatJid: modelData.jid,
                    chatName: getDisplayName(modelData.jid, modelData.name),
                    chatAvatar: modelData.avatar || "",
                    isChannel: modelData.isChannel === true
                })

                Image {
                    id: favAvatar
                    x: Theme.horizontalPageMargin
                    anchors.verticalCenter: parent.verticalCenter
                    width: Theme.itemSizeSmall
                    height: Theme.itemSizeSmall
                    source: modelData.avatar || ""
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                }

                Column {
                    anchors.left: favAvatar.right
                    anchors.leftMargin: Theme.paddingMedium
                    anchors.right: favBadge.left
                    anchors.rightMargin: Theme.paddingMedium
                    anchors.verticalCenter: parent.verticalCenter

                    Label {
                        width: parent.width
                        text: getDisplayName(modelData.jid, modelData.name)
                        truncationMode: TruncationMode.Fade
                        color: highlighted ? Theme.highlightColor : Theme.primaryColor
                    }
                    Label {
                        width: parent.width
                        text: locMsg(modelData.lastMessage) || ""
                        truncationMode: TruncationMode.Fade
                        font.pixelSize: Theme.fontSizeExtraSmall
                        color: Theme.secondaryColor
                    }
                }

                Rectangle {
                    id: favBadge
                    visible: (modelData.unread || 0) > 0
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.horizontalPageMargin
                    anchors.verticalCenter: parent.verticalCenter
                    width: favBadgeLbl.width + Theme.paddingMedium
                    height: favBadgeLbl.height + Theme.paddingSmall
                    radius: height / 2
                    color: Theme.highlightBackgroundColor
                    Label {
                        id: favBadgeLbl
                        anchors.centerIn: parent
                        text: modelData.unread || ""
                        font.pixelSize: Theme.fontSizeExtraSmall
                        font.bold: true
                    }
                }
            }
        }
    }

    Page {
        allowedOrientations: orientationMask()
        id: archPageItem
        property bool stackBuilt: false
        onStatusChanged: {
            if (status !== PageStatus.Active) return
            if (!stackBuilt) {
                stackBuilt = true
                pageStack.push(favPageItem, {}, PageStackAction.Immediate)
                pageStack.push(mainPage, {}, PageStackAction.Immediate)
            } else {
                pageStack.pushAttached(favPageItem)
            }
        }

        Loader {
            id: archNav
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            z: 10   // vor der Liste, falls doch etwas darueber hinausragt
            // itemSizeExtraSmall war als Tippziel zu knapp - man trifft daneben
            // und landet in der Liste darueber (rdomschk). Die Beschriftung
            // ist seit 0.9.217 groesser, die Flaeche war es noch nicht
            height: (connected && showNavBar) ? navBarHeight() : 0
            visible: connected && showNavBar
            sourceComponent: navBarComp
            onLoaded: item.activeIndex = 0
        }

        SilicaListView {
            anchors { left: parent.left; right: parent.right; top: parent.top; bottom: archNav.top }
            header: PageHeader { title: loc.archive }
            model: chats.filter(function(c) { return c.archived === true })

            ViewPlaceholder {
                enabled: parent.count === 0
                text: loc.noArchived
                hintText: loc.noArchivedHint
            }

            delegate: ListItem {
                width: ListView.view.width
                contentHeight: Theme.itemSizeMedium
                menu: ContextMenu {
                    MenuItem {
                        text: loc.unarchiveAction
                        onClicked: chatSettingFor(modelData.jid, "unarchive")
                    }
                    MenuItem {
                        text: (modelData.muted ? loc.unmute : loc.mute)
                        onClicked: chatSettingFor(modelData.jid, modelData.muted ? "unmute" : "mute")
                    }
                    MenuItem {
                        text: (modelData.pinned ? loc.removeFav : loc.addFav)
                        onClicked: chatSettingFor(modelData.jid, modelData.pinned ? "unpin" : "pin")
                    }
                }
                onClicked: pageStack.push(chatPage, {
                    chatJid: modelData.jid,
                    chatName: getDisplayName(modelData.jid, modelData.name),
                    chatAvatar: modelData.avatar || "",
                    isChannel: modelData.isChannel === true
                })

                Image {
                    id: arcAvatar
                    x: Theme.horizontalPageMargin
                    anchors.verticalCenter: parent.verticalCenter
                    width: Theme.itemSizeSmall
                    height: Theme.itemSizeSmall
                    source: modelData.avatar || ""
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                }

                Column {
                    anchors.left: arcAvatar.right
                    anchors.leftMargin: Theme.paddingMedium
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.horizontalPageMargin
                    anchors.verticalCenter: parent.verticalCenter

                    Label {
                        width: parent.width
                        text: getDisplayName(modelData.jid, modelData.name)
                        truncationMode: TruncationMode.Fade
                        color: highlighted ? Theme.highlightColor : Theme.primaryColor
                    }
                    Label {
                        width: parent.width
                        text: locMsg(modelData.lastMessage) || ""
                        truncationMode: TruncationMode.Fade
                        font.pixelSize: Theme.fontSizeExtraSmall
                        color: Theme.secondaryColor
                    }
                }
            }
        }
    }

    // Kontakt-Info als attached page am Chat (Glow-Punkt rechts oben):
    // grosses Profilbild (der Avatar-Cache haelt bereits das Vollbild),
    // Nummer/About bei Kontakten, Topic/Mitgliederzahl bei Gruppen
    Component {
        id: avatarViewerPage
        Page {
            property string imgSource: ""
            allowedOrientations: Orientation.All
            Rectangle { anchors.fill: parent; color: "black" }
            Image {
                anchors.fill: parent
                fillMode: Image.PreserveAspectFit
                source: imgSource
                asynchronous: true
            }
            MouseArea { anchors.fill: parent; onClicked: pageStack.pop() }
        }
    }

    Component {
        id: contactInfoPage
        Page {
            allowedOrientations: orientationMask()
            id: ciPage
            property string jid: ""
            property string name: ""
            property string avatar: ""
            property bool group: false
            property bool channel: false
            property var info: ({})
            property bool infoLoaded: false
            property var mediaMsgs: []
            property var linkMsgs: []
            property var docMsgs: []
            property var groupMembers: []

            // "Medien, Links, Doks" wie in WhatsApp (tom_i-Wunsch):
            // volle Historie holen und client-seitig sortieren
            function loadMedia() {
                var xhr = new XMLHttpRequest()
                xhr.open("GET", "http://127.0.0.1:" + backendPort + "/messages?jid=" + jid)
                xhr.onreadystatechange = function() {
                    if (xhr.readyState !== 4 || xhr.status !== 200) return
                    var list = []
                    try { list = JSON.parse(xhr.responseText) || [] } catch (e) {}
                    var med = [], docs = [], links = []
                    for (var i = list.length - 1; i >= 0; i--) {  // neueste zuerst
                        var m = list[i]
                        if (m.revoked) continue
                        if (m.mediaType === "image" || m.mediaType === "video") med.push(m)
                        else if (m.mediaType === "document" || m.mediaType === "audio") docs.push(m)
                        else if (m.text && m.text.match(/https?:\/\/|www\./)) links.push(m)
                    }
                    ciPage.mediaMsgs = med
                    ciPage.docMsgs = docs
                    ciPage.linkMsgs = links
                }
                xhr.send()
            }

            function loadParticipants() {
                var xhr = new XMLHttpRequest()
                xhr.open("GET", "http://127.0.0.1:" + backendPort + "/group/info?chat=" + jid)
                xhr.onreadystatechange = function() {
                    if (xhr.readyState !== 4 || xhr.status !== 200) return
                    try {
                        var d = JSON.parse(xhr.responseText)
                        ciPage.groupMembers = (d.participants || []).slice(0, 100)
                    } catch (e) {}
                }
                xhr.send()
            }

            property string inviteLink: ""

            // Gleiche Endpoints wie die Gruppeninfo-Seite - Verwaltung
            // direkt auf der Info-Seite (Langdruck auf Teilnehmer)
            function groupCall(params, cb) {
                var xhr = new XMLHttpRequest()
                xhr.open("GET", "http://127.0.0.1:" + backendPort + params)
                xhr.onreadystatechange = function() {
                    if (xhr.readyState === 4) {
                        if (cb) cb(xhr)
                        loadParticipants()
                    }
                }
                xhr.send()
            }

            Component.onCompleted: {
                var xhr = new XMLHttpRequest()
                xhr.open("GET", "http://127.0.0.1:" + backendPort + "/userinfo?jid=" + jid)
                xhr.onreadystatechange = function() {
                    if (xhr.readyState !== 4) return
                    if (xhr.status === 200) {
                        try { ciPage.info = JSON.parse(xhr.responseText) } catch (e) {}
                    }
                    ciPage.infoLoaded = true
                }
                xhr.send()
                loadMedia()
                if (group) loadParticipants()
            }

            SilicaFlickable {
                anchors.fill: parent
                contentHeight: ciCol.height

                PullDownMenu {
                    // Bisher hatte diese Seite NUR fuer Gruppen ein Menue - bei einem
                    // Kontakt fehlte jeder Einstieg, obwohl dort die Nummer steht,
                    // die man anrufen will
                    visible: ciPage.jid !== "status"

                    MenuItem {
                        text: loc.call + " +" + ciPage.jid
                        visible: !ciPage.group
                        onClicked: Qt.openUrlExternally("tel:+" + ciPage.jid)
                    }

                    MenuItem {
                        visible: ciPage.group
                        text: loc.groupInfo
                        onClicked: pageStack.push(groupInfoPage, { groupJid: ciPage.jid })
                    }
                    MenuItem {
                        visible: ciPage.group
                        text: loc.getInviteLink
                        onClicked: ciPage.groupCall("/group/invitelink?chat=" + ciPage.jid, function(xhr) {
                            if (xhr.status === 200) {
                                try { ciPage.inviteLink = JSON.parse(xhr.responseText).link } catch (e) {}
                                Clipboard.text = ciPage.inviteLink
                            }
                        })
                    }
                    MenuItem {
                        visible: ciPage.group
                        text: loc.leaveGroup
                        onClicked: ciPage.groupCall("/group/leave?chat=" + ciPage.jid, function() {
                            pageStack.pop(mainPage)
                        })
                    }
                }

                Column {
                    id: ciCol
                    width: parent.width
                    spacing: Theme.paddingLarge

                    PageHeader { title: ciPage.name }

                    Image {
                        visible: ciPage.avatar !== ""
                        width: parent.width - 2 * Theme.horizontalPageMargin
                        height: width
                        anchors.horizontalCenter: parent.horizontalCenter
                        source: ciPage.avatar
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true

                        MouseArea {
                            anchors.fill: parent
                            onClicked: pageStack.push(avatarViewerPage,
                                                      { imgSource: ciPage.avatar })
                        }
                    }

                    Label {
                        visible: ciPage.avatar === ""
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: loc.noProfilePicture
                        color: Theme.secondaryColor
                    }

                    Label {
                        visible: !ciPage.group && !ciPage.channel
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*x
                        text: "+" + ciPage.jid
                        font.pixelSize: Theme.fontSizeLarge
                        color: Theme.highlightColor
                    }

                    Label {
                        visible: (ciPage.info.status || "") !== ""
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*x
                        text: ciPage.info.status || ""
                        wrapMode: Text.Wrap
                        color: Theme.primaryColor
                    }

                    Label {
                        visible: ciPage.group && (ciPage.info.topic || "") !== ""
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*x
                        text: ciPage.info.topic || ""
                        wrapMode: Text.Wrap
                        color: Theme.primaryColor
                    }

                    Label {
                        visible: ciPage.group && ciPage.info.participants !== undefined
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*x
                        text: (ciPage.info.participants || 0) + " " + loc.participants
                        color: Theme.secondaryColor
                    }

                    Label {
                        visible: ciPage.inviteLink !== ""
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*x
                        text: ciPage.inviteLink
                        wrapMode: Text.WrapAnywhere
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.highlightColor
                    }

                    SectionHeader {
                        visible: ciPage.group && ciPage.groupMembers.length > 0
                        text: loc.participantsHdr
                    }

                    Column {
                        visible: ciPage.group && ciPage.groupMembers.length > 0
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*x
                        Repeater {
                            model: ciPage.groupMembers
                            delegate: ListItem {
                                width: parent.width
                                contentHeight: Theme.itemSizeExtraSmall
                                // Gleiches Verhalten wie in der Gruppeninfo -
                                // zwei Listen mit denselben Eintraegen duerfen
                                // sich nicht unterschiedlich anfuehlen
                                onClicked: pageStack.push(chatPage, {
                                    chatJid: modelData.number,
                                    chatName: getDisplayName(modelData.number, modelData.name)
                                })
                                menu: Component {
                                    ContextMenu {
                                        MenuItem {
                                            text: loc.call + " +" + modelData.number
                                            onClicked: Qt.openUrlExternally("tel:+" + modelData.number)
                                        }
                                        MenuItem {
                                            text: modelData.isAdmin ? loc.removeAdmin : loc.makeAdmin
                                            onClicked: ciPage.groupCall("/group/participants?chat=" + ciPage.jid
                                                       + "&action=" + (modelData.isAdmin ? "demote" : "promote")
                                                       + "&numbers=" + modelData.number)
                                        }
                                        MenuItem {
                                            text: loc.removeFromGroup
                                            onClicked: ciPage.groupCall("/group/participants?chat=" + ciPage.jid
                                                       + "&action=remove&numbers=" + modelData.number)
                                        }
                                    }
                                }
                                Label {
                                    width: parent.width
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: getDisplayName(modelData.number, modelData.name)
                                          + (modelData.isAdmin ? " \u2605" : "")
                                    font.pixelSize: Theme.fontSizeSmall
                                    truncationMode: TruncationMode.Fade
                                    color: Theme.primaryColor
                                }
                            }
                        }
                    }

                    SectionHeader {
                        visible: ciPage.mediaMsgs.length > 0
                        text: loc.media
                    }

                    Grid {
                        visible: ciPage.mediaMsgs.length > 0
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*x
                        columns: 3
                        spacing: Theme.paddingSmall

                        Repeater {
                            model: ciPage.mediaMsgs
                            delegate: Rectangle {
                                width: (parent.width - 2*Theme.paddingSmall) / 3
                                height: width
                                color: Theme.rgba(Theme.primaryColor, 0.15)
                                radius: Theme.paddingSmall

                                Image {
                                    anchors.fill: parent
                                    anchors.margins: 1
                                    fillMode: Image.PreserveAspectCrop
                                    asynchronous: true
                                    sourceSize.width: 256
                                    source: (modelData.mediaType === "image" && modelData.localPath)
                                            ? "file://" + modelData.localPath : ""
                                }

                                Label {
                                    anchors.centerIn: parent
                                    visible: modelData.mediaType === "video" || !modelData.localPath
                                    text: !modelData.localPath ? "\u2b07"
                                        : "\u25b6"
                                    font.pixelSize: Theme.fontSizeExtraLarge
                                    color: Theme.primaryColor
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: {
                                        if (modelData.localPath) {
                                            Qt.openUrlExternally("file://" + modelData.localPath)
                                        } else {
                                            var xhr = new XMLHttpRequest()
                                            xhr.open("GET", "http://127.0.0.1:" + backendPort
                                                     + "/download?id=" + encodeURIComponent(modelData.id))
                                            xhr.onreadystatechange = function() {
                                                if (xhr.readyState === 4) ciPage.loadMedia()
                                            }
                                            xhr.send()
                                        }
                                    }
                                }
                            }
                        }
                    }

                    SectionHeader {
                        visible: ciPage.linkMsgs.length > 0
                        text: loc.links
                    }

                    Column {
                        visible: ciPage.linkMsgs.length > 0
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*x
                        spacing: Theme.paddingMedium
                        Repeater {
                            model: ciPage.linkMsgs
                            delegate: Label {
                                width: parent.width
                                text: linkify(modelData.text)
                                textFormat: Text.StyledText
                                linkColor: Theme.highlightColor
                                onLinkActivated: Qt.openUrlExternally(link)
                                wrapMode: Text.Wrap
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.primaryColor
                            }
                        }
                    }

                    SectionHeader {
                        visible: ciPage.docMsgs.length > 0
                        text: loc.documents
                    }

                    Column {
                        visible: ciPage.docMsgs.length > 0
                        width: parent.width
                        Repeater {
                            model: ciPage.docMsgs
                            delegate: BackgroundItem {
                                width: parent.width
                                height: Theme.itemSizeSmall
                                onClicked: {
                                    if (modelData.localPath) {
                                        Qt.openUrlExternally("file://" + modelData.localPath)
                                    } else {
                                        var xhr = new XMLHttpRequest()
                                        xhr.open("GET", "http://127.0.0.1:" + backendPort
                                                 + "/download?id=" + encodeURIComponent(modelData.id))
                                        xhr.onreadystatechange = function() {
                                            if (xhr.readyState === 4) ciPage.loadMedia()
                                        }
                                        xhr.send()
                                    }
                                }
                                Label {
                                    x: Theme.horizontalPageMargin
                                    width: parent.width - 2*x
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: (modelData.mediaType === "audio" ? "\ud83c\udfb5 " : "\ud83d\udcc4 ")
                                          + (modelData.text || modelData.mediaType)
                                          + (modelData.localPath ? "" : "  \u2b07")
                                    truncationMode: TruncationMode.Fade
                                    font.pixelSize: Theme.fontSizeSmall
                                }
                            }
                        }
                    }

                    BusyIndicator {
                        anchors.horizontalCenter: parent.horizontalCenter
                        size: BusyIndicatorSize.Small
                        running: !ciPage.infoLoaded
                    }
                }
            }
        }
    }

    Component {
        id: statusPage
        Page {
            allowedOrientations: orientationMask()
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
                        // Nach Person gruppieren: wer ein ganzes Fotoalbum
                        // postet, schob sonst alle anderen aus der Liste.
                        // Innerhalb einer Person bleibt es zeitlich sortiert,
                        // die Personen selbst nach ihrer neuesten Meldung.
                        // Stummgeschaltete Personen gar nicht erst aufnehmen
                        list = list.filter(function(m) {
                            return m.fromMe === true || !isStatusMuted(m.sender)
                        })

                        var order = [], byUser = {}
                        if (!statusGrouping) {
                            for (var q = 0; q < list.length; q++) {
                                list[q].groupHead = true
                                list[q].groupCount = 1
                                list[q].groupIndex = 1
                            }
                        }
                        for (var i = 0; i < list.length; i++) {
                            var k = list[i].sender || "?"
                            if (!byUser[k]) { byUser[k] = []; order.push(k) }
                            byUser[k].push(list[i])
                        }
                        var grouped = []
                        for (var j = 0; j < order.length; j++) {
                            var g = byUser[order[j]]
                            for (var n = 0; n < g.length; n++) {
                                // Erster Eintrag einer Person traegt die
                                // Ueberschrift, die uebrigen zaehlen mit
                                g[n].groupHead = (n === 0)
                                g[n].groupCount = g.length
                                g[n].groupIndex = n + 1
                                grouped.push(g[n])
                            }
                        }
                        if (statusGrouping) list = grouped
                        statuses = list
                        // Wer die Seite gerade offen hat, sieht sie ja - sonst
                        // nur zaehlen, damit die Kachel es anzeigen kann
                        if (status === PageStatus.Active) markStatusSeen(list)
                        else recomputeStatusUnread(list)
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
                    title: loc.selectImageVideo
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
                    allowedOrientations: orientationMask()
                    property string mediaPath: ""
                    property string captionText: captionArea.text
                    canAccept: true // Caption ist optional
                    Column {
                        width: parent.width
                        DialogHeader {
                            title: loc.postToStatus
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
                            placeholderText: loc.captionPlaceholder
                            label: loc.caption
                        }
                    }
                }
            }

            onStatusChanged: {
                if (status === PageStatus.Active) {
                    loadStatuses()
                    markStatusSeen(statuses)
                }
            }
            Component.onCompleted: loadStatuses()

            Loader {
                id: stNav
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            z: 10   // vor der Liste, falls doch etwas darueber hinausragt
                // itemSizeExtraSmall war als Tippziel zu knapp - man trifft daneben
            // und landet in der Liste darueber (rdomschk). Die Beschriftung
            // ist seit 0.9.217 groesser, die Flaeche war es noch nicht
            height: (connected && showNavBar) ? navBarHeight() : 0
                visible: connected && showNavBar
                sourceComponent: navBarComp
                onLoaded: item.activeIndex = 3
            }

            SilicaListView {
                // OHNE clip zeichnet eine ListView ihre Eintraege ueber die
                // eigenen Grenzen hinaus - und diese Eintraege nehmen auch
                // Beruehrungen entgegen. Der letzte Chat lag damit HINTER der
                // Bodenleiste und fing den Tipp ab, egal wie hoch sie war.
                clip: true
                anchors { left: parent.left; right: parent.right; top: parent.top; bottom: stNav.top }
                // Je nach Einstellung eine Zeile pro Person oder alle
                // Beitraege untereinander. Der Delegate entscheidet sich am
                // selben Schalter, damit nur EINE Liste zu pflegen ist.
                model: statusByPerson ? statusPeople() : statuses

                PullDownMenu {
                    MenuItem { text: loc.refresh; onClicked: loadStatuses() }
                    MenuItem {
                        text: loc.muteStatusPeople
                        onClicked: pageStack.push(statusMutePage)
                    }
                    MenuItem {
                        text: loc.postImageVideo
                        onClicked: pageStack.push(statusMediaPicker)
                    }
                    MenuItem {
                        text: loc.postStatus
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

                header: PageHeader { title: loc.statusUpdates }

                ViewPlaceholder {
                    // Ohne diesen Hinweis wirkt die leere Liste wie ein Fehler
                    enabled: statuses.length === 0 && hideOnline
                    text: loc.statusHiddenTitle
                    hintText: loc.statusHiddenHint
                }

                // Der Delegate war eine schlichte Column. Fuer den langen
                // Druck braucht es ein ListItem - die Column bleibt darin
                // unveraendert, damit am Aufbau nichts kaputtgeht. Die Hoehe
                // muss ausdruecklich mitwachsen, ein ListItem hat sonst seine
                // Standardhoehe und die Eintraege ueberlappen.
                delegate: statusByPerson ? personRowDelegate : statusPostDelegate

                Component {
                    id: personRowDelegate
                    ListItem {
                        width: ListView.view.width
                        contentHeight: Theme.itemSizeLarge
                        onClicked: pageStack.push(personStatusPage, {
                            personJid: modelData.sender
                        })
                        menu: Component {
                            ContextMenu {
                                MenuItem {
                                    text: isStatusMuted(modelData.sender)
                                          ? loc.unmuteStatusPerson : loc.muteStatusPerson
                                    onClicked: toggleStatusMute(modelData.sender)
                                }
                            }
                        }
                        Row {
                            x: Theme.horizontalPageMargin
                            width: parent.width - 2*x
                            height: parent.height
                            spacing: Theme.paddingMedium
                            Image {
                                width: Theme.iconSizeMedium
                                height: Theme.iconSizeMedium
                                sourceSize.width: Theme.iconSizeMedium
                                sourceSize.height: Theme.iconSizeMedium
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                anchors.verticalCenter: parent.verticalCenter
                                source: "http://127.0.0.1:" + backendPort
                                        + "/avatar/" + modelData.sender
                            }
                            Column {
                                anchors.verticalCenter: parent.verticalCenter
                                Label {
                                    text: modelData.isLid
                                          ? loc.unknownSender
                                          : (getDisplayName(modelData.sender, "") !== ""
                                             ? getDisplayName(modelData.sender, "")
                                             : "+" + modelData.sender)
                                    color: Theme.highlightColor
                                }
                                Label {
                                    text: modelData.count + " \u00b7 "
                                          + Qt.formatDateTime(new Date(modelData.newest * 1000),
                                                              "dd.MM. hh:mm")
                                    font.pixelSize: Theme.fontSizeExtraSmall
                                    color: Theme.secondaryColor
                                }
                            }
                        }
                    }
                }

                Component {
                    id: statusPostDelegate
                    ListItem {
                    // Nach dem Muster des Kanalverzeichnisses weiter unten,
                    // das nachweislich funktioniert: ListView.view.width statt
                    // parent.width und das Menue unmittelbar als Component.
                    width: ListView.view.width
                    contentHeight: stCol.height
                    menu: Component {
                        ContextMenu {
                            MenuItem {
                                visible: !modelData.fromMe && !!modelData.sender
                                text: isStatusMuted(modelData.sender)
                                      ? loc.unmuteStatusPerson : loc.muteStatusPerson
                                onClicked: toggleStatusMute(modelData.sender)
                            }
                        }
                    }

                Column {
                    id: stCol
                    width: parent.width
                    spacing: Theme.paddingSmall

                    Item { width: 1; height: Theme.paddingMedium }

                    Row {
                        x: Theme.horizontalPageMargin
                        spacing: Theme.paddingMedium
                                                Image {
                            // Bild bei JEDEM Beitrag, nicht nur beim ersten: bei zehn
                            // Bildern derselben Person sieht man sonst ab dem zweiten
                            // nicht mehr, von wem sie stammen, ohne nach oben zu
                            // scrollen. Wunsch von rdomschk.
                            visible: !modelData.senderIsLid && !!modelData.sender
                            width: Theme.iconSizeMedium
                            height: Theme.iconSizeMedium
                            sourceSize.width: Theme.iconSizeMedium
                            sourceSize.height: Theme.iconSizeMedium
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            anchors.verticalCenter: parent.verticalCenter
                            source: modelData.sender
                                    ? "http://127.0.0.1:" + backendPort + "/avatar/" + modelData.sender
                                    : ""
                        }
                        Label {
                            // Bei unaufgeloester LID zeigte hier eine
                            // Ziffernfolge, die wie eine auslaendische
                            // Rufnummer aussieht und keine ist - schlimmer
                            // als gar keine Angabe, weil sie eine falsche
                            // Sicherheit vortaeuscht
                            // Name nur beim ersten Beitrag einer Person, die
                            // weiteren zaehlen mit (2/7). Bei einem Fotoalbum
                            // stand der Name sonst sieben Mal untereinander
                            text: modelData.groupHead
                                  ? (modelData.senderIsLid === true
                                     ? loc.unknownSender
                                     : getDisplayName(modelData.sender, ""))
                                  : ""
                            visible: text !== ""
                            color: Theme.highlightColor
                            font.bold: true
                        }
                        Label {
                            visible: modelData.groupCount > 1
                            text: modelData.groupIndex + "/" + modelData.groupCount
                            color: Theme.secondaryHighlightColor
                            font.pixelSize: Theme.fontSizeExtraSmall
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Label {
                            text: formatTime(modelData.timestamp)
                            color: Theme.secondaryColor
                            font.pixelSize: Theme.fontSizeExtraSmall
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        IconButton {
                            // Auf einen Status antworten: das wird eine
                            // normale Nachricht an den Verfasser, die den
                            // Status zitiert - genau wie in WhatsApp selbst.
                            // Wunsch von rdomschk.
                            // Nur wenn wir die Person benennen koennen. Ueber
                            // die Vorwahl allein sind 13-stellige LIDs nicht
                            // von echten Nummern zu trennen - eine Antwort ins
                            // Blaue erreicht einen Fremden.
                            visible: modelData.fromMe !== true
                                     && modelData.senderKnown === true
                            icon.source: "image://theme/icon-m-message-reply"
                            onClicked: {
                                pageStack.push(chatPage, {
                                    chatJid: modelData.sender,
                                    chatName: getDisplayName(modelData.sender, ""),
                                    pendingQuoteId: modelData.id,
                                    // Ohne Bildunterschrift stand im Zitat nur
                                    // "Bilder" - der Empfaenger konnte nicht
                                    // erkennen, welcher Status gemeint war.
                                    // Jetzt Uhrzeit und Datum dazu, das
                                    // benennt ihn eindeutig. Wunsch von
                                    // rdomschk.
                                    pendingQuoteText: modelData.text && modelData.text !== ""
                                          ? modelData.text
                                          : (loc.status + " "
                                             + Qt.formatDateTime(
                                                   new Date(modelData.timestamp * 1000),
                                                   "dd.MM. HH:mm")),
                                    pendingQuoteSender: modelData.sender
                                })
                            }
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
                        // Statusmeldungen enthalten oft Links, waren hier aber
                        // roher Text - nicht antippbar und ohne Emojis. Dieselbe
                        // Aufbereitung wie im Chat.
                        text: linkify(modelData.text)
                        textFormat: Text.StyledText
                        linkColor: Theme.highlightColor
                        onLinkActivated: Qt.openUrlExternally(link)
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
                                } else if (modelData.mediaType === "video") {
                                    pageStack.push(videoPlayerPage, { videoPath: modelData.localPath })
                                } else if (modelData.mediaType === "audio") {
                                    pageStack.push(audioPlayerPage, { audioPath: modelData.localPath, title: modelData.text || "Audio" })
                                } else {
                                    Qt.openUrlExternally("file://" + modelData.localPath)
                                }
                            }
                        }
                    }
                }
            }
                }

                ViewPlaceholder {
                    enabled: statuses.length === 0
                    text: loc.noStatus
                    hintText: loc.noStatusHint
                }
            }
        }
    }

    // Die Beitraege einer Person. Bewusst schlicht gehalten: Bild oder Text
    // je Beitrag, neueste zuerst - fuer alles Weitere gibt es die
    // durchgehende Ansicht.
    Component {
        id: personStatusPage
        Page {
            property string personJid: ""
            SilicaListView {
                anchors.fill: parent
                clip: true
                model: statusesOf(personJid)
                header: PageHeader {
                    title: getDisplayName(personJid, "") !== ""
                           ? getDisplayName(personJid, "") : ("+" + personJid)
                }
                delegate: Column {
                    width: parent.width
                    spacing: Theme.paddingSmall
                    Item { width: 1; height: Theme.paddingMedium }
                    Image {
                        visible: !!modelData.mediaPath
                        width: parent.width - 2*Theme.horizontalPageMargin
                        x: Theme.horizontalPageMargin
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                        source: modelData.mediaPath ? "file://" + modelData.mediaPath : ""
                        MouseArea {
                            anchors.fill: parent
                            onClicked: pageStack.push(statusFullscreen, {
                                imagePath: modelData.mediaPath,
                                caption: modelData.text || ""
                            })
                        }
                    }
                    Label {
                        visible: !!modelData.text
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*x
                        text: linkify(modelData.text || "")
                        textFormat: Text.StyledText
                        linkColor: Theme.highlightColor
                        onLinkActivated: Qt.openUrlExternally(link)
                        wrapMode: Text.Wrap
                    }
                    Label {
                        x: Theme.horizontalPageMargin
                        text: Qt.formatDateTime(new Date(modelData.timestamp * 1000),
                                                "dd.MM. hh:mm")
                        font.pixelSize: Theme.fontSizeExtraSmall
                        color: Theme.secondaryColor
                    }
                }
                ViewPlaceholder {
                    enabled: parent.model.length === 0
                    text: loc.statusHiddenTitle
                }
            }
        }
    }

    // Seite zum Stummschalten. Aufgefuehrt wird, wer zuletzt etwas gepostet
    // hat, dazu alle bereits Stummgeschalteten - sonst koennte man jemanden
    // nicht mehr zuruecknehmen, sobald er nichts Neues mehr schreibt.
    Component {
        id: statusMutePage
        Page {
            SilicaListView {
                anchors.fill: parent
                clip: true
                header: PageHeader { title: loc.muteStatusPeople }
                model: {
                    var seen = {}, out = []
                    for (var i = 0; i < statuses.length; i++) {
                        var j = statuses[i].sender
                        if (!j || statuses[i].fromMe || seen[j]) continue
                        seen[j] = true
                        out.push(j)
                    }
                    for (var k = 0; k < mutedStatus.length; k++) {
                        if (!seen[mutedStatus[k]]) {
                            seen[mutedStatus[k]] = true
                            out.push(mutedStatus[k])
                        }
                    }
                    return out
                }
                delegate: TextSwitch {
                    width: parent.width
                    text: getDisplayName(modelData, "") !== ""
                          ? getDisplayName(modelData, "") : ("+" + modelData)
                    description: isStatusMuted(modelData) ? loc.statusMutedDesc : ""
                    checked: isStatusMuted(modelData)
                    onClicked: toggleStatusMute(modelData)
                }
                ViewPlaceholder {
                    enabled: parent.model.length === 0
                    text: loc.noStatusPeople
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

            // Zoombar. Bewusst OHNE die Eigenschaft scale: die skaliert um
            // den Mittelpunkt und PinchArea verschiebt zusaetzlich das Ziel -
            // diese Verschiebung blieb nach dem Aufziehen stehen, das Bild sass
            // danach nicht mehr mittig und rutschte nach unten (rdomschk).
            // Stattdessen waechst das Bild selbst, und der Flickable schiebt
            // es, wie er es fuer jeden zu grossen Inhalt tut.
            SilicaFlickable {
                id: zoomFlick
                anchors.fill: parent
                property real zoom: 1.0
                contentWidth: zoomImg.width
                contentHeight: zoomImg.height
                clip: true

                PinchArea {
                    width: Math.max(zoomFlick.width, zoomImg.width)
                    height: Math.max(zoomFlick.height, zoomImg.height)
                    property real startZoom: 1.0
                    pinch.minimumScale: 1.0
                    pinch.maximumScale: 6.0
                    onPinchStarted: startZoom = zoomFlick.zoom
                    onPinchUpdated: zoomFlick.zoom =
                        Math.max(1.0, Math.min(6.0, startZoom * pinch.scale))

                    Image {
                        id: zoomImg
                        width: zoomFlick.width * zoomFlick.zoom
                        height: zoomFlick.height * zoomFlick.zoom
                        anchors.centerIn: parent
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                        // Beim Vergroessern die volle Aufloesung anfordern,
                        // sonst vergroessert man nur Bildschirmpunkte
                        sourceSize.width: zoomFlick.zoom > 1 ? 0 : zoomFlick.width
                        source: "file://" + imagePath
                        Behavior on width { NumberAnimation { duration: 150 } }
                        Behavior on height { NumberAnimation { duration: 150 } }
                    }

                    MouseArea {
                        anchors.fill: parent
                        onDoubleClicked: {
                            zoomFlick.zoom = (zoomFlick.zoom > 1.05) ? 1.0 : 2.0
                            if (zoomFlick.zoom === 1.0) {
                                zoomFlick.contentX = 0
                                zoomFlick.contentY = 0
                            }
                        }
                        // Nur bei unveraendertem Bild schliessen - sonst faellt
                        // man beim Verschieben aus dem Betrachter
                        onClicked: if (zoomFlick.zoom <= 1.05) pageStack.pop()
                    }
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
            allowedOrientations: orientationMask()
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
                PageHeader { title: scopeName !== "" ? loc.searchInScope.arg(scopeName) : loc.searchTitle }
                SearchField {
                    id: spField
                    width: parent.width
                    placeholderText: scopeName !== "" ? loc.searchInChat : loc.searchChatsMessages
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
            allowedOrientations: orientationMask()
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

                PullDownMenu {
                    MenuItem {
                        text: loc.discoverChannels
                        onClicked: pageStack.push(channelDirectoryPage)
                    }
                }

                header: Column {
                    width: parent ? parent.width : Screen.width
                    PageHeader { title: loc.channels }
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
                            text: loc.unfollow
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
                    text: loc.noChannels
                    hintText: loc.noChannelsHint
                }
            }
        }
    }

    Component {
        id: joinLinkPage
        Dialog {
            allowedOrientations: orientationMask()
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
                DialogHeader { title: loc.joinGroupChannel }
                TextField {
                    id: linkField
                    width: parent.width
                    label: loc.inviteLink
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
                    text: loc.joinHint
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
            allowedOrientations: orientationMask()
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
                DialogHeader { title: loc.createGroup }
                TextField {
                    id: ngName
                    width: parent.width
                    label: loc.groupName
                    placeholderText: loc.groupNameMax
                    text: ngDialog.ngNameText
                    onTextChanged: ngDialog.ngNameText = text
                }
                SearchField {
                    id: ngSearchField
                    width: parent.width
                    placeholderText: loc.searchContacts
                    onTextChanged: ngDialog.ngSearch = text
                }
                SectionHeader {
                    text: loc.selectParticipants
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


    // Sammelseite fuer das Querformat: dort passen nur sechs Menuepunkte auf
    // den Schirm, ueber diese Seite bleibt aber alles erreichbar. Bewusst
    // eine eigene Seite und kein zweites Pulley - eine Liste scrollt, ein
    // Pulley nicht.
    Component {
        id: allActionsPage
        Page {
            allowedOrientations: orientationMask()
            SilicaFlickable {
                anchors.fill: parent
                contentHeight: aaCol.height
                VerticalScrollDecorator {}
                Column {
                    id: aaCol
                    width: parent.width
                    PageHeader { title: loc.allActions }

                    ListItem {
                        width: parent.width
                        onClicked: { pageStack.pop(); pageStack.push(settingsPage) }
                        Label { x: Theme.horizontalPageMargin; anchors.verticalCenter: parent.verticalCenter
                                text: loc.settings }
                    }
                    ListItem {
                        width: parent.width
                        onClicked: { pageStack.pop(); pageStack.push(profilePage) }
                        Label { x: Theme.horizontalPageMargin; anchors.verticalCenter: parent.verticalCenter
                                text: loc.profile }
                    }
                    ListItem {
                        width: parent.width
                        onClicked: { pageStack.pop(); pageStack.push(searchPage) }
                        Label { x: Theme.horizontalPageMargin; anchors.verticalCenter: parent.verticalCenter
                                text: loc.search }
                    }
                    ListItem {
                        width: parent.width
                        onClicked: { pageStack.pop(); pageStack.push(channelsPage) }
                        Label { x: Theme.horizontalPageMargin; anchors.verticalCenter: parent.verticalCenter
                                text: loc.channels }
                    }
                    ListItem {
                        width: parent.width
                        onClicked: { pageStack.pop(); pageStack.push(joinLinkPage) }
                        Label { x: Theme.horizontalPageMargin; anchors.verticalCenter: parent.verticalCenter
                                text: loc.joinViaLink }
                    }
                    ListItem {
                        width: parent.width
                        onClicked: { pageStack.pop(); pageStack.push(newGroupPage) }
                        Label { x: Theme.horizontalPageMargin; anchors.verticalCenter: parent.verticalCenter
                                text: loc.newGroup }
                    }
                    ListItem {
                        width: parent.width
                        onClicked: { pageStack.pop(); pageStack.push(newChatPage) }
                        Label { x: Theme.horizontalPageMargin; anchors.verticalCenter: parent.verticalCenter
                                text: loc.newChat }
                    }
                    ListItem {
                        width: parent.width
                        onClicked: {
                            var xhr = new XMLHttpRequest()
                            xhr.open("GET", "http://127.0.0.1:" + backendPort + "/chats/read-all")
                            xhr.onreadystatechange = function() { if (xhr.readyState === 4) loadChats() }
                            xhr.send()
                            pageStack.pop()
                        }
                        Label { x: Theme.horizontalPageMargin; anchors.verticalCenter: parent.verticalCenter
                                text: loc.markAllRead }
                    }
                    ListItem {
                        width: parent.width
                        visible: connected
                        onClicked: {
                            pageStack.pop()
                            var xhr = new XMLHttpRequest()
                            xhr.open("GET", "http://127.0.0.1:" + backendPort + "/reload")
                            xhr.onreadystatechange = function() {
                                if (xhr.readyState === 4) { loadWAContacts(); loadChats() }
                            }
                            xhr.send()
                        }
                        Label { x: Theme.horizontalPageMargin; anchors.verticalCenter: parent.verticalCenter
                                text: loc.reload }
                    }
                    ListItem {
                        width: parent.width
                        // Dieselbe Remorse-Sicherung wie im Pulley - Abmelden
                        // ohne Ruecknahmefenster waere hier gefaehrlicher als
                        // dort, weil die Liste sich leichter danebentippen laesst
                        onClicked: {
                            pageStack.pop()
                            logoutRemorse.execute("Logging out", doLogout, 15000)
                        }
                        Label { x: Theme.horizontalPageMargin; anchors.verticalCenter: parent.verticalCenter
                                text: loc.logout; color: Theme.errorColor }
                    }
                }
            }
        }
    }
    Component {
        id: newChatPage
        Page {
            allowedOrientations: orientationMask()
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

                    PageHeader { title: loc.newChatTitle }

                    SearchField {
                        id: searchField
                        width: parent.width
                        placeholderText: loc.newChatSearch
                        inputMethodHints: Qt.ImhNone
                        onTextChanged: searchText = text
                    }

                    Column {
                        width: parent.width
                        visible: isValidNumber()
                        
                        SectionHeader { text: loc.newConversation }

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
                                        text: loc.startChatWithNumber
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.secondaryColor
                                    }
                                }
                            }
                        }
                    }

                    SectionHeader { 
                        text: loc.contacts + " (" + filteredContacts().length + ")"
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
            allowedOrientations: orientationMask()
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

            // Beim Oeffnen aus der Statusliste heraus vorbelegtes Zitat: die
            // Chatseite entsteht erst beim Druck, deshalb kann das Zitat nicht
            // direkt in replyTo* gesetzt werden - es wird uebergeben und hier
            // uebernommen, sobald die Seite steht
            // Mehrere Nachrichten auswaehlen und gemeinsam weiterleiten.
            // Der Modus wird ueber "Auswaehlen" im Langdruck-Menue betreten;
            // danach waehlt ein Tipp aus statt zu oeffnen.
            property bool selectMode: false
            property var selectedIds: []
            function toggleSelect(id) {
                var a = selectedIds.slice()
                var i = a.indexOf(id)
                if (i >= 0) a.splice(i, 1); else a.push(id)
                selectedIds = a
                if (a.length === 0) selectMode = false
            }
            function isSelected(id) { return selectedIds.indexOf(id) >= 0 }
            function endSelect() { selectedIds = []; selectMode = false }

            property string pendingQuoteId: ""
            property string pendingQuoteText: ""
            property string pendingQuoteSender: ""


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

            // Reihenfolge: eigener Kontaktname, dann der Name, den die Person
            // sich selbst gegeben hat (PushName vom Server), sonst die Nummer.
            // Der Gruppenname darf hier NIE stehen - Gruppen-JIDs enthalten
            // einen Bindestrich, und waContactsMap kennt auch Gruppen. Steht
            // in sender die Gruppe selbst (alte Nachrichten aus dem
            // Verlaufsabgleich ohne Teilnehmerangabe), wissen wir schlicht
            // nichts und behaupten lieber nichts.
            function senderDisplay(number) {
                if (!number) return ""
                if (number.indexOf("-") >= 0 || number === chatJid) return ""
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

            property string lastMsgsJson: ""
            function load() {
                var xhr = new XMLHttpRequest()
                xhr.open("GET", "http://127.0.0.1:" + backendPort + "/messages?jid=" + chatJid)
                xhr.onreadystatechange = function() {
                    if (xhr.readyState === 4 && xhr.status === 200) {
                        // Unveraendert -> NICHTS tun: die frueher bedingungslose
                        // Neuzuweisung baute das Modell alle 2 s neu auf und
                        // sprang ans Ende - Hochscrollen war ein Kampf gegen
                        // den Poll-Timer (bei Live-Location im Sekundentakt)
                        if (xhr.responseText === lastMsgsJson) return
                        lastMsgsJson = xhr.responseText
                        markOpened() // Chat ist offen: Neues gilt als gelesen
                        // Reassign-Doppelschlag abschirmen: steht noch eine
                        // Wiederherstellung aus (positionTimer/Anker), liegt
                        // die View gerade transient falsch - atYEnd dann NICHT
                        // sampeln und das alte Restore-Ziel weiterreichen,
                        // sonst schreibt der zweite Schlag den Fehlsprung fest
                        var pendingRestore = (positionTimer.running && restoreY >= 0)
                                             || anchorSettle.running
                        var liveEnd = posCaptured ? wasAtEnd : msgList.atYEnd
                        stickToEnd = forceEnd
                                     || (pendingRestore ? false : liveEnd)
                        var keepY = (positionTimer.running && restoreY >= 0)
                                    ? restoreY
                                    : (posCaptured ? capturedY : msgList.contentY)
                        // Anker VOR der Zuweisung nehmen: Pixelkoordinaten
                        // sind ueber eine Neuzuweisung hinweg keine stabile
                        // Identitaet (originY-Verschiebung, Log: holdback
                        // y=4339 keepY=4117) - die Nachricht-ID ist es
                        var hbId = "", hbOff = 0
                        if (!stickToEnd && posCaptured && anchorId !== "") {
                            // Video/Audio oeffnen eine INTERNE Seite: die
                            // Chatseite wird unsichtbar, ihre Delegates sind
                            // weg, itemAt() liefert nichts - also den bei der
                            // Capture (noch sichtbar!) genommenen Anker nutzen
                            hbId = anchorId
                            hbOff = anchorOffset
                        } else if (!stickToEnd) {
                            var pY = keepY + 8
                            var hbIt = msgList.itemAt(msgList.width / 2, pY)
                            var hbIx = msgList.indexAt(msgList.width / 2, pY)
                            if (!hbIt || hbIx < 0) {
                                pY = keepY + msgList.height / 3
                                hbIt = msgList.itemAt(msgList.width / 2, pY)
                                hbIx = msgList.indexAt(msgList.width / 2, pY)
                            }
                            if (hbIt && hbIx >= 0 && hbIx < msgs.length && msgs[hbIx]) {
                                hbId = msgs[hbIx].id || ""
                                hbOff = keepY - hbIt.y
                            }
                        }
                        msgs = JSON.parse(xhr.responseText) || []
                        // Synchron im selben JS-Zug wiederherstellen - es wird
                        // nie ein Frame mit falscher Position gerendert.
                        // Anker-basiert; Pixel nur als Notnagel, wenn die
                        // Ankernachricht verschwunden ist
                        if (!stickToEnd) {
                            var hbDone = false
                            if (hbId !== "") {
                                for (var hi = 0; hi < msgs.length; hi++) {
                                    if (msgs[hi].id === hbId) {
                                        msgList.positionViewAtIndex(hi, ListView.Beginning)
                                        msgList.contentY += hbOff
                                        hbDone = true
                                        break
                                    }
                                }
                            }
                            if (!hbDone) msgList.contentY = keepY
                            restoreY = msgList.contentY
                        }
                        else restoreY = -1
                        forceEnd = false
                        if (status !== PageStatus.Active) awayModelChanged = true
                        // Frische Delegates unter laufendem Einpendeln:
                        // von vorn ansetzen statt auf alten Layouts zu stehen
                        if (anchorSettle.running) anchorSettle.tries = 0
                        // Immer starten: die Neuzuweisung setzt die ListView
                        // zurueck, auch wenn die Anzahl gleich bleibt - in
                        // Kanaelen der Normalfall (Viewzaehler aendern sich)
                        positionTimer.start()
                    }
                }
                xhr.send()
            }
            property bool stickToEnd: true
            property real restoreY: -1
            // Position merken/wiederherstellen - als Nachrichten-Index, weil
            // Pixel-Offsets nach dem Delegate-Neuaufbau der ListView nichts
            // taugen. Greift bei internen Playern (Seitenstatus) UND bei
            // extern geoeffneten Medien (App-Status). Wer unten war, kommt
            // unten zurueck; wer mitten im Verlauf las (Kanaele!), genau dort.
            property int resumeIndex: -1

            property real capturedY: -1
            property bool awayModelChanged: false

            property string anchorId: ""
            property real anchorOffset: 0

            property bool posCaptured: false

            function captureListPos() {
                // Einmalige Aufnahme bis zum Verbrauch: das Aktiv-Flackern
                // beim Viewer-Start loeste eine zweite Capture aus, die den
                // transienten Zombie-Zustand (atYEnd=true bei contentY~-40,
                // kein Anker) ueber die gute Aufnahme schrieb - der Restore
                // restaurierte dann pflichtbewusst den Muell
                if (posCaptured) {
                    return
                }
                posCaptured = true
                wasAtEnd = msgList.atYEnd
                capturedY = msgList.contentY
                awayModelChanged = false
                // Haengendes forceEnd entschaerfen: es stammt ggf. von einem
                // frueheren Unten-Restore und wuerde sonst beim naechsten
                // Reassign (z.B. Download!) faelschlich ans Ende springen -
                // onMovementStarted greift bei programmatischen Bewegungen nie
                forceEnd = false
                // Anker: oberste sichtbare Nachricht + Pixel-Offset darin.
                // Damit gelingt die exakte Wiederherstellung auch dann, wenn
                // das Modell waehrend der Abwesenheit neu zugewiesen wurde
                anchorId = ""
                anchorOffset = 0
                var probeY = msgList.contentY + 8
                var it = msgList.itemAt(msgList.width / 2, probeY)
                var idx = msgList.indexAt(msgList.width / 2, probeY)
                if (!it || idx < 0) {
                    probeY = msgList.contentY + msgList.height / 3
                    it = msgList.itemAt(msgList.width / 2, probeY)
                    idx = msgList.indexAt(msgList.width / 2, probeY)
                }
                if (it && idx >= 0 && idx < msgs.length && msgs[idx]) {
                    anchorId = msgs[idx].id || ""
                    anchorOffset = msgList.contentY - it.y
                }
                resumeIndex = wasAtEnd ? -1 : msgList.indexAt(
                    msgList.width / 2, msgList.contentY + msgList.height / 2)
                // In einer Luecke zwischen Delegates liefert indexAt -1:
                // dann etwas hoeher noch einmal probieren
                if (!wasAtEnd && resumeIndex < 0)
                    resumeIndex = msgList.indexAt(
                        msgList.width / 2, msgList.contentY + msgList.height / 3)
            }

            function restoreListPos() {
                posCaptured = false
                if (!awayModelChanged) {
                    // Modell unveraendert: die alte Pixelposition gilt exakt -
                    // nichts zentrieren, nichts springen, hoechstens still
                    // zuruecksetzen, falls die View minimal verrutscht ist
                    if (capturedY >= 0 && Math.abs(msgList.contentY - capturedY) > 1)
                        msgList.contentY = capturedY
                    // Anker aufraeumen! Ein verwaister anchorId liess den
                    // positionTimer dauerhaft passen - nach der naechsten
                    // Neuzuweisung restaurierte niemand mehr (Chat oben)
                    anchorId = ""
                    anchorOffset = 0
                    resumeIndex = -1
                    forceEnd = false
                    return
                }
                if (wasAtEnd) {
                    anchorId = ""
                    anchorOffset = 0
                    stickToEnd = true
                    forceEnd = true
                    restoreY = -1
                    positionTimer.start()
                } else if (resumeIndex >= 0) {
                    restoreY = -1
                    forceEnd = false
                    resumeTimer.start()
                } else {
                    anchorId = ""
                    anchorOffset = 0
                }
            }

            Connections {
                target: Qt.application
                onActiveChanged: {
                    if (!Qt.application.active) {
                        chatPageItem.captureListPos()
                    } else if (chatPageItem.status === PageStatus.Active) {
                        chatPageItem.restoreListPos()
                    }
                }
            }

            Timer {
                id: resumeTimer
                interval: 80
                repeat: false
                onTriggered: {
                    var done = false
                    if (chatPageItem.anchorId !== "") {
                        for (var i = 0; i < msgs.length; i++) {
                            if (msgs[i].id === chatPageItem.anchorId) {
                                anchorSettle.idx = i
                                anchorSettle.tries = 0
                                anchorSettle.apply()
                                anchorSettle.start()
                                done = true
                                break
                            }
                        }
                    }
                    if (!done && chatPageItem.resumeIndex >= 0) {
                        msgList.positionViewAtIndex(chatPageItem.resumeIndex, ListView.Center)
                    }
                    chatPageItem.resumeIndex = -1
                    if (!done) {
                        chatPageItem.anchorId = ""
                        chatPageItem.anchorOffset = 0
                    }
                }
            }

            Timer {
                id: anchorSettle
                interval: 120
                repeat: true
                property int idx: -1
                property int tries: 0

                // Idempotente Verankerung: Grobposition UND Offset im selben
                // JS-Zug - gerendert wird erst danach, es gibt also nie einen
                // "Anker buendig oben"-Zwischenframe. Die Wiederholungen
                // fangen nur noch Layout-Drift ab; jede landet exakt auf
                // Anker+Offset unter dem dann aktuellen Layout, deshalb gibt
                // es kein Hin und Her mehr
                function apply() {
                    if (idx < 0 || idx >= msgs.length
                            || !msgs[idx] || msgs[idx].id !== chatPageItem.anchorId) {
                        idx = -1
                        for (var i = 0; i < msgs.length; i++) {
                            if (msgs[i].id === chatPageItem.anchorId) { idx = i; break }
                        }
                        if (idx < 0) { finish(); return }
                    }
                    var yBefore = msgList.contentY
                    msgList.positionViewAtIndex(idx, ListView.Beginning)
                    var yBase = msgList.contentY
                    msgList.contentY = msgList.contentY + chatPageItem.anchorOffset
                }

                function finish() {
                    stop()
                    chatPageItem.anchorId = ""
                    chatPageItem.anchorOffset = 0
                    chatPageItem.forceEnd = false
                    idx = -1
                }

                onTriggered: {
                    // Nutzer scrollt selbst: sofort aufhoeren, nicht kaempfen
                    if (msgList.moving || msgList.dragging) {
                        finish()
                        return
                    }
                    apply()
                    tries++
                    if (tries >= 3) finish()
                }
            }
            // Nach eigenem Senden ans Ende springen, egal wo die Liste stand.
            // Ueberlebt die Polls, bis die gesendete Nachricht wirklich da ist
            // (load() kehrt bei unveraendertem JSON frueh zurueck)
            property bool forceEnd: false

            // Nach einer Server-Ablehnung im leeren Chat gesetzt; gilt nur
            // fuer diese Seiteninstanz - Chat verlassen und neu oeffnen
            // gibt den Versuch bewusst wieder frei
            property bool sendBlocked: false

            function send() {
                if (input.text === "") return
                if (sendBlocked) {
                    globalNotice = loc.sendBlockedHint
                    noticeIsError = true
                    return
                }
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
                    if (xhr.readyState !== 4) return
                    if (xhr.status !== 200) {
                        // Fehler NICHT verschlucken: bisher gab es nur den
                        // 200-Zweig, der Text blieb stehen und es sah aus,
                        // als passiere schlicht nichts. Der Dateiversand
                        // meldet seit 0.9.167 sauber - der Textversand nicht
                        globalNotice = sendErrorText(xhr.status, xhr.responseText)
                        noticeIsError = true
                        // Erstkontakt-Bremse: eine vom Server abgelehnte
                        // erste Nachricht an einen noch leeren Chat nicht
                        // wieder und wieder abfeuern - genau dieses Muster
                        // verlaengert eine Kontobeschraenkung
                        if (sendRejectCode(xhr.responseText) > 0 && msgs.length === 0) {
                            sendBlocked = true
                        }
                        return
                    }
                    input.text = ""
                    editingId = ""
                    replyToId = ""; replyToText = ""; replyToSender = ""
                    forceEnd = true
                    load()
                    loadChats()
                }
                xhr.send()
            }

            property string uploadName: ""
            property int uploadSecs: 0

            Timer {
                // Upload dauert je nach Groesse und Netz zweistellige Sekunden -
                // ohne Rueckmeldung wirkt das wie "nichts passiert"
                id: uploadTicker
                interval: 1000
                repeat: true
                onTriggered: {
                    chatPageItem.uploadSecs++
                    globalNotice = "Sending " + chatPageItem.uploadName
                                   + "\u2026 " + chatPageItem.uploadSecs + "s"
                }
            }

            // Mehrere Dateien nacheinander senden. Nicht alle auf einmal:
            // ein Schwall gleichzeitiger Uploads ist genau das Muster, das
            // beim Erstkontakt schon zur Kontosperre gefuehrt hat.
            property var pendingFiles: []
            Timer {
                id: fileQueue
                interval: 1200
                repeat: true
                onTriggered: {
                    if (pendingFiles.length === 0) { stop(); return }
                    var next = pendingFiles.shift()
                    pendingFiles = pendingFiles
                    sendFile(next)
                }
            }
            function sendFileQueue(paths) {
                if (!paths || paths.length === 0) return
                sendFile(paths[0])
                if (paths.length > 1) {
                    pendingFiles = paths.slice(1)
                    fileQueue.restart()
                }
            }

            function sendFile(path) {
                console.log("WASEND sendFile path=" + path + " chat=" + chatJid
                            + " port=" + backendPort)
                if (!path || path === "") {
                    globalNotice = "Send failed: the picker returned no file path"
                    return
                }
                forceEnd = true   // Upload dauert: schon die Zwischen-Polls sollen ans Ende
                uploadInFlight++
                uploadName = path.substring(path.lastIndexOf("/") + 1)
                uploadSecs = 0
                globalNotice = "Sending " + uploadName + "\u2026"
                uploadTicker.restart()
                var xhr = new XMLHttpRequest()
                xhr.open("POST", "http://127.0.0.1:" + backendPort + "/sendmedia?to=" + chatJid + "&file=" + encodeURIComponent(path) + "&caption=")
                xhr.onreadystatechange = function() {
                    if (xhr.readyState === 4) {
                        uploadInFlight = Math.max(0, uploadInFlight - 1)
                        uploadTicker.stop()
                        console.log("WASEND sendFile reply status=" + xhr.status
                                    + " body=" + (xhr.responseText || "").substring(0, 120))
                        // Fehler NICHT verschlucken: bisher lief load() auch bei
                        // Status 500, der Grund des Backends ging verloren und
                        // es sah aus, als passiere schlicht nichts
                        if (xhr.status !== 200) {
                            globalNotice = sendErrorText(xhr.status, xhr.responseText)
                                           + " [" + path + "]"
                            noticeIsError = true
                            if (sendRejectCode(xhr.responseText) > 0 && msgs.length === 0) {
                                sendBlocked = true
                            }
                            return
                        }
                        if (globalNotice.indexOf("Sending ") === 0) globalNotice = ""
                        forceEnd = true
                        load()
                        loadChats()
                    }
                }
                xhr.send()
            }

            function markOpened() {
                var xhr = new XMLHttpRequest()
                xhr.open("GET", "http://127.0.0.1:" + backendPort + "/chat/opened?chat=" + chatJid)
                xhr.send()
            }
            Connections { target: app; onEventTick: load() }
            Timer {
                // Sicherheitsnetz - der Normalweg ist der /events-Long-Poll
                interval: 30000; running: true; repeat: true; onTriggered: load()
            }
            Component.onCompleted: {
                load()
                markOpened()
                // Aus der Statusliste heraus geoeffnet: das Zitat steht schon
                // bereit, sobald die Seite existiert
                if (pendingQuoteId !== "") {
                    replyToId = pendingQuoteId
                    replyToText = pendingQuoteText
                    replyToSender = pendingQuoteSender
                }
            }
            // Beim Verlassen (Medium oeffnen) merken, ob die Liste am Ende
            // stand; beim Zurueckkommen genau dorthin. Ohne das landet man
            // nach dem Schliessen eines Bildes/Videos/Audios in der Chatmitte,
            // weil der Poll-Timer stickToEnd auf die Zwischenposition setzt.
            property bool wasAtEnd: true
            onStatusChanged: {
                if (status === PageStatus.Deactivating) {
                    markOpened()   // Gelesen-Stand sofort festschreiben
                    captureListPos()
                } else if (status === PageStatus.Active) {
                    pageStack.pushAttached(contactInfoPage, {
                        jid: chatJid, name: chatName,
                        avatar: chatAvatar,
                        group: isGroupChat, channel: isChannel
                    })
                    restoreListPos()
                }
            }

            Component {
                id: imagePicker
                // Die Mehrfachauswahl gibt es nur als DIALOG, nicht als Page -
                // MultiImagePickerPage existiert nicht und liess die ganze
                // QML-Datei scheitern (weisse Flaeche in 0.9.220). Die Auswahl
                // steht erst mit onAccepted fest, nicht bei jeder Aenderung.
                MultiImagePickerDialog {
                    onAccepted: {
                        if (!selectedContent || selectedContent.count === 0) return
                        var paths = []
                        for (var i = 0; i < selectedContent.count; i++) {
                            var it = selectedContent.get(i)
                            if (it && it.filePath) paths.push(it.filePath)
                        }
                        chatPageItem.sendFileQueue(paths)
                    }
                }
            }

            Component {
                id: imagePickerSingle
                ImagePickerPage {
                    onSelectedContentPropertiesChanged: {
                        console.log("WASEND imagePicker fired path="
                                    + (selectedContentProperties
                                       ? selectedContentProperties.filePath : "(keine Props)"))
                        chatPageItem.sendFile(selectedContentProperties
                                              ? selectedContentProperties.filePath : "")
                    }
                    onSelectedContentChanged: console.log("WASEND imagePicker selectedContent=" + selectedContent)
                }
            }

            // Nach Typ sortierte Auswahl (Bilder, Videos, Musik, Dokumente) -
            // dasselbe Bauteil, das die Status-Seite schon nutzt
            Component {
                id: contentPicker
                ContentPickerPage {
                    onSelectedContentPropertiesChanged: {
                        console.log("WASEND contentPicker fired path="
                                    + (selectedContentProperties
                                       ? selectedContentProperties.filePath : "(keine Props)"))
                        chatPageItem.sendFile(selectedContentProperties
                                              ? selectedContentProperties.filePath : "")
                    }
                }
            }

            // Fragt nur, wenn die Einstellung auf "ask" steht. replace statt
            // push: der Rueckweg aus dem Waehler fuehrt in den Chat, nicht
            // wieder in diese Auswahl
            Component {
                id: attachChooser
                Page {
                    allowedOrientations: orientationMask()
                    SilicaFlickable {
                        anchors.fill: parent
                        contentHeight: attachCol.height
                        Column {
                            id: attachCol
                            width: parent.width
                            PageHeader { title: loc.chooseAttachSource }
                            ListItem {
                                width: parent.width
                                onClicked: pageStack.replace(contentPicker)
                                Label {
                                    x: Theme.horizontalPageMargin
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: loc.attachPickerContent
                                }
                            }
                            ListItem {
                                width: parent.width
                                onClicked: pageStack.replace(filePicker)
                                Label {
                                    x: Theme.horizontalPageMargin
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: loc.attachPickerFile
                                }
                            }
                        }
                    }
                }
            }

            Component {
                id: filePicker
                FilePickerPage {
                    onSelectedContentPropertiesChanged: {
                        console.log("WASEND filePicker fired path="
                                    + (selectedContentProperties
                                       ? selectedContentProperties.filePath : "(keine Props)"))
                        chatPageItem.sendFile(selectedContentProperties
                                              ? selectedContentProperties.filePath : "")
                    }
                    onSelectedContentChanged: console.log("WASEND filePicker selectedContent=" + selectedContent)
                }
            }

            SilicaListView {
                id: msgList
                // Ein scharfes forceEnd ("halte mich unten") verfaellt, sobald
                // der Nutzer selbst scrollt - sonst feuert es beim naechsten
                // JSON-Wechsel (Kanal-Viewzaehler!) und springt ans Ende
                onMovementStarted: forceEnd = false
                anchors.fill: parent
                // Der Kopf zaehlt IMMER, nicht nur wenn eine Nachricht
                // angeheftet ist: sonst beginnt die Liste ganz oben und die
                // Nachrichten scheinen hinter dem Kopf durch. Solange er
                // durchsichtig war, fiel das kaum auf - mit Farbe und Avatar
                // ueberlagern sich Text und Name sichtbar (rdomschk).
                anchors.topMargin: pageHead.height
                                   + (pinnedBar.visible ? pinnedBar.height : 0)
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
                    onTriggered: {
                        // Anker-Einpendeln hat Vorfahrt: solange es laeuft,
                        // haelt sich der normale Restaurator zurueck - sonst
                        // schieben zwei Timer abwechselnd (sichtbares Hin
                        // und Her, Endposition zufaellig)
                        if (anchorSettle.running) {
                            return
                        }
                        if (stickToEnd) {
                            msgList.positionViewAtIndex(msgList.count - 1, ListView.End)
                        } else if (restoreY >= 0) {
                            // Nutzer las weiter oben: Leseposition erhalten
                            msgList.contentY = restoreY
                            restoreY = -1
                        }
                    }
                }
                onCountChanged: positionTimer.start()
                Component.onCompleted: positionTimer.start()

                PushUpMenu {
                    // Spiegel des oberen Pulley-Menues: am unteren Ende ist
                    // man in einem Chat ohnehin - kein Scrollen an den Anfang
                    // mehr noetig, um eine Aktion zu erreichen

                    MenuItem {
                        text: loc.refreshChannel
                        visible: !chatPageItem.isLandscape && (isChannel)
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
                        text: loc.unfollowChannel
                        visible: !chatPageItem.isLandscape && (isChannel)
                        onClicked: blockRemorse.execute("Unfollowing channel", function() {
                            var xhr = new XMLHttpRequest()
                            xhr.open("GET", "http://127.0.0.1:" + backendPort + "/channel/unfollow?jid=" + chatJid)
                            xhr.send()
                        })
                    }
                    MenuItem {
                        text: loc.loadHistory
                        visible: !chatPageItem.isLandscape && (chatJid !== "status" && !isChannel)
                        onClicked: {
                            var xhr = new XMLHttpRequest()
                            xhr.open("GET", "http://127.0.0.1:" + backendPort + "/history/request?chat=" + chatJid)
                            xhr.onreadystatechange = function() {
                                if (xhr.readyState === 4) {
                                    globalNotice = xhr.status === 200 ? xhr.responseText : ("History request failed: " + xhr.responseText)
                                }
                            }
                            xhr.send()
                        }
                    }
                    MenuItem {
                        text: loc.searchInChat
                        onClicked: pageStack.push(searchPage, { scopeJid: chatJid, scopeName: chatName })
                    }
                    MenuItem {
                        text: loc.shareLiveLocation
                        visible: chatJid !== "status" && !isChannel && !(liveActive && liveChatJid === chatJid)
                        onClicked: {
                            var dlg = pageStack.push(liveDurationDialog)
                            dlg.accepted.connect(function() {
                                startLiveShare(chatJid, [15, 60, 480][dlg.durationIndex])
                            })
                        }
                    }
                    MenuItem {
                        text: loc.stopLiveLocation
                        visible: !chatPageItem.isLandscape && (liveActive && liveChatJid === chatJid)
                        onClicked: stopLiveShare()
                    }
                    MenuItem {
                        text: loc.sendLocation
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
                        text: loc.disappearingMessages
                        visible: chatJid !== "status" && !isChannel
                        onClicked: {
                            var dlg = pageStack.push(disappearingDialog, { chatJid: chatJid })
                        }
                    }
                    MenuItem {
                        text: loc.clearChat
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
                        text: loc.deleteChat
                        visible: !chatPageItem.isLandscape && (chatJid !== "status" && !isChannel)
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
                        text: loc.loadOlder
                        visible: !chatPageItem.isLandscape && (chatJid !== "status" && !isChannel && !isChannel)
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
                        text: loc.createPoll
                        visible: chatJid !== "status" && !isChannel && (!chatPageItem.isLandscape || isGroupChat)
                        onClicked: pageStack.push(createPollPage, { targetChat: chatJid })
                    }
                    MenuItem {
                        text: loc.groupInfo
                        visible: !chatPageItem.isLandscape && (isGroupChat)
                        onClicked: pageStack.push(groupInfoPage, { groupJid: chatJid })
                    }
                    MenuItem {
                        text: loc.blockContact
                        visible: !chatPageItem.isLandscape && (!isGroupChat && chatJid !== "status" && !isChannel)
                        onClicked: blockRemorse.execute("Blocking +" + chatJid, function() { blockAction("block") })
                    }
                    MenuItem {
                        text: loc.unblockContact
                        visible: !chatPageItem.isLandscape && (!isGroupChat && chatJid !== "status" && !isChannel)
                        onClicked: blockAction("unblock")
                    }
                    MenuItem {
                        text: loc.call + " +" + chatJid
                        visible: !isGroupChat && chatJid !== "status" && !isChannel
                        onClicked: Qt.openUrlExternally("tel:+" + chatJid)
                    }
                    MenuItem { text: loc.sendFile; visible: !chatPageItem.isLandscape && (chatJid !== "status" && !isChannel); onClicked: pageStack.push(filePicker) }
                    MenuItem { text: loc.sendImage; visible: !chatPageItem.isLandscape && (chatJid !== "status" && !isChannel); onClicked: pageStack.push(imagePicker) }
                    MenuItem { visible: !chatPageItem.isLandscape; text: loc.refresh; onClicked: load() }
                }

                PullDownMenu {
                    MenuItem {
                        text: loc.refreshChannel
                        visible: !chatPageItem.isLandscape && (isChannel)
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
                        text: loc.unfollowChannel
                        visible: !chatPageItem.isLandscape && (isChannel)
                        onClicked: blockRemorse.execute("Unfollowing channel", function() {
                            var xhr = new XMLHttpRequest()
                            xhr.open("GET", "http://127.0.0.1:" + backendPort + "/channel/unfollow?jid=" + chatJid)
                            xhr.send()
                        })
                    }
                    MenuItem {
                        text: loc.loadHistory
                        visible: !chatPageItem.isLandscape && (chatJid !== "status" && !isChannel)
                        onClicked: {
                            var xhr = new XMLHttpRequest()
                            xhr.open("GET", "http://127.0.0.1:" + backendPort + "/history/request?chat=" + chatJid)
                            xhr.onreadystatechange = function() {
                                if (xhr.readyState === 4) {
                                    globalNotice = xhr.status === 200 ? xhr.responseText : ("History request failed: " + xhr.responseText)
                                }
                            }
                            xhr.send()
                        }
                    }
                    MenuItem {
                        text: loc.searchInChat
                        onClicked: pageStack.push(searchPage, { scopeJid: chatJid, scopeName: chatName })
                    }
                    MenuItem {
                        text: loc.shareLiveLocation
                        visible: chatJid !== "status" && !isChannel && !(liveActive && liveChatJid === chatJid)
                        onClicked: {
                            var dlg = pageStack.push(liveDurationDialog)
                            dlg.accepted.connect(function() {
                                startLiveShare(chatJid, [15, 60, 480][dlg.durationIndex])
                            })
                        }
                    }
                    MenuItem {
                        text: loc.stopLiveLocation
                        visible: !chatPageItem.isLandscape && (liveActive && liveChatJid === chatJid)
                        onClicked: stopLiveShare()
                    }
                    MenuItem {
                        text: loc.sendLocation
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
                        text: loc.disappearingMessages
                        visible: chatJid !== "status" && !isChannel
                        onClicked: {
                            var dlg = pageStack.push(disappearingDialog, { chatJid: chatJid })
                        }
                    }
                    MenuItem {
                        text: loc.clearChat
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
                        text: loc.deleteChat
                        visible: !chatPageItem.isLandscape && (chatJid !== "status" && !isChannel)
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
                        text: loc.loadOlder
                        visible: !chatPageItem.isLandscape && (chatJid !== "status" && !isChannel && !isChannel)
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
                        text: loc.createPoll
                        // Im Querformat ist nur Platz fuer sechs Punkte: dort weicht die
                        // Umfrage im Einzelchat dem Anrufen. In einem Zweiergespraech ist
                        // eine Umfrage ohnehin selten das, was man sucht
                        visible: chatJid !== "status" && !isChannel
                                 && (!chatPageItem.isLandscape || isGroupChat)
                        onClicked: pageStack.push(createPollPage, { targetChat: chatJid })
                    }
                    MenuItem {
                        text: loc.groupInfo
                        visible: !chatPageItem.isLandscape && (isGroupChat)
                        onClicked: pageStack.push(groupInfoPage, { groupJid: chatJid })
                    }
                    MenuItem {
                        text: loc.blockContact
                        visible: !chatPageItem.isLandscape && (!isGroupChat && chatJid !== "status" && !isChannel)
                        onClicked: blockRemorse.execute("Blocking +" + chatJid, function() { blockAction("block") })
                    }
                    MenuItem {
                        text: loc.unblockContact
                        visible: !chatPageItem.isLandscape && (!isGroupChat && chatJid !== "status" && !isChannel)
                        onClicked: blockAction("unblock")
                    }
                    MenuItem {
                        text: loc.call + " +" + chatJid
                        // Nimmt im Querformat den Platz der Umfrage ein
                        visible: !isGroupChat && chatJid !== "status" && !isChannel
                        onClicked: Qt.openUrlExternally("tel:+" + chatJid)
                    }
                    MenuItem {
                        text: loc.sendFile
                        visible: !chatPageItem.isLandscape && chatJid !== "status" && !isChannel
                        onClicked: pageStack.push(filePicker)
                    }
                    MenuItem {
                        text: loc.sendImage
                        visible: !chatPageItem.isLandscape && chatJid !== "status" && !isChannel
                        onClicked: pageStack.push(imagePicker)
                    }
                    MenuItem {
                        text: loc.refresh
                        visible: !chatPageItem.isLandscape
                        onClicked: load()
                    }
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
                                 || (chatPageItem.selectMode && chatPageItem.isSelected(modelData.id))
                    // Im Auswahlmodus waehlt ein Tipp aus, statt das Medium
                    // zu oeffnen - sonst kaeme man aus dem Modus nie heraus
                    onClicked: if (chatPageItem.selectMode) chatPageItem.toggleSelect(modelData.id)
                    Label {
                        visible: chatPageItem.selectMode
                        anchors {
                            right: parent.right
                            rightMargin: Theme.paddingSmall
                            top: parent.top
                            topMargin: Theme.paddingSmall
                        }
                        text: chatPageItem.isSelected(modelData.id) ? "\u2611" : "\u2610"
                        color: Theme.highlightColor
                        font.pixelSize: Theme.fontSizeLarge
                    }
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
                            text: loc.reply
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
                            text: loc.edit
                            visible: modelData.fromMe && !modelData.revoked && !modelData.mediaType && modelData.text !== ""
                            onClicked: {
                                editingId = modelData.id
                                input.text = modelData.text
                                input.forceActiveFocus()
                            }
                        }
                        MenuItem {
                            text: loc.deleteForEveryone
                            visible: modelData.fromMe && !modelData.revoked
                            onClicked: revokeMessage(modelData.id)
                        }
                        MenuItem {
                            text: loc.callBack + " +" + modelData.sender
                            visible: modelData.text && modelData.text.indexOf("\ud83d\udcde") === 0 && !modelData.fromMe
                            onClicked: Qt.openUrlExternally("tel:+" + modelData.sender)
                        }
                        MenuItem {
                            text: loc.open
                            visible: !!modelData.localPath
                            onClicked: modelData.mediaType === "image"
                                       ? pageStack.push(statusFullscreen, { imagePath: modelData.localPath, caption: modelData.text || "" })
                                       : modelData.mediaType === "video"
                                         ? pageStack.push(videoPlayerPage, { videoPath: modelData.localPath })
                                         : modelData.mediaType === "audio"
                                           ? pageStack.push(audioPlayerPage, { audioPath: modelData.localPath, title: modelData.text || "Audio" })
                                           : Qt.openUrlExternally("file://" + modelData.localPath)
                        }
                        MenuItem {
                            text: loc.copyText
                            visible: modelData.text && modelData.text !== ""
                            onClicked: Clipboard.text = modelData.text
                        }
                        MenuItem {
                            text: loc.forward
                            visible: !modelData.revoked && !modelData.pollName
                            onClicked: pageStack.push(forwardPage, { forwardIds: [modelData.id] })
                        }
                        MenuItem {
                            text: loc.selectMessages
                            visible: !modelData.revoked && !modelData.pollName
                            onClicked: {
                                chatPageItem.selectMode = true
                                chatPageItem.toggleSelect(modelData.id)
                            }
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
                            text: loc.joinGroup
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

                    // Im Zeilenmodus faerbt ein Streifen die ganze Zeile -
                    // eigene Nachrichten heller, fremde dunkler. Ohne die
                    // Seitenzuordnung muss die Farbe tragen, was sonst die
                    // Ausrichtung leistet.
                    Rectangle {
                        visible: lineMode
                        anchors.fill: parent
                        color: modelData.fromMe
                               ? Theme.rgba(Theme.highlightBackgroundColor, 0.18)
                               : Theme.rgba(Theme.primaryColor, 0.06)
                        z: -1
                    }

                    Column {
                        id: msgContent
                        width: lineMode ? parent.width - 2*Theme.horizontalPageMargin
                                        : parent.width * 0.8
                        anchors.right: (lineMode || !modelData.fromMe) ? undefined : parent.right
                        anchors.left: (lineMode || modelData.fromMe) ? undefined : parent.left
                        anchors.horizontalCenter: lineMode ? parent.horizontalCenter : undefined
                        anchors.margins: Theme.horizontalPageMargin
                        spacing: Theme.paddingSmall

                        Column {
                            visible: modelData.mediaType === "poll"
                            width: parent.width
                            spacing: Theme.paddingSmall



                            Label {
                                text: "📊 " + (modelData.pollName || loc.poll)
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
                                    Label { text: loc.location; font.pixelSize: Theme.fontSizeSmall }
                                    Label {
                                        text: loc.tapToOpenMaps
                                        font.pixelSize: Theme.fontSizeExtraSmall
                                        color: Theme.secondaryColor
                                    }
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                onClicked: {
                                    if (!modelData.latitude && !modelData.longitude) {
                                        globalNotice = "No coordinates in this message (sharing may have ended before a fix arrived)"
                                        return
                                    }
                                    Qt.openUrlExternally("geo:" + modelData.latitude + "," + modelData.longitude)
                                }
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
                                    text: locMsg(modelData.quotedText) || ""
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
                            text: (modelData.forwarded ? "\u21aa " + loc.forwarded + "  " : "")
                                  + (modelData.pinnedInChat ? "\ud83d\udccc " + loc.pinnedBadge + "  " : "")
                                  + (modelData.live ? "\ud83d\udd34 Live  " : "")
                                  + (mentionsMe ? "\ud83d\udd14 " + loc.mentionedYou + "  " : "")
                                  + ((modelData.ephemeral !== undefined && modelData.ephemeral > 0) ? "\u23f3" : "")
                            font.pixelSize: Theme.fontSizeTiny
                            color: Theme.secondaryHighlightColor
                        }

                        Label {
                            // Leeres Label nahm frueher trotzdem Platz ein und
                            // die Zeile fehlte kommentarlos - jetzt entweder
                            // ein echter Name oder gar keine Zeile
                            // Im Zeilenmodus fehlt die Seitenzuordnung, also
                            // muss der Name auch im Einzelchat und bei eigenen
                            // Nachrichten stehen - sonst weiss man nicht mehr,
                            // wer was geschrieben hat. Eigene heissen schlicht
                            // "Ich", der Name waere hier ohne Aussage.
                            visible: lineMode
                                     ? true
                                     : (isGroupChat && !modelData.fromMe
                                        && senderDisplay(modelData.sender) !== "")
                            text: {
                                if (!visible) return ""
                                if (modelData.fromMe) return lineMode ? loc.meSender : ""
                                var n = senderDisplay(modelData.sender)
                                return n !== "" ? n : (lineMode ? loc.unknownSender : "")
                            }
                            font.pixelSize: Theme.fontSizeExtraSmall
                            font.bold: true
                            color: modelData.fromMe
                                   ? Theme.highlightColor
                                   : (visible ? senderColor(modelData.sender) : Theme.primaryColor)
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
                                    text: loc.tapToDownload + (modelData.fileSize ? " (" + formatSize(modelData.fileSize) + ")" : "")
                                    font.pixelSize: Theme.fontSizeExtraSmall
                                    color: Theme.secondaryColor
                                    anchors.horizontalCenter: parent.horizontalCenter
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                onClicked: {
                                    if (!modelData.localPath) { downloadMediaFor(modelData.id); return }
                                    if (modelData.mediaType === "image")
                                        pageStack.push(statusFullscreen, { imagePath: modelData.localPath, caption: modelData.text || "" })
                                    else if (modelData.mediaType === "video")
                                        pageStack.push(videoPlayerPage, { videoPath: modelData.localPath })
                                    else if (modelData.mediaType === "audio")
                                        pageStack.push(audioPlayerPage, { audioPath: modelData.localPath, title: modelData.text || "Audio" })
                                    else
                                        Qt.openUrlExternally("file://" + modelData.localPath)
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
                                    Label { text: formatSize(modelData.fileSize) + (modelData.localPath ? "" : " · " + loc.tapToDownloadLower); font.pixelSize: Theme.fontSizeExtraSmall; color: Theme.secondaryColor }
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
                                onClicked: {
                                    if (!modelData.localPath) { downloadMediaFor(modelData.id); return }
                                    if (modelData.mediaType === "image")
                                        pageStack.push(statusFullscreen, { imagePath: modelData.localPath, caption: modelData.text || "" })
                                    else if (modelData.mediaType === "video")
                                        pageStack.push(videoPlayerPage, { videoPath: modelData.localPath })
                                    else if (modelData.mediaType === "audio")
                                        pageStack.push(audioPlayerPage, { audioPath: modelData.localPath, title: modelData.text || "Audio" })
                                    else
                                        Qt.openUrlExternally("file://" + modelData.localPath)
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
                                Label { text: "Audio · " + formatSize(modelData.fileSize) + (modelData.localPath ? "" : " · " + loc.tapToDownloadLower); font.pixelSize: Theme.fontSizeSmall; color: Theme.secondaryColor }
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
                                onClicked: {
                                    if (!modelData.localPath) { downloadMediaFor(modelData.id); return }
                                    if (modelData.mediaType === "image")
                                        pageStack.push(statusFullscreen, { imagePath: modelData.localPath, caption: modelData.text || "" })
                                    else if (modelData.mediaType === "video")
                                        pageStack.push(videoPlayerPage, { videoPath: modelData.localPath })
                                    else if (modelData.mediaType === "audio")
                                        pageStack.push(audioPlayerPage, { audioPath: modelData.localPath, title: modelData.text || "Audio" })
                                    else
                                        Qt.openUrlExternally("file://" + modelData.localPath)
                                }
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
                                    Label { text: modelData.fileName || loc.document; font.pixelSize: Theme.fontSizeSmall }
                                    Label { text: formatSize(modelData.fileSize) + (modelData.localPath ? "" : " · " + loc.tapToDownloadLower); font.pixelSize: Theme.fontSizeExtraSmall; color: Theme.secondaryColor }
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
                                onClicked: {
                                    if (!modelData.localPath) { downloadMediaFor(modelData.id); return }
                                    if (modelData.mediaType === "image")
                                        pageStack.push(statusFullscreen, { imagePath: modelData.localPath, caption: modelData.text || "" })
                                    else if (modelData.mediaType === "video")
                                        pageStack.push(videoPlayerPage, { videoPath: modelData.localPath })
                                    else if (modelData.mediaType === "audio")
                                        pageStack.push(audioPlayerPage, { audioPath: modelData.localPath, title: modelData.text || "Audio" })
                                    else
                                        Qt.openUrlExternally("file://" + modelData.localPath)
                                }
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
                            width: lineMode ? parent.width
                                   : Math.min(msgTxt.implicitWidth + Theme.paddingLarge * 2, parent.width)
                            height: visible ? msgTxt.height + Theme.paddingMedium * 2 : 0
                            // Im Zeilenmodus traegt der Streifen die Farbe -
                            // eine zweite Flaeche darauf ergaebe Kaesten in
                            // Kaesten, also genau die Blasen, die weg sollten
                            color: lineMode ? "transparent"
                                   : (modelData.fromMe
                                      ? Theme.rgba(Theme.highlightBackgroundColor, Theme.highlightBackgroundOpacity)
                                      : Theme.rgba(Theme.primaryColor, 0.1))
                            radius: lineMode ? 0 : Theme.paddingMedium

                            Label {
                                id: msgTxt
                                anchors.centerIn: parent
                                width: parent.width - Theme.paddingLarge * 2
                                text: linkify(mentionsToNames(locMsg(modelData.text)))
                                textFormat: Text.StyledText
                                linkColor: Theme.highlightColor
                                onLinkActivated: Qt.openUrlExternally(link)
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
                            text: formatTime(modelData.timestamp) + (modelData.edited ? " · " + loc.edited : "")
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
                    text: loc.noMessages
                    hintText: loc.noMessagesHint
                }
            }

            Column {
                id: inputCol
                width: parent.width
                anchors.bottom: parent.bottom
                visible: chatJid !== "status" && !isChannel

                // Meldungen (z.B. fehlgeschlagenes Senden) hier zeigen: die
                // Anzeigen in Chatliste und Hauptseite sieht man beim Senden
                // nicht, der Fehler blieb deshalb unsichtbar
                BackgroundItem {
                    visible: globalNotice !== ""
                    width: parent.width
                    height: visible ? chatNoticeLbl.height + 2*Theme.paddingSmall : 0
                    onClicked: {
                        Clipboard.text = globalNotice
                        globalNotice = loc.copiedToClipboard
                    }
                    Label {
                        id: chatNoticeLbl
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*x
                        anchors.verticalCenter: parent.verticalCenter
                        text: globalNotice + (noticeLooksLikeError()
                                              ? "\n" + loc.tapToCopy : "")
                        wrapMode: Text.Wrap
                        font.pixelSize: Theme.fontSizeSmall
                        color: noticeLooksLikeError() ? Theme.errorColor : Theme.highlightColor
                    }
                }

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

                // Bedienleiste des Auswahlmodus: zeigt, wie viele gewaehlt
                // sind, und bietet Weiterleiten und Abbrechen. Ohne sie
                // waere der Modus eine Sackgasse.
                Row {
                    visible: chatPageItem.selectMode
                    width: parent.width
                    height: visible ? Theme.itemSizeSmall : 0
                    spacing: Theme.paddingLarge
                    Label {
                        anchors.verticalCenter: parent.verticalCenter
                        x: Theme.horizontalPageMargin
                        text: loc.selectedCount.replace("%1", chatPageItem.selectedIds.length)
                        color: Theme.highlightColor
                    }
                    Button {
                        anchors.verticalCenter: parent.verticalCenter
                        text: loc.forward
                        enabled: chatPageItem.selectedIds.length > 0
                        onClicked: {
                            pageStack.push(forwardPage, {
                                forwardIds: chatPageItem.selectedIds.slice()
                            })
                            chatPageItem.endSelect()
                        }
                    }
                    Button {
                        anchors.verticalCenter: parent.verticalCenter
                        text: loc.cancel
                        onClicked: chatPageItem.endSelect()
                    }
                }

                // Emoji-Auswahl ueber der Eingabe. Bewusst eine feste, kleine
                // Auswahl der gebraeuchlichsten Zeichen statt aller 4010 -
                // ein Raster mit tausenden Eintraegen waere weder schnell
                // noch benutzbar, und fuer alles Weitere gibt es weiterhin
                // die Tastatur.
                Flickable {
                    id: emojiPanel
                    visible: false
                    width: parent.width
                    height: visible ? Theme.itemSizeExtraLarge * 1.6 : 0
                    contentHeight: emojiFlow.height
                    clip: true
                    Flow {
                        id: emojiFlow
                        width: parent.width
                        spacing: Theme.paddingSmall
                        Repeater {
                            model: [
                                "\ud83d\ude00","\ud83d\ude02","\ud83d\ude0a","\ud83d\ude09","\ud83d\ude0d",
                                "\ud83d\ude18","\ud83d\ude17","\ud83d\ude1b","\ud83d\ude1c","\ud83d\ude0e",
                                "\ud83e\udd14","\ud83d\ude10","\ud83d\ude44","\ud83d\ude22","\ud83d\ude2d",
                                "\ud83d\ude21","\ud83d\ude33","\ud83d\ude31","\ud83e\udd17","\ud83d\ude4f",
                                "\ud83d\udc4d","\ud83d\udc4e","\ud83d\udc4c","\u270c\ufe0f","\ud83d\udc4f",
                                "\ud83d\udcaa","\u2764\ufe0f","\ud83d\udc94","\ud83c\udf89","\ud83c\udf82",
                                "\ud83c\udf81","\u2600\ufe0f","\u2601\ufe0f","\u2744\ufe0f","\ud83c\udf27\ufe0f",
                                "\ud83c\udf55","\u2615","\ud83c\udf7a","\ud83c\udf70","\ud83c\udf4e",
                                "\ud83d\ude97","\u2708\ufe0f","\u26bd","\ud83c\udfb5","\ud83d\udcde",
                                "\ud83d\udcbb","\u23f0","\u2705","\u274c","\u2757"
                            ]
                            delegate: BackgroundItem {
                                width: Theme.itemSizeSmall
                                height: Theme.itemSizeSmall
                                onClicked: {
                                    var p0 = input.cursorPosition
                                    input.text = input.text.substring(0, p0) + modelData
                                                 + input.text.substring(p0)
                                    input.cursorPosition = p0 + modelData.length
                                }
                                // Bei eingeschalteten Farb-Emojis dasselbe
                                // Bild wie im Chat - sonst zeigte die Auswahl
                                // schwarzweisse Systemzeichen und die Nachricht
                                // danach ein farbiges, was verwirrt.
                                // getEmojiPath entfernt FE0F nach derselben
                                // Regel wie beim Nachrichtentext.
                                Image {
                                    visible: emojiEnabled
                                    anchors.centerIn: parent
                                    width: Theme.iconSizeSmall
                                    height: Theme.iconSizeSmall
                                    sourceSize.width: Theme.iconSizeSmall
                                    sourceSize.height: Theme.iconSizeSmall
                                    asynchronous: true
                                    source: emojiEnabled ? Twemoji.getEmojiPath(modelData) : ""
                                }
                                Label {
                                    visible: !emojiEnabled
                                    anchors.centerIn: parent
                                    text: modelData
                                    font.pixelSize: Theme.fontSizeLarge
                                }
                            }
                        }
                    }
                }

                Row {
                    width: parent.width
                    property bool recording: false
                    property int recSeconds: 0
                    id: inputRow

                    Timer {
                        id: recTimer
                        interval: 1000
                        repeat: true
                        running: inputRow.recording
                        onTriggered: inputRow.recSeconds++
                    }

                    Component.onDestruction: {
                        // Chat verlassen waehrend der Aufnahme: abbrechen,
                        // sonst laeuft das Mikrofon unsichtbar weiter
                        if (inputRow.recording) python.call('start_backend.voice_cancel', [])
                    }

                    IconButton {
                        icon.source: inputRow.recording ? "image://theme/icon-m-clear"
                                                        : "image://theme/icon-m-attach"
                        onClicked: {
                            if (inputRow.recording) {
                                // Aufnahme verwerfen
                                inputRow.recording = false
                                python.call('start_backend.voice_cancel', [])
                                globalNotice = "Recording discarded"
                            } else if (attachPicker === "content") {
                                pageStack.push(contentPicker)
                            } else if (attachPicker === "file") {
                                pageStack.push(filePicker)
                            } else {
                                pageStack.push(attachChooser)
                            }
                        }
                    }

                    IconButton {
                        id: emojiBtn
                        // Ohne diesen Knopf muss man fuer jedes Emoji die
                        // Tastatur umschalten - Wunsch von rdomschk. Die
                        // Auswahl klappt ueber der Eingabe auf.
                        icon.source: "image://theme/icon-m-other"
                        highlighted: emojiPanel.visible
                        anchors.verticalCenter: parent.verticalCenter
                        onClicked: emojiPanel.visible = !emojiPanel.visible
                    }

                    TextArea {
                        id: input
                        width: parent.width - sendBtn.width - parent.children[0].width
                               - emojiBtn.width
                        // Wachstum bei ~5 Zeilen deckeln (OpenRepos-Wunsch:
                        // lange Texte fuellten den ganzen Schirm) - darueber
                        // scrollt der Inhalt innerhalb des Felds. Zeilenhoehe
                        // aus font.pixelSize genaehert (~1.4x) statt
                        // FontMetrics: der Typ braucht QtQuick 2.4+ und
                        // liess die gesamte QML-Ladung sterben (weisser
                        // Schirm auf dem Geraet)
                        height: Math.min(implicitHeight,
                                         Math.ceil(font.pixelSize * 1.4) * 5 + Theme.paddingLarge * 2)
                        placeholderText: inputRow.recording
                                         ? ("Recording… " + Math.floor(inputRow.recSeconds / 60)
                                            + ":" + (inputRow.recSeconds % 60 < 10 ? "0" : "")
                                            + (inputRow.recSeconds % 60))
                                         : "Message..."
                        enabled: !inputRow.recording
                        // Send by Enter ist Opt-in (Settings): default fuegt
                        // Enter eine neue Zeile ein, gesendet wird per Knopf
                        EnterKey.iconSource: sendByEnter ? "image://theme/icon-m-enter-accept"
                                                         : "image://theme/icon-m-enter"
                        EnterKey.onClicked: {
                            if (sendByEnter) {
                                send()
                            } else {
                                var p = cursorPosition
                                text = text.slice(0, p) + "\n" + text.slice(p)
                                cursorPosition = p + 1
                            }
                        }
                        backgroundStyle: TextEditor.NoBackground
                        onTextChanged: updateMentionToken()
                    }

                    IconButton {
                        id: sendBtn
                        icon.source: inputRow.recording ? "image://theme/icon-m-send"
                                     : (input.text.length > 0 ? "image://theme/icon-m-send"
                                                              : "image://theme/icon-m-mic")
                        highlighted: inputRow.recording
                        onClicked: {
                            if (inputRow.recording) {
                                // Stoppen und senden
                                inputRow.recording = false
                                var secs = inputRow.recSeconds
                                if (secs < 1) {
                                    // Doppeltipp: 0-Sekunden-Notes will niemand
                                    python.call('start_backend.voice_cancel', [])
                                    globalNotice = "Too short - discarded"
                                    return
                                }
                                python.call('start_backend.voice_stop', [], function(path) {
                                    if (!path) {
                                        globalNotice = "Recording failed - is gst-launch-1.0 available?"
                                        return
                                    }
                                    var xhr = new XMLHttpRequest()
                                    xhr.open("GET", "http://127.0.0.1:" + backendPort + "/send/voice?to=" + chatJid
                                             + "&file=" + encodeURIComponent(path) + "&seconds=" + secs)
                                    xhr.onreadystatechange = function() {
                                        if (xhr.readyState !== 4) return
                                        if (xhr.status === 200) { load() }
                                        else {
                                            globalNotice = sendErrorText(xhr.status, xhr.responseText)
                                            noticeIsError = true
                                            if (sendRejectCode(xhr.responseText) > 0 && msgs.length === 0) {
                                                sendBlocked = true
                                            }
                                        }
                                    }
                                    xhr.send()
                                })
                            } else if (input.text.length > 0) {
                                send()
                            } else {
                                // Aufnahme starten - aber nur mit ausgewiesener
                                // Mikrofon-Berechtigung: die Audio-Permission
                                // wuerde pulsesrc technisch auch erlauben
                                // (upstream-FIXME: Streams nicht trennbar),
                                // doch die Settings versprechen Aufnahme nur
                                // fuer Microphone - dieses Versprechen haelt
                                // die App selbst ein
                                var pxr = new XMLHttpRequest()
                                pxr.open("GET", "http://127.0.0.1:" + backendPort + "/permcheck")
                                pxr.onreadystatechange = function() {
                                    if (pxr.readyState !== 4) return
                                    var mic = false
                                    try { mic = JSON.parse(pxr.responseText).micPermission === true } catch (e) {}
                                    if (!mic) {
                                        globalNotice = "Voice notes need the Microphone permission. Open Settings INSIDE this app \u2192 'Sailjail permissions' \u2192 tap the GRANT microphone command (copies to clipboard), run it in Terminal, restart the app. The Sailfish Settings app cannot add it."
                                        return
                                    }
                                python.call('start_backend.voice_start', [], function(res) {
                                    if (res === true) {
                                        inputRow.recSeconds = 0
                                        inputRow.recording = true
                                        globalNotice = "Recording - tap \u2716 to discard, send to deliver"
                                    } else {
                                        globalNotice = "Recording failed (" + res + ") - grant the "
                                                     + "microphone permission in Settings and restart the app"
                                    }
                                })
                                }
                                pxr.send()
                            }
                        }
                    }
                }
            }

            // Der Name des Gespraechspartners war durch die Transparenz des
            // Kopfes schwer zu lesen. Dahinter liegt jetzt derselbe leicht
            // abgesetzte Grund wie unter der Bodenleiste, und daneben steht
            // das Bild - so erkennt man den Chat auch beim Ueberfliegen.
            // Wunsch von rdomschk.
            Rectangle {
                anchors.fill: pageHead
                // 0.12 war zu zart - der Name blieb schwer zu lesen. Deutlich
                // dichter, damit die Schrift auf ruhigem Grund steht statt auf
                // dem durchscheinenden Ambiente-Bild.
                // Durchscheinend, seit die Liste nicht mehr dahinter laeuft.
                // Ein echter Weichzeichner braeuchte einen ShaderEffect ueber
                // dem Ambiente-Bild, an das eine App nicht herankommt -
                // stattdessen ein weicher Verlauf nach unten, der denselben
                // Zweck erfuellt: oben traegt die Flaeche den Text, unten geht
                // sie ohne Kante in die Liste ueber (rdomschk).
                gradient: Gradient {
                    GradientStop {
                        position: 0.0
                        color: Theme.rgba(Theme.highlightBackgroundColor, 0.35)
                    }
                    GradientStop {
                        position: 1.0
                        color: Theme.rgba(Theme.highlightBackgroundColor, 0.05)
                    }
                }
                z: 9
            }
            // Praesenz des Gespraechspartners. Wird beim Oeffnen des Chats
            // abgefragt - eine Anfrage bei einer bewussten Handlung, nicht
            // hunderte im Hintergrund. Der Abruf abonniert zugleich, damit es
            // auch bei einem frisch begonnenen Chat sofort greift.
            property string presenceText: ""
            function loadPresence() {
                if (!chatJid || chatJid === "status" || isGroupChat) return
                var x = new XMLHttpRequest()
                x.open("GET", "http://127.0.0.1:" + backendPort
                       + "/presence?jid=" + encodeURIComponent(chatJid))
                x.onreadystatechange = function() {
                    if (x.readyState !== 4 || x.status !== 200) return
                    try {
                        var p = JSON.parse(x.responseText)
                        if (p.hiddenBySetting) { presenceText = ""; return }
                        if (!p.known) { presenceText = ""; return }
                        if (p.online) { presenceText = loc.presenceOnline; return }
                        presenceText = p.lastSeen > 0
                            ? loc.presenceLastSeen.replace("%1",
                                Qt.formatDateTime(new Date(p.lastSeen * 1000), "dd.MM. hh:mm"))
                            : ""
                    } catch (e) { presenceText = "" }
                }
                x.send()
            }
            Timer {
                // Nachfassen: die Antwort des Servers trifft erst nach dem
                // Abonnieren ein, der erste Abruf ist deshalb meist leer
                id: presencePoll
                interval: 4000
                repeat: true
                running: !!chatJid && !isGroupChat && chatJid !== "status"
                triggeredOnStart: true
                onTriggered: loadPresence()
            }

            PageHeader {
                id: pageHead
                // Vor der Liste, falls doch einmal etwas darueber hinausragt -
                // Gurt und Hosentraeger, wie bei der Bodenleiste
                z: 10
                title: chatName
                description: presenceText
                Image {
                    visible: !!chatJid && chatJid !== "status"
                    anchors {
                        left: parent.left
                        leftMargin: Theme.horizontalPageMargin
                        verticalCenter: parent.verticalCenter
                    }
                    width: Theme.iconSizeMedium
                    height: Theme.iconSizeMedium
                    sourceSize.width: Theme.iconSizeMedium
                    sourceSize.height: Theme.iconSizeMedium
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    source: chatJid
                            ? "http://127.0.0.1:" + backendPort + "/avatar/" + chatJid
                            : ""
                }
            }

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
            allowedOrientations: orientationMask()
            // Mehrere Nachrichten auf einmal. Sie gehen NACHEINANDER raus,
            // mit Abstand - ein Schwall gleichzeitiger Weiterleitungen ist
            // genau das Muster, das hier schon eine Kontosperre einbrachte.
            property var forwardIds: []
            Timer {
                id: fwdGap
                interval: 900
                property var action: null
                onTriggered: if (action) action()
            }
            property string forwardId: ""
            SilicaListView {
                anchors.fill: parent
                header: PageHeader { title: loc.forwardTo }
                model: chats.filter(function(c) { return c.jid !== "status" && !c.isChannel })
                delegate: ListItem {
                    Label {
                        x: Theme.horizontalPageMargin
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.name || ("+" + modelData.jid)
                    }
                    // Wer in der Liste bleibt, um an mehrere zu schicken, sieht
                    // sonst nicht, wen er schon erwischt hat - und tippt zweimal
                    property bool sent: false
                    // Waehrend des Sendens gesperrt. Ohne Rueckmeldung tippt
                    // man nach, und jeder Tipp schickte bisher erneut - das
                    // Bild kam mehrfach an. Ein Empfaenger ist pro
                    // Weiterleitung genau einmal dran; die Seite wird fuer
                    // jede neue Weiterleitung neu aufgebaut, damit setzt sich
                    // die Sperre von selbst zurueck.
                    property bool busy: false
                    enabled: !sent && !busy
                    Label {
                        anchors {
                            right: parent.right
                            rightMargin: Theme.horizontalPageMargin
                            verticalCenter: parent.verticalCenter
                        }
                        visible: sent || busy
                        // Waehrend des Sendens Punkte, danach der Haken -
                        // ohne dieses Zeichen weiss niemand, ob etwas laeuft
                        text: busy ? "\u2026" : "\u2713"
                        color: Theme.highlightColor
                    }
                    onClicked: {
                        if (sent || busy) return
                        busy = true
                        var target = modelData.name || ("+" + modelData.jid)
                        var ids = (forwardIds && forwardIds.length > 0)
                                  ? forwardIds.slice() : [forwardId]
                        var done = 0, failed = false
                        function step() {
                            if (done >= ids.length) {
                                busy = false
                                if (!failed) {
                                    sent = true
                                    globalNotice = ids.length > 1
                                        ? loc.forwardedCountTo.replace("%1", ids.length)
                                                              .replace("%2", target)
                                        : loc.forwardedTo.replace("%1", target)
                                    if (!forwardStay) pageStack.pop()
                                }
                                return
                            }
                            var xhr = new XMLHttpRequest()
                            xhr.open("GET", "http://127.0.0.1:" + backendPort
                                     + "/msg/forward?to=" + modelData.jid
                                     + "&id=" + encodeURIComponent(ids[done]))
                            xhr.onreadystatechange = function() {
                                if (xhr.readyState !== 4) return
                                if (xhr.status !== 200) {
                                    failed = true
                                    busy = false
                                    globalNotice = loc.forwardFailed + ": " + xhr.responseText
                                    noticeIsError = true
                                    pageStack.pop()
                                    return
                                }
                                done++
                                // Abstand zwischen den einzelnen Nachrichten
                                if (done < ids.length) fwdGap.restart()
                                else step()
                            }
                            xhr.send()
                        }
                        fwdGap.action = step
                        step()
                    }
                }
                VerticalScrollDecorator {}
            }
        }
    }

    Component {
        id: disappearingDialog
        Dialog {
            allowedOrientations: orientationMask()
            property string chatJid: ""
            property int chosen: -1
            Column {
                width: parent.width
                spacing: Theme.paddingMedium
                DialogHeader { title: loc.disappearingTitle }
                ComboBox {
                    id: ephemeralCombo
                    label: loc.timer
                    menu: ContextMenu {
                        MenuItem { text: loc.off }
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
                    text: loc.disappearingNote
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
            allowedOrientations: orientationMask()
            property string descText: descArea.text
            Column {
                width: parent.width
                DialogHeader { title: loc.groupDescription }
                TextArea {
                    id: descArea
                    width: parent.width
                    placeholderText: loc.description
                }
            }
        }
    }

    Component {
        id: joinRequestsPage
        Page {
            allowedOrientations: orientationMask()
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
                    PageHeader { title: loc.joinRequests }
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
                        MenuItem { text: loc.approve; onClicked: decide(modelData.number, "approve") }
                        MenuItem { text: loc.reject;  onClicked: decide(modelData.number, "reject") }
                    }
                }
                VerticalScrollDecorator {}
            }
        }
    }

    Component {
        id: locationDialog
        Dialog {
            allowedOrientations: orientationMask()
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
                DialogHeader { title: loc.sendLocationTitle }
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
                    label: loc.latitude
                    placeholderText: "48.2082"
                    inputMethodHints: Qt.ImhFormattedNumbersOnly
                }
                TextField {
                    id: lonField
                    width: parent.width
                    label: loc.longitude
                    placeholderText: "16.3738"
                    inputMethodHints: Qt.ImhFormattedNumbersOnly
                }
                TextField {
                    id: nameField
                    width: parent.width
                    label: loc.labelOptional
                    placeholderText: "e.g. Meeting point"
                }
            }
        }
    }

    Component {
        id: liveDurationDialog
        Dialog {
            allowedOrientations: orientationMask()
            property int durationIndex: durCombo.currentIndex
            Column {
                width: parent.width
                spacing: Theme.paddingMedium
                DialogHeader { title: loc.shareLiveTitle }
                ComboBox {
                    id: durCombo
                    label: loc.duration
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
                    text: loc.liveLocationNote
                }
            }
        }
    }

    Component {
        id: channelDirectoryPage
        Page {
            allowedOrientations: orientationMask()
            id: chDirPage
            property var results: []
            property string dirStatus: ""
            property bool searching: false
            property string nextCursor: ""
            property string lastQuery: ""
            property int curLimit: 30
            property bool exhausted: false
            property double lastAutoLoad: 0

            function loadMore() {
                if (searching || exhausted) return
                if (nextCursor !== "") {
                    search(lastQuery, nextCursor, curLimit)
                } else {
                    // Kein Cursor in der Antwort: stattdessen mit groesserem
                    // Limit neu holen (Backend erlaubt bis 500)
                    curLimit = Math.min(curLimit + 50, 500)
                    search(lastQuery, "", curLimit)
                }
            }

            function search(q, cursor, limit) {
                searching = true
                dirStatus = ""
                lastQuery = q
                if (!limit) limit = curLimit
                var url = "http://127.0.0.1:" + backendPort + "/channels/search?query=" + encodeURIComponent(q) + "&limit=" + limit
                if (cursor) url += "&cursor=" + encodeURIComponent(cursor)
                var xhr = new XMLHttpRequest()
                xhr.open("GET", url)
                xhr.onreadystatechange = function() {
                    if (xhr.readyState === 4) {
                        searching = false
                        if (xhr.status === 200) {
                            var d = JSON.parse(xhr.responseText) || {}
                            var page = d.results || []
                            var before = results.length
                            results = cursor ? results.concat(page) : page
                            nextCursor = d.nextCursor || ""
                            // Nichts Neues trotz Nachladen -> Ende erreicht
                            exhausted = (cursor || before > 0) && results.length <= before
                            if (results.length === 0) dirStatus = "No channels found"
                            else if (d.localFilter) dirStatus = "Online search unavailable - showing matches from recommendations"
                            else dirStatus = ""
                        } else if (xhr.status === 429) {
                            dirStatus = "WhatsApp rate limit reached - wait a minute and try again"
                        } else {
                            dirStatus = xhr.responseText
                        }
                    }
                }
                xhr.send()
            }
            Component.onCompleted: search("")

            SilicaListView {
                anchors.fill: parent
                model: results
                header: Column {
                    width: parent ? parent.width : Screen.width
                    PageHeader { title: loc.discoverChannelsTitle }
                    SearchField {
                        id: dirSearch
                        width: parent.width
                        placeholderText: loc.searchChannels
                        EnterKey.iconSource: "image://theme/icon-m-search"
                        EnterKey.onClicked: { focus = false; chDirPage.curLimit = 30; chDirPage.exhausted = false; chDirPage.search(text) }
                    }
                    BusyIndicator {
                        anchors.horizontalCenter: parent.horizontalCenter
                        running: chDirPage.searching
                        size: BusyIndicatorSize.Medium
                    }
                    Label {
                        visible: chDirPage.dirStatus !== ""
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*x
                        text: chDirPage.dirStatus
                        wrapMode: Text.Wrap
                        color: Theme.secondaryColor
                    }
                }
                delegate: ListItem {
                    width: ListView.view.width
                    contentHeight: dirCol.height + 2*Theme.paddingMedium
                    onClicked: openMenu()
                    menu: Component {
                        ContextMenu {
                            MenuItem {
                                text: loc.follow
                                onClicked: {
                                    var xhr = new XMLHttpRequest()
                                    xhr.open("GET", "http://127.0.0.1:" + backendPort + "/channel/follow?jid=" + encodeURIComponent(modelData.jid))
                                    xhr.onreadystatechange = function() {
                                        if (xhr.readyState === 4) {
                                            globalNotice = xhr.status === 200 ? ("Following " + modelData.name) : ("Follow failed: " + xhr.responseText)
                                            if (xhr.status === 200) loadChats()
                                        }
                                    }
                                    xhr.send()
                                }
                            }
                        }
                    }
                    Column {
                        id: dirCol
                        x: Theme.horizontalPageMargin
                        width: parent.width - 2*x
                        anchors.verticalCenter: parent.verticalCenter
                        Label {
                            width: parent.width
                            text: modelData.name + (modelData.verified ? " \u2713" : "")
                            truncationMode: TruncationMode.Fade
                        }
                        Label {
                            width: parent.width
                            visible: !!modelData.description
                            text: modelData.description || ""
                            font.pixelSize: Theme.fontSizeExtraSmall
                            color: Theme.secondaryColor
                            maximumLineCount: 2
                            wrapMode: Text.Wrap
                            elide: Text.ElideRight
                        }
                        Label {
                            text: modelData.subscribers > 0 ? (modelData.subscribers + " followers") : ""
                            visible: modelData.subscribers > 0
                            font.pixelSize: Theme.fontSizeTiny
                            color: Theme.secondaryHighlightColor
                        }
                    }
                }
                onAtYEndChanged: {
                    // Infinite Scroll mit Abklingzeit: nie schneller als
                    // alle 3 s automatisch nachladen (Rate-Limit-Schutz)
                    if (atYEnd && chDirPage.results.length > 0
                            && Date.now() - chDirPage.lastAutoLoad > 3000) {
                        chDirPage.lastAutoLoad = Date.now()
                        chDirPage.loadMore()
                    }
                }
                footer: Item {
                    width: parent ? parent.width : Screen.width
                    height: chDirPage.results.length > 0 && !chDirPage.exhausted ? Theme.itemSizeMedium : 0
                    Button {
                        anchors.centerIn: parent
                        visible: parent.height > 0 && !chDirPage.searching
                        text: loc.loadMore
                        onClicked: chDirPage.loadMore()
                    }
                    BusyIndicator {
                        anchors.centerIn: parent
                        running: chDirPage.searching && chDirPage.results.length > 0
                        size: BusyIndicatorSize.Medium
                    }
                }
                VerticalScrollDecorator {}
            }
        }
    }

    Component {
        id: videoPlayerPage
        Page {
            id: vpPage
            property string videoPath: ""
            allowedOrientations: Orientation.All
            backgroundColor: "black"

            MediaPlayer {
                id: vplayer
                source: "file://" + vpPage.videoPath
                autoPlay: true
                onStatusChanged: if (status === MediaPlayer.EndOfMedia) vpControls.visible = true
            }
            VideoOutput {
                anchors.fill: parent
                source: vplayer
            }
            MouseArea {
                anchors.fill: parent
                onClicked: {
                    if (vplayer.playbackState === MediaPlayer.PlayingState) {
                        vplayer.pause()
                        vpControls.visible = true
                    } else {
                        vplayer.play()
                        vpControls.visible = false
                    }
                }
            }
            Column {
                id: vpControls
                visible: false
                anchors.bottom: parent.bottom
                anchors.bottomMargin: Theme.paddingLarge
                width: parent.width
                spacing: Theme.paddingSmall

                Slider {
                    width: parent.width
                    minimumValue: 0
                    maximumValue: vplayer.duration > 0 ? vplayer.duration : 1
                    value: vplayer.position
                    enabled: vplayer.seekable
                    onReleased: vplayer.seek(value)
                }
                Label {
                    anchors.horizontalCenter: parent.horizontalCenter
                    color: "white"
                    font.pixelSize: Theme.fontSizeSmall
                    function fmt(ms) {
                        var t = Math.floor(ms / 1000)
                        var m = Math.floor(t / 60)
                        var sec = t % 60
                        return m + ":" + (sec < 10 ? "0" : "") + sec
                    }
                    text: fmt(vplayer.position) + " / " + fmt(vplayer.duration)
                }
            }
            IconButton {
                anchors { top: parent.top; left: parent.left; margins: Theme.paddingLarge }
                icon.source: "image://theme/icon-m-back"
                onClicked: pageStack.pop()
            }
        }
    }

    Component {
        id: audioPlayerPage
        Page {
            allowedOrientations: orientationMask()
            id: apPage
            property string audioPath: ""
            property string title: "Audio"

            MediaPlayer {
                id: aplayer
                source: "file://" + apPage.audioPath
                autoPlay: true
                onPlaybackStateChanged: {
                    // Wiedergabe zu Ende/pausiert: Ohrhoerer-Praeferenz weg
                    if (playbackState !== MediaPlayer.PlayingState) apPage.setEarpiece(false)
                }
            }

            // --- Proximity-Earpiece: Telefon ans Ohr -> kleiner Lautsprecher
            // (Route Manager braucht die Audio-Berechtigung, die in der
            // Mikrofon-Berechtigung enthalten ist; ohne sie scheitert der
            // D-Bus-Ruf stumm und alles bleibt beim Lautsprecher)
            property int earpieceType: 0     // geraetespezifisch, aus Routes gelesen
            property bool earpieceOn: false
            // Wiedergabe endet oft, waehrend das Telefon noch am Ohr ist:
            // die komplette Freigabe (Route, Call-State, Lautstaerke) dann
            // bis zum echten "far" aufschieben - mce weckt das Display beim
            // Absetzen selbst, solange der Anrufzustand aktiv ist
            property bool pendingRelease: false
            property string savedVolume: ""

            DBusInterface {
                id: routeMgr
                bus: DBus.SystemBus
                service: "org.nemomobile.Route.Manager"
                path: "/org/nemomobile/Route/Manager"
                iface: "org.nemomobile.Route.Manager"
            }

            DBusInterface {
                id: mce
                bus: DBus.SystemBus
                service: "com.nokia.mce"
                path: "/com/nokia/mce/request"
                iface: "com.nokia.mce.request"
            }

            // Waehrend der Ohr-Modus aktiv ist, darf das Geraet nicht
            // einschlafen - sonst kaeme das "far"-Ereignis nie an und das
            // Display bliebe schwarz
            KeepAlive {
                enabled: apPage.earpieceOn || apPage.pendingRelease
            }

            // Sicherheitsnetz: kommt kein "far" (Telefon abgelegt), den
            // Pseudo-Anruf nach 25s trotzdem beenden. mce selbst raeumt
            // zusaetzlich auf, wenn unser D-Bus-Client verschwindet
            // (callstate.c: restore to "none" on client exit)
            Timer {
                id: releaseTimer
                interval: 25000
                repeat: false
                onTriggered: apPage.releaseEarpiece()
            }

            // Kein manuelles Display-Wecken mehr: echte Anrufe melden mce
            // einen Anrufzustand und lassen dessen Proximity-Logik arbeiten
            // (tklock.c, UIEXCEPTION_TYPE_CALL: Route=Handset + bedeckt ->
            // blank, nicht bedeckt -> activate). Wir machen es genauso.
            function callState(active) {
                mce.typedCall("req_call_state_change",
                    [{ "type": "s", "value": active ? "active" : "none" },
                     { "type": "s", "value": "normal" }],
                    function() {}, function() {})
            }

            function releaseEarpiece() {
                // Komplette Freigabe: Route zurueck, Lautstaerke zurueck,
                // Pseudo-Anruf beenden (mce aktiviert das Display beim
                // far-Uebergang von selbst, solange der Anruf noch lief)
                releaseTimer.stop()
                pendingRelease = false
                if (savedVolume !== "") {
                    python.call('start_backend.sink_volume_set', [savedVolume])
                    savedVolume = ""
                }
                if (earpieceOn) {
                    earpieceOn = false
                    routeMgr.typedCall("Prefer",
                        [{ "type": "s", "value": "earpiece" },
                         { "type": "u", "value": earpieceType },
                         { "type": "u", "value": 0 }],
                        function() {}, function() {})
                }
                callState(false)
            }

            function setEarpiece(on) {
                if (earpieceType === 0) return
                if (on) {
                    if (earpieceOn) return
                    earpieceOn = true
                    pendingRelease = false
                    releaseTimer.stop()
                    // Pseudo-Anruf: mce uebernimmt Blank (bedeckt) und
                    // Aufwecken (frei) mit seinem eigenen Sensor
                    callState(true)
                    // Ohrhoerer ist leise und die Lautstaerketasten greifen in
                    // dieser Streamklasse nicht - definierte 60% setzen und
                    // die alte Lautstaerke fuers Zurueckschalten merken
                    python.call('start_backend.sink_volume_get', [], function(v) {
                        apPage.savedVolume = v
                        python.call('start_backend.sink_volume_set', ["60%"])
                    })
                    routeMgr.typedCall("Prefer",
                        [{ "type": "s", "value": "earpiece" },
                         { "type": "u", "value": earpieceType },
                         { "type": "u", "value": 1 }],
                        function() {}, function() { apPage.earpieceOn = false })
                } else {
                    if (!earpieceOn && !pendingRelease) return
                    if (proxSensor.reading && proxSensor.reading.near) {
                        // Telefon noch am Ohr (Wiedergabe zu Ende): alles
                        // erst beim "far" freigeben, sonst weckt der
                        // Routenwechsel das Display am Ohr
                        pendingRelease = true
                        releaseTimer.restart()
                    } else {
                        releaseEarpiece()
                    }
                }
            }

            ProximitySensor {
                id: proxSensor
                active: (aplayer.playbackState === MediaPlayer.PlayingState
                         || apPage.earpieceOn || apPage.pendingRelease)
                        && apPage.status === PageStatus.Active
                onReadingChanged: {
                    if (reading.near) {
                        // Kopfhoerer-Wache: nur vom LAUTSPRECHER wegschalten -
                        // niemandem mit Headset das Audio auf den Ohrhoerer reissen
                        routeMgr.typedCall("ActiveRoutes", [], function(outDev) {
                            if (outDev === "speaker") apPage.setEarpiece(true)
                        }, function() {})
                    } else {
                        apPage.releaseEarpiece()
                    }
                }
            }

            function initEarpiece() {
                // earpiece-Typ des Geraets aus der Routenliste holen (die
                // Typ-Bits sind vendor-abhaengig, nicht hartkodierbar)
                routeMgr.typedCall("Routes", [], function(routes) {
                    console.log("Routes reply, entries:", routes ? routes.length : "null")
                    for (var i = 0; i < routes.length; i++) {
                        var name = routes[i][0], t = routes[i][1]
                        if (name === undefined && routes[i].length === undefined) {
                            // manche Nemo.DBus-Versionen liefern Objekte
                            name = routes[i][0] !== undefined ? routes[i][0] : routes[i]["0"]
                        }
                        if (name === "earpiece" && (t & 1)) {
                            apPage.earpieceType = t
                            console.log("earpiece route type:", t)
                            break
                        }
                    }
                    if (apPage.earpieceType === 0)
                        console.log("earpiece route NOT found - raw:", JSON.stringify(routes).substring(0, 300))
                }, function() {
                    console.log("Routes call FAILED")
                })
            }

            Component.onCompleted: {
                // Anzeige = Laufzeit: die Mikrofon-Berechtigung schliesst
                // Audio auf sailjail-Ebene ein, also aktiviert (Audio ODER
                // Microphone) + Sensors den Ohr-Modus - exakt wie die
                // "Ear-speaker switching"-Statuszeile es verspricht
                var xhr = new XMLHttpRequest()
                xhr.open("GET", "http://127.0.0.1:" + backendPort + "/permcheck")
                xhr.onreadystatechange = function() {
                    if (xhr.readyState !== 4) return
                    try {
                        var p = JSON.parse(xhr.responseText)
                        if ((p.audioPermission === true || p.micPermission === true)
                                && p.sensorsPermission === true) apPage.initEarpiece()
                    } catch (e) {}
                }
                xhr.send()
            }

            Component.onDestruction: {
                // Rueckstell-Garantie: nie mit klebendem Ohrhoerer,
                // haengendem Pseudo-Anruf oder verstellter Lautstaerke
                // zuruecklassen (mce raeumt den Call-State zusaetzlich
                // selbst, falls die App abstuerzt)
                releaseEarpiece()
            }

            Column {
                anchors.centerIn: parent
                width: parent.width - 2*Theme.horizontalPageMargin
                spacing: Theme.paddingLarge

                Image {
                    anchors.horizontalCenter: parent.horizontalCenter
                    source: "image://theme/icon-l-music"
                    width: Theme.itemSizeExtraLarge
                    height: width
                }
                Label {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: apPage.title
                    truncationMode: TruncationMode.Fade
                    color: Theme.highlightColor
                }
                IconButton {
                    anchors.horizontalCenter: parent.horizontalCenter
                    icon.source: aplayer.playbackState === MediaPlayer.PlayingState
                                 ? "image://theme/icon-l-pause" : "image://theme/icon-l-play"
                    onClicked: aplayer.playbackState === MediaPlayer.PlayingState
                               ? aplayer.pause() : aplayer.play()
                }
                Slider {
                    width: parent.width
                    minimumValue: 0
                    maximumValue: aplayer.duration > 0 ? aplayer.duration : 1
                    value: aplayer.position
                    enabled: aplayer.seekable
                    onReleased: aplayer.seek(value)
                }
                Label {
                    anchors.horizontalCenter: parent.horizontalCenter
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.secondaryColor
                    function fmt(ms) {
                        var t = Math.floor(ms / 1000)
                        var m = Math.floor(t / 60)
                        var sec = t % 60
                        return m + ":" + (sec < 10 ? "0" : "") + sec
                    }
                    text: fmt(aplayer.position) + " / " + fmt(aplayer.duration)
                }
            }
        }
    }
}