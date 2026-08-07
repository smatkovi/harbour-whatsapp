package main

import (
    "unicode/utf16"
    neturl "net/url"
    "github.com/godbus/dbus/v5"
    "golang.org/x/sys/unix"
    "context"
    "encoding/hex"
    "encoding/base64"
    "encoding/json"
    "errors"
    "fmt"
    "io"
    "math"
    "net"
    "net/http"
    "os"
    "path/filepath"
    "sort"
    "strconv"
    "strings"
    "sync"
    "syscall"
    "time"
    "os/signal"

    "bytes"
    "image"
    _ "image/gif"
    "image/jpeg"
    _ "image/png"

    _ "github.com/mutecomm/go-sqlcipher/v4"
    "go.mau.fi/whatsmeow"
    "go.mau.fi/whatsmeow/appstate"
    "go.mau.fi/whatsmeow/proto/waCommon"
    "go.mau.fi/whatsmeow/proto/waE2E"
    "go.mau.fi/whatsmeow/proto/waMmsRetry"
    "go.mau.fi/whatsmeow/store/sqlstore"
    "go.mau.fi/whatsmeow/types"
    "go.mau.fi/whatsmeow/types/events"
    waLog "go.mau.fi/whatsmeow/util/log"
    "google.golang.org/protobuf/proto"
)

var version = "dev" // per -ldflags "-X main.version=X.Y.Z" gesetzt

var client *whatsmeow.Client
var container *sqlstore.Container
var ctx = context.Background()
var messages []Message
var msgMutex sync.RWMutex
var contacts = make(map[string]string)
var contactsMutex sync.RWMutex
var avatars = make(map[string]string)
var avatarsMutex sync.RWMutex
var pairCode string
var isConnected bool
var connState = "starting"   // starting|connecting|waiting_for_pair|connected|reconnecting|logged_out|error
var lastError string

// Paths - homeDir for media, current dir for data
var homeDir string
var picturesDir string
var videosDir string
var audioDir string
var documentsDir string
var avatarsDir string

// Data files in current working directory
var messagesFile = "messages.enc"
var contactsFile = "contacts.enc"
var rawMediaFile = "rawmedia.enc"
var rawMedia = make(map[string]string) // msgID -> base64(proto waE2E.Message)
var rawMediaMutex sync.RWMutex
var activeCalls = make(map[string]bool) // CallID -> accepted
var activeCallsMutex sync.Mutex
var pendingRetries = make(map[string][]byte) // msgID -> mediaKey
var pendingRetriesMutex sync.Mutex

type ChatSettings struct {
    LastOpened int64 `json:"lastOpened,omitempty"`
    Pinned   bool `json:"pinned,omitempty"`
    Muted    bool `json:"muted,omitempty"`
    Archived bool `json:"archived,omitempty"`
    IsChannel bool `json:"isChannel,omitempty"`
    Ephemeral uint32 `json:"ephemeral,omitempty"`
}

var chatSettings = make(map[string]*ChatSettings) // chatJid -> settings
var chatSettingsMutex sync.RWMutex
var chatSettingsFile = "chatsettings.enc"
var knownChannels = make(map[string]bool) // chatJid(user) -> true
var knownChannelsMutex sync.RWMutex
var knownChannelsFile = "channels.enc"
var prefs = make(map[string]string)
var prefsMutex sync.RWMutex
var prefsFile = "prefs.enc"

func loadPrefs() {
    prefsMutex.Lock()
    defer prefsMutex.Unlock()
    LoadEncrypted(prefsFile, &prefs)
}

func loadKnownChannels() {
    knownChannelsMutex.Lock()
    defer knownChannelsMutex.Unlock()
    LoadEncrypted(knownChannelsFile, &knownChannels)
}

func saveKnownChannels() {
    knownChannelsMutex.RLock()
    defer knownChannelsMutex.RUnlock()
    SaveEncrypted(knownChannelsFile, knownChannels)
}

// ---- Benachrichtigungen (Nemo/Lipstick via org.freedesktop.Notifications) ----
// Stufe 1: aktiv solange die App laeuft (Cover), Stufe 2: mit Daemon auch
// danach. Gesendet wird nur, wenn die GUI nicht aktiv ist: sie meldet ihren
// Zustand via /ui/state; bleiben zusaetzlich die /chats-Polls >10s aus, gilt
// die GUI als weg (Daemon-Fall).
var uiActive bool
var uiLastSeen time.Time
var uiStateMutex sync.Mutex

// Als Daemon gestartet? (systemd-Unit setzt WA_DAEMON=1)
var isDaemon = os.Getenv("WA_DAEMON") == "1"

// Vom HTTP-Server gebundener Port (8085-8089) - u.a. fuer den
// D-Bus-Reply-Handler, der ans eigene /send delegiert
var boundPort int

var notifIDs = map[string]uint32{}   // chatJid -> Notification-ID (Dedupe)
var notifCounts = map[string]int{}   // chatJid -> ungemeldete Nachrichten
var notifMutex sync.Mutex

// ---- Ein-Verbindungs-Wache + Reconnect-Daempfer (Lehre vom 31.07.) ----
// Zwei Instanzen (App-Backend + Daemon) haben sich die WhatsApp-Session im
// Sekundentakt gegenseitig weggerissen; der Server wertete das als Missbrauch
// und meldete das Geraet ab. Ab jetzt gilt: vor JEDEM Connect pruefen, ob
// eine andere lokale Instanz verbunden ist (dann zuruecktreten statt
// konkurrieren), Mindestabstand zwischen Verbindungsaufbauten und
// exponentielles Backoff bei Fehlschlaegen.

var connectMu sync.Mutex
var connectPending bool
var lastConnectAttempt time.Time
var consecReconnects int
var lastConnectedAt time.Time

const minConnectInterval = 10 * time.Second

// Weckkanal: kehrt das Netz zurueck, soll ein laufender Backoff-Schlaf
// nicht bis zu fuenf Minuten ausgesessen werden
var connectWake = make(chan struct{}, 1)

// Letzter von connman gemeldeter Zustand: offline|idle|ready|online.
// "unknown" heisst, wir konnten ihn nicht ermitteln - dann wird der
// periodische Versuch NICHT unterdrueckt, lieber einmal zu viel probieren
var netState = "unknown"

// anotherInstanceConnected: haelt eine ANDERE lokale Instanz die Session?
func anotherInstanceConnected() bool {
    cl := &http.Client{Timeout: 1500 * time.Millisecond}
    for p := 8085; p <= 8089; p++ {
        if p == boundPort {
            continue
        }
        resp, err := cl.Get(fmt.Sprintf("http://127.0.0.1:%d/status", p))
        if err != nil {
            continue
        }
        var st struct {
            Connected bool `json:"connected"`
        }
        json.NewDecoder(resp.Body).Decode(&st)
        resp.Body.Close()
        if st.Connected {
            return true
        }
    }
    return false
}

// Deckel BEIM EXPONENTEN, nicht erst am Ergebnis: 5*(1<<61) laeuft in
// int64 ueber und lieferte 0 - nach etwa fuenf Stunden ohne Netz waere aus
// dem Fuenf-Minuten-Abstand ein Zehn-Sekunden-Takt geworden, also genau der
// Sturm, gegen den die Wache gebaut wurde. 7 ergibt 5*64 = 320 s > Deckel.
const maxBackoffStep = 7

func reconnectDelay() time.Duration {
    if consecReconnects <= 0 {
        return 0
    }
    n := consecReconnects
    if n > maxBackoffStep {
        n = maxBackoffStep
    }
    d := time.Duration(5*(1<<uint(n-1))) * time.Second
    if d > 5*time.Minute {
        d = 5 * time.Minute
    }
    return d
}

// connectWithGuard: einziger erlaubter Weg zu client.Connect()
func connectWithGuard(reason string) {
    connectMu.Lock()
    if connectPending {
        connectMu.Unlock()
        return
    }
    connectPending = true
    connectMu.Unlock()
    go func() {
        defer func() {
            connectMu.Lock()
            connectPending = false
            connectMu.Unlock()
        }()
        if d := reconnectDelay(); d > 0 {
            fmt.Printf("⏳ reconnect backoff %s (attempt %d, %s)\n", d, consecReconnects, reason)
            select {
            case <-time.After(d):
            case <-connectWake:
                fmt.Println("⏭ backoff aborted - network came back")
            }
        }
        if since := time.Since(lastConnectAttempt); since < minConnectInterval && !lastConnectAttempt.IsZero() {
            time.Sleep(minConnectInterval - since)
        }
        for anotherInstanceConnected() {
            connState = "standby"
            lastError = "Another local instance (app or daemon) holds the connection - standing by instead of competing."
            fmt.Println("⏸ standby: another instance is connected, not competing for the session")
            time.Sleep(30 * time.Second)
        }
        if connState == "logged_out" || connState == "relogin_required" {
            fmt.Println("⏸ not reconnecting: state " + connState)
            return
        }
        if client == nil {
            // Kann beim Start passieren (Netzsignal vor der Initialisierung)
            fmt.Println("⏸ not connecting: client not initialised yet")
            return
        }
        lastConnectAttempt = time.Now()
        fmt.Printf("🔌 connecting (%s)\n", reason)
        if cerr := client.Connect(); cerr != nil {
            fmt.Printf("❌ connect error (%s): %v\n", reason, cerr)
            // Ohne whatsmeows Auto-Reconnect (bewusst aus, s.o.) folgt auf
            // einen gescheiterten Verbindungsaufbau KEIN Disconnected- und
            // kein ConnectFailure-Ereignis. Ohne die Nachplanung hier hoerte
            // der Daemon nach einem einzigen Fehlversuch im Funkloch
            // endgueltig auf - still, ohne Benachrichtigungen.
            consecReconnects++
            connState = "reconnecting"
            // Kurz warten, damit connectPending (defer) schon zurueckgesetzt
            // ist - sonst verwuerfe der naechste Aufruf sich selbst
            go func() {
                time.Sleep(500 * time.Millisecond)
                connectWithGuard("retry-after-error")
            }()
        }
    }()
}

// daemonTakeover: laeuft bereits ein (Kind-)Backend, wird es hoeflich per
// /quit beendet, bevor der Daemon den Port uebernimmt - sonst kaempfen zwei
// Backends mit denselben Credentials um die WhatsApp-Session, und der Daemon
// startet mit veralteten Prefs. Die offene GUI findet den Daemon danach
// ueber ihren Port-Rescan von selbst.
func daemonTakeover() {
    if !isDaemon {
        return
    }
    cl := &http.Client{Timeout: 2 * time.Second}
    for p := 8085; p <= 8089; p++ {
        if _, err := cl.Get(fmt.Sprintf("http://127.0.0.1:%d/status", p)); err == nil {
            fmt.Printf("👑 daemon takeover: asking backend on :%d to quit\n", p)
            cl.Get(fmt.Sprintf("http://127.0.0.1:%d/quit", p))
        }
    }
    for i := 0; i < 30; i++ { // bis 3s warten, bis der Port frei ist
        if _, err := cl.Get("http://127.0.0.1:8085/status"); err != nil {
            break
        }
        time.Sleep(100 * time.Millisecond)
    }
}

func daemonWatchdog() {
    if !isDaemon {
        return
    }
    for {
        time.Sleep(30 * time.Second)
        if !storesLoaded {
            continue
        }
        fresh := map[string]string{}
        if err := LoadEncrypted(prefsFile, &fresh); err == nil {
            prefsMutex.Lock()
            prefs = fresh
            prefsMutex.Unlock()
        }
        prefsMutex.RLock()
        notif := prefs["notifications"] == "1"
        prefsMutex.RUnlock()
        if !notif && !guiPresent() {
            fmt.Println("🔔 daemon exiting: notifications disabled and no GUI attached (rule: daemon requires notifications)")
            os.Exit(0)
        }
    }
}

func guiPresent() bool {
    uiStateMutex.Lock()
    defer uiStateMutex.Unlock()
    if time.Since(uiLastSeen) > 10*time.Second {
        return false // keine Polls mehr: App zu (Daemon-Fall)
    }
    return uiActive
}

func notifyIncoming(chatJid, title, preview string) {
    prefsMutex.RLock()
    enabled := prefs["notifications"] == "1"
    prefsMutex.RUnlock()
    if !enabled || guiPresent() || getChatSettings(chatJid).Muted {
        return
    }
    notifMutex.Lock()
    notifCounts[chatJid]++
    count := notifCounts[chatJid]
    replaces := notifIDs[chatJid]
    notifMutex.Unlock()
    body := preview
    if count > 1 {
        body = fmt.Sprintf("%d new messages", count)
    }
    conn, err := dbus.SessionBus()
    if err != nil {
        fmt.Printf("🔔 notification bus error: %v\n", err)
        return
    }
    obj := conn.Object("org.freedesktop.Notifications", "/org/freedesktop/Notifications")
    hints := map[string]dbus.Variant{
        "x-nemo-preview-summary": dbus.MakeVariant(title),
        "x-nemo-preview-body":    dbus.MakeVariant(body),
        "category":               dbus.MakeVariant("x-nemo.messaging.im"),
        // echte Anzahl je Chat-Eintrag - Switcher-Badge-Patches u.ae.
        // summieren item-counts statt Eintraege zu zaehlen
        "x-nemo-item-count":      dbus.MakeVariant(int32(count)),
    }
    // Ton und Vibration getrennt schaltbar: die x-nemo-feedback-Liste
    // benennt ngfd-Ereignisse ("chat" = Ton, "vibra" = Vibration); das
    // tatsaechliche Verhalten folgt zusaetzlich dem Klingelprofil
    prefsMutex.RLock()
    sound := prefs["notif_sound"] != "0"
    vibrate := prefs["notif_vibrate"] != "0"
    // Beschriftung des Antworten-Knopfes: die Oberflaeche legt den
    // uebersetzten Text hier ab, damit der Katalog einzige Quelle bleibt
    replyLabel := prefs["notif_reply_label"]
    prefsMutex.RUnlock()
    if replyLabel == "" {
        replyLabel = "Reply"
    }
    // Das ngfd-Ereignis heisst chat_exists, nicht chat. Beide sind in
    // chat.ini definiert, aber mit ganz verschiedener Wirkung: [chat]
    // bindet im Normalfall nur "haptic" ein - also NUR Vibration - waehrend
    // [chat_exists] ueber "default" den Ton UND
    // mce.led_pattern = PatternCommunicationIM mitbringt. Wir haben jahrelang
    // "chat" gesendet und damit die funktionierende Vorgabe der Kategorie
    // (x-nemo-feedback=chat_exists) durch etwas Wirkungsloses ersetzt: kein
    // Ton, keine LED. Auf dem Geraet nachgemessen.
    var fb []string
    if sound {
        fb = append(fb, "chat_exists")
    }
    if vibrate {
        fb = append(fb, "vibra")
    }
    if !sound {
        // Die LED haengt am selben Ereignis wie der Ton. Wer den Ton
        // abschaltet, wollte Ruhe - nicht auch noch die stille Anzeige
        // verlieren, dass etwas ungelesen ist.
        fb = append(fb, "communication_led")
    }
    hints["x-nemo-feedback"] = dbus.MakeVariant(strings.Join(fb, ","))
    // Antworten direkt aus der Ereignisansicht (wie bei SMS): benannte
    // Remote-Action mit type=input - lipstick zeigt Pfeil+Eingabefeld und
    // ruft unser Reply(chatJid, <text>) am Session-Bus
    replyTarget := "harbour.harbour-whatsapp / harbour.whatsapp.Gui replyFromNotification "
    if isDaemon {
        replyTarget = "harbour.whatsapp.backend / harbour.whatsapp.Backend Reply "
    }
    hints["x-nemo-remote-action-reply"] = dbus.MakeVariant(replyTarget + qvariantStringB64(chatJid))
    hints["x-nemo-remote-action-type-reply"] = dbus.MakeVariant("input")
    // Tippen auf den Eintrag oeffnet die Konversation: default-Aktion an
    // den GUI-Namen - laeuft die App nicht, startet sailjaild sie (ExecDBus)
    hints["x-nemo-remote-action-default"] = dbus.MakeVariant(
        "harbour.harbour-whatsapp / harbour.whatsapp.Gui openChat " + qvariantStringB64(chatJid))
    var id uint32
    call := obj.Call("org.freedesktop.Notifications.Notify", 0,
        "WhatsApp", replaces, "harbour-whatsapp", title, body,
        []string{"default", "", "reply", replyLabel}, hints, int32(-1))
    if call.Err != nil {
        fmt.Printf("🔔 notification failed: %v\n", call.Err)
        return
    }
    call.Store(&id)
    notifMutex.Lock()
    notifIDs[chatJid] = id
    notifMutex.Unlock()
}

// qvariantStringB64 serialisiert einen QString als QDataStream-QVariant
// (Base64), wie nemo-qml-plugin-notifications encodeDBusCall es tut:
// quint32 TypeId(10=QString) + qint8 isNull + quint32 Bytelaenge + UTF-16BE
func qvariantStringB64(s string) string {
    u16 := utf16.Encode([]rune(s))
    buf := make([]byte, 0, 9+2*len(u16))
    buf = append(buf, 0, 0, 0, 10) // QVariant::String
    buf = append(buf, 0)           // not null
    n := 2 * len(u16)
    buf = append(buf, byte(n>>24), byte(n>>16), byte(n>>8), byte(n))
    for _, c := range u16 {
        buf = append(buf, byte(c>>8), byte(c))
    }
    return base64.StdEncoding.EncodeToString(buf)
}

// replyService nimmt die Eingabe-Aktion der Benachrichtigung entgegen
// (lipstick ruft Reply(chatJid, text) - der getippte Text wird von
// lipstick als letztes Argument angehaengt) und delegiert ans eigene
// /send, damit Local-Echo und Ephemeral-Logik identisch bleiben.
type replyService struct{}

func (replyService) Reply(chatJid string, text string) *dbus.Error {
    fmt.Printf("↩️ notification reply to %s\n", chatJid)
    if boundPort != 0 && text != "" {
        url := fmt.Sprintf("http://127.0.0.1:%d/send?to=%s&text=%s",
            boundPort, neturl.QueryEscape(chatJid), neturl.QueryEscape(text))
        if _, err := http.Get(url); err != nil {
            fmt.Printf("↩️ reply send failed: %v\n", err)
        }
    }
    clearNotification(chatJid)
    return nil
}

// startReplyService besetzt den sandbox-erlaubten Busnamen
// (sailjailclient.c: --dbus-user.own=OrganizationName.ApplicationName ->
// harbour.harbour-whatsapp) und exportiert Reply. Retry, weil der Name
// waehrend einer Takeover-Uebergabe noch dem Vorgaenger gehoeren kann.
func startReplyService() {
    // Nur der Daemon besitzt harbour.whatsapp.backend (Grant via
    // Daemon-Desktop-File). Laeuft die App, beantwortet die GUI den
    // Reply ueber ihren eigenen Namen - das Kind-Backend braucht keinen
    if !isDaemon {
        return
    }
    for i := 0; i < 40; i++ {
        conn, err := dbus.SessionBus()
        if err == nil {
            conn.Export(replyService{}, "/", "harbour.whatsapp.Backend")
            reply, rerr := conn.RequestName("harbour.whatsapp.backend", dbus.NameFlagDoNotQueue)
            if rerr == nil && reply == dbus.RequestNameReplyPrimaryOwner {
                fmt.Println("↩️ notification reply service ready (harbour.whatsapp.backend)")
                return
            }
            // Stilles Scheitern hat uns schon einmal in die Irre gefuehrt -
            // Fehlschlaege gehoeren ins Log (haeufigste Ursache: Jail ohne
            // dbus-Erlaubnis, weil das Desktop-File die X-Maemo-Service-
            // Zeile noch nicht hat -> %post-Migration + App-Neustart)
            if i%4 == 0 {
                fmt.Printf("↩️ reply service: cannot own harbour.whatsapp.backend yet (reply=%v err=%v) - desktop file missing X-Maemo-Service? retrying\n", reply, rerr)
            }
        }
        time.Sleep(15 * time.Second)
    }
    fmt.Println("↩️ reply service: giving up - notification replies will be lost")
}

// clearAllNotifications schliesst alle offenen Eintraege in der
// Ereignisansicht - aufgerufen, wenn die App in den Vordergrund kommt
// (wer die App oeffnet, hat die Benachrichtigungen gesehen)
var setupHintSent bool
var versionPollErrLogged bool

// notifySetupHint: einmalige Selbsthilfe-Benachrichtigung des Daemons,
// wenn nur ein App-Start weiterhelfen kann (Schluessel-Uebergabe).
// Benachrichtigen ist das Kerngeschaeft des Daemons - dann darf er auch
// in eigener Sache anklopfen.
func notifySetupHint(body string) {
    if setupHintSent || os.Getenv("WA_DAEMON") != "1" {
        return
    }
    setupHintSent = true
    conn, err := dbus.SessionBus()
    if err != nil {
        return
    }
    obj := conn.Object("org.freedesktop.Notifications", "/org/freedesktop/Notifications")
    hints := map[string]dbus.Variant{
        "x-nemo-preview-summary": dbus.MakeVariant("WhatsApp"),
        "x-nemo-preview-body":    dbus.MakeVariant(body),
        "category":               dbus.MakeVariant("x-nemo.messaging.im"),
    }
    obj.Call("org.freedesktop.Notifications.Notify", 0,
        "WhatsApp", uint32(0), "harbour-whatsapp", "WhatsApp", body,
        []string{}, hints, int32(-1))
}

func clearAllNotifications() {
    notifMutex.Lock()
    ids := make([]uint32, 0, len(notifIDs))
    for _, id := range notifIDs {
        if id != 0 {
            ids = append(ids, id)
        }
    }
    notifIDs = map[string]uint32{}
    notifCounts = map[string]int{}
    notifMutex.Unlock()
    if len(ids) == 0 {
        return
    }
    if conn, err := dbus.SessionBus(); err == nil {
        obj := conn.Object("org.freedesktop.Notifications", "/org/freedesktop/Notifications")
        for _, id := range ids {
            obj.Call("org.freedesktop.Notifications.CloseNotification", 0, id)
        }
    }
}

func clearNotification(chatJid string) {
    notifMutex.Lock()
    id := notifIDs[chatJid]
    delete(notifIDs, chatJid)
    delete(notifCounts, chatJid)
    notifMutex.Unlock()
    if id == 0 {
        return
    }
    if conn, err := dbus.SessionBus(); err == nil {
        conn.Object("org.freedesktop.Notifications", "/org/freedesktop/Notifications").
            Call("org.freedesktop.Notifications.CloseNotification", 0, id)
    }
}

// Gruppeninfo-Cache (Paket-Ebene, damit ihn jeder Handler invalidieren
// kann): Mutationen wie promote/demote/rename MUESSEN invalidieren, sonst
// serviert /group/info nach der Aktion die alte Kopie
type groupInfoCacheEntry struct {
    JSON []byte
    At   time.Time
}

var groupInfoCache = map[string]groupInfoCacheEntry{}
var groupInfoCacheMutex sync.Mutex

// cropScaleSquare schneidet das Bild mittig quadratisch zu und skaliert
// bilinear auf size x size (WhatsApp-Vorgabe fuer Gruppen-/Profilfotos)
func cropScaleSquare(src image.Image, size int) image.Image {
    b := src.Bounds()
    side := b.Dx()
    if b.Dy() < side {
        side = b.Dy()
    }
    x0 := b.Min.X + (b.Dx()-side)/2
    y0 := b.Min.Y + (b.Dy()-side)/2
    dst := image.NewRGBA(image.Rect(0, 0, size, size))
    scale := float64(side) / float64(size)
    for y := 0; y < size; y++ {
        sy := float64(y0) + (float64(y)+0.5)*scale - 0.5
        yi := int(sy)
        fy := sy - float64(yi)
        if yi < y0 {
            yi, fy = y0, 0
        }
        if yi >= y0+side-1 {
            yi, fy = y0+side-2, 1
        }
        for x := 0; x < size; x++ {
            sx := float64(x0) + (float64(x)+0.5)*scale - 0.5
            xi := int(sx)
            fx := sx - float64(xi)
            if xi < x0 {
                xi, fx = x0, 0
            }
            if xi >= x0+side-1 {
                xi, fx = x0+side-2, 1
            }
            r00, g00, b00, _ := src.At(xi, yi).RGBA()
            r10, g10, b10, _ := src.At(xi+1, yi).RGBA()
            r01, g01, b01, _ := src.At(xi, yi+1).RGBA()
            r11, g11, b11, _ := src.At(xi+1, yi+1).RGBA()
            lerp := func(a, b uint32, t float64) float64 { return float64(a) + (float64(b)-float64(a))*t }
            rr := lerp(uint32(lerp(r00, r10, fx)), uint32(lerp(r01, r11, fx)), fy)
            gg := lerp(uint32(lerp(g00, g10, fx)), uint32(lerp(g01, g11, fx)), fy)
            bb := lerp(uint32(lerp(b00, b10, fx)), uint32(lerp(b01, b11, fx)), fy)
            i := dst.PixOffset(x, y)
            dst.Pix[i] = uint8(uint32(rr) >> 8)
            dst.Pix[i+1] = uint8(uint32(gg) >> 8)
            dst.Pix[i+2] = uint8(uint32(bb) >> 8)
            dst.Pix[i+3] = 0xFF
        }
    }
    return dst
}

func invalidateGroupInfo(chat string) {
    groupInfoCacheMutex.Lock()
    delete(groupInfoCache, chat)
    groupInfoCacheMutex.Unlock()
}

func markChannel(jid string) {
    knownChannelsMutex.Lock()
    knownChannels[jid] = true
    knownChannelsMutex.Unlock()
    go saveKnownChannels()
}

// importNewsletterMessages holt Nachrichten eines Kanals und legt sie im
// normalen Nachrichtenspeicher ab (Dedup ueber addMessage).
func importNewsletterMessages(jid types.JID, count int) (int, error) {
    msgs, err := client.GetNewsletterMessages(ctx, jid, &whatsmeow.GetNewsletterMessagesParams{Count: count})
    if err != nil {
        return 0, err
    }
    n := 0
    for _, nm := range msgs {
        if nm.Message == nil {
            continue
        }
        text := nm.Message.GetConversation()
        if text == "" {
            text = nm.Message.GetExtendedTextMessage().GetText()
        }
        mediaType, mimeType, fileName, fileSize, caption, _ := extractMedia(nm.Message)
        if caption != "" {
            text = caption
        }
        var lat, lon float64
        if text == "" && mediaType == "" {
            text, mediaType, lat, lon = specialInfo(nm.Message)
        }
        if text == "" && mediaType == "" {
            continue
        }
        if mediaType != "" {
            stashRawMedia(string(nm.MessageID), nm.Message)
        }
        addMessage(Message{
            ID: string(nm.MessageID), Sender: jid.User, Text: text,
            Timestamp: nm.Timestamp.Unix(), FromMe: false, ChatJID: jid.User,
            MediaType: mediaType, MimeType: mimeType, FileName: fileName,
            FileSize: fileSize, Latitude: lat, Longitude: lon,
        })
        n++
    }
    markChannel(jid.User)
    return n, nil
}

func loadChatSettings() {
    chatSettingsMutex.Lock()
    defer chatSettingsMutex.Unlock()
    LoadEncrypted(chatSettingsFile, &chatSettings)
}

func saveChatSettings() {
    if !storesLoaded {
        return
    }
    chatSettingsMutex.RLock()
    defer chatSettingsMutex.RUnlock()
    SaveEncrypted(chatSettingsFile, chatSettings)
}

func getChatSettings(jid string) *ChatSettings {
    chatSettingsMutex.Lock()
    defer chatSettingsMutex.Unlock()
    cs, ok := chatSettings[jid]
    if !ok {
        cs = &ChatSettings{}
        chatSettings[jid] = cs
    }
    return cs
}
var avatarsFile = "avatars.enc"

var mimeTypes = map[string]string{
    ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png",
    ".gif": "image/gif", ".webp": "image/webp", ".bmp": "image/bmp",
    ".svg": "image/svg+xml", ".ico": "image/x-icon", ".tiff": "image/tiff",
    ".mp4": "video/mp4", ".mkv": "video/x-matroska", ".avi": "video/x-msvideo",
    ".mov": "video/quicktime", ".wmv": "video/x-ms-wmv", ".flv": "video/x-flv",
    ".webm": "video/webm", ".3gp": "video/3gpp", ".m4v": "video/x-m4v",
    ".mp3": "audio/mpeg", ".ogg": "audio/ogg", ".wav": "audio/wav",
    ".flac": "audio/flac", ".aac": "audio/aac", ".m4a": "audio/mp4",
    ".wma": "audio/x-ms-wma", ".opus": "audio/opus",
    ".pdf": "application/pdf",
    ".doc": "application/msword",
    ".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    ".xls": "application/vnd.ms-excel",
    ".xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    ".ppt": "application/vnd.ms-powerpoint",
    ".pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    ".odt": "application/vnd.oasis.opendocument.text",
    ".ods": "application/vnd.oasis.opendocument.spreadsheet",
    ".odp": "application/vnd.oasis.opendocument.presentation",
    ".txt": "text/plain", ".csv": "text/csv", ".json": "application/json",
    ".xml": "application/xml", ".html": "text/html", ".htm": "text/html",
    ".md": "text/markdown", ".rtf": "application/rtf",
    ".zip": "application/zip", ".rar": "application/vnd.rar",
    ".7z": "application/x-7z-compressed", ".tar": "application/x-tar",
    ".gz": "application/gzip", ".bz2": "application/x-bzip2",
    ".apk": "application/vnd.android.package-archive",
    ".exe": "application/x-msdownload",
    ".vcf": "text/vcard", ".ics": "text/calendar",
}

var mimeToExt = map[string]string{
    "image/jpeg": ".jpg", "image/png": ".png", "image/gif": ".gif",
    "image/webp": ".webp", "image/bmp": ".bmp", "image/svg+xml": ".svg",
    "video/mp4": ".mp4", "video/x-matroska": ".mkv", "video/x-msvideo": ".avi",
    "video/quicktime": ".mov", "video/webm": ".webm", "video/3gpp": ".3gp",
    "audio/mpeg": ".mp3", "audio/ogg": ".ogg", "audio/wav": ".wav",
    "audio/flac": ".flac", "audio/aac": ".aac", "audio/mp4": ".m4a",
    "audio/opus": ".opus",
    "application/pdf": ".pdf",
    "application/msword": ".doc",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document": ".docx",
    "application/vnd.ms-excel": ".xls",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": ".xlsx",
    "application/vnd.ms-powerpoint": ".ppt",
    "application/vnd.openxmlformats-officedocument.presentationml.presentation": ".pptx",
    "application/zip": ".zip", "application/vnd.rar": ".rar",
    "application/x-7z-compressed": ".7z",
    "application/vnd.android.package-archive": ".apk",
    "text/plain": ".txt", "text/csv": ".csv", "application/json": ".json",
}

type Message struct {
    ID        string `json:"id"`
    Sender    string `json:"sender"`
    // Konnte der Absender NICHT auf eine Telefonnummer aufgeloest werden,
    // steht in Sender eine LID. Die sieht aus wie eine Rufnummer mit
    // fremder Laendervorwahl und ist keine: weder laesst sich ein Name dazu
    // finden, noch darf man sie als Rufnummer behandeln. Bei Statusmeldungen
    // ist das der Normalfall, weil die Zuordnung oft fehlt.
    SenderIsLid bool `json:"senderIsLid,omitempty"`
    // Kennen wir den Absender wirklich? Nur dann darf eine Antwort
    // angeboten werden. Ueber die Laendervorwahl allein sind 13-stellige
    // LIDs nicht von echten Nummern zu unterscheiden (518 beginnt mit 51 =
    // Peru, 609 mit 60 = Malaysia), deshalb entscheidet hier nicht eine
    // Schaetzung, sondern ob der Absender im Adressbuch bzw. in den
    // WhatsApp-Kontakten steht.
    SenderKnown bool `json:"senderKnown,omitempty"`
    Text      string `json:"text"`
    Timestamp int64  `json:"timestamp"`
    FromMe    bool   `json:"fromMe"`
    ChatJID   string `json:"chatJid"`
    MediaType string `json:"mediaType,omitempty"`
    MimeType  string `json:"mimeType,omitempty"`
    FileName  string `json:"fileName,omitempty"`
    FileSize  uint64 `json:"fileSize,omitempty"`
    LocalPath string `json:"localPath,omitempty"`
    Latitude  float64 `json:"latitude,omitempty"`
    Longitude float64 `json:"longitude,omitempty"`
    QuotedID     string `json:"quotedId,omitempty"`
    QuotedText   string `json:"quotedText,omitempty"`
    QuotedSender string `json:"quotedSender,omitempty"`
    Reactions map[string]string `json:"reactions,omitempty"` // Nummer -> Emoji
    Edited  bool `json:"edited,omitempty"`
    Revoked bool `json:"revoked,omitempty"`
    PollName     string              `json:"pollName,omitempty"`
    PollOptions  []string            `json:"pollOptions,omitempty"`
    PollMultiple bool                `json:"pollMultiple,omitempty"`
    PollVoters   map[string][]string `json:"pollVoters,omitempty"` // Nummer -> gewaehlte Optionen
    Mentions     []string `json:"mentions,omitempty"`     // erwaehnte Nummern
    Forwarded    bool     `json:"forwarded,omitempty"`
    Live         bool     `json:"live,omitempty"`         // Live-Standort
    Ephemeral    uint32   `json:"ephemeral,omitempty"`    // Ablauf in Sekunden
    PinnedInChat bool     `json:"pinnedInChat,omitempty"`
    InviteGroupJID  string `json:"inviteGroupJid,omitempty"` // Gruppen-Einladung
    InviteGroupName string `json:"inviteGroupName,omitempty"`
    InviteCode      string `json:"inviteCode,omitempty"`
    InviteExpiration int64 `json:"inviteExpiration,omitempty"`
    InviteFrom      string `json:"inviteFrom,omitempty"` // Einlader (Nummer)
}

type Chat struct {
    JID         string `json:"jid"`
    Pinned   bool `json:"pinned,omitempty"`
    Muted    bool `json:"muted,omitempty"`
    Archived bool `json:"archived,omitempty"`
    Ephemeral uint32 `json:"ephemeral,omitempty"` // Ablauf-Timer in Sekunden
    IsChannel bool `json:"isChannel,omitempty"`
    Name        string `json:"name"`
    LastMessage string `json:"lastMessage"`
    LastTime    int64  `json:"lastTime"`
    FromMe      bool   `json:"fromMe"`
    IsGroup     bool   `json:"isGroup"`
    Avatar      string `json:"avatar,omitempty"`
    Unread      int    `json:"unread,omitempty"`
}

func writeFileAtomic(filename string, data []byte) error {
    return os.WriteFile(filename, data, 0600)
}

func readFileBytes(filename string) ([]byte, error) {
    return os.ReadFile(filename)
}

func initPaths() {
    homeDir = os.Getenv("HOME")
    if homeDir == "" {
        homeDir = "/home/defaultuser"
    }
    // cwd-Wache: der Datenordner leitet sich aus dem Arbeitsverzeichnis ab.
    // Wer das Backend von Hand startet (oder wessen cwd die Sandbox nach
    // $HOME mappt), wuerde sonst eine FRISCHE wa.db in $HOME anlegen und
    // "need to pair" sehen, obwohl die echte Datenbank existiert - passiert
    // beim manuellen sailjail-Test. In dem Fall in den kanonischen
    // App-Datenordner wechseln.
    if wd, err := os.Getwd(); err == nil && (wd == homeDir || wd == "/") {
        canonical := filepath.Join(homeDir, ".local", "share", "harbour", "harbour-whatsapp")
        os.MkdirAll(canonical, 0700)
        if err := os.Chdir(canonical); err == nil {
            fmt.Printf("📁 cwd was %s - switched to data dir %s\n", wd, canonical)
        }
    }
    
    picturesDir = filepath.Join(homeDir, "Pictures", "WhatsApp")
    videosDir = filepath.Join(homeDir, "Videos", "WhatsApp")
    audioDir = filepath.Join(homeDir, "Music", "WhatsApp")
    documentsDir = filepath.Join(homeDir, "Documents", "WhatsApp")
    avatarsDir = filepath.Join(homeDir, "Pictures", "WhatsApp", "avatars")

    // Ohne UserDirs-Permission sind ~/Pictures etc. in der Sandbox
    // unsichtbar - dann in den privaten Datenordner ausweichen
    if !dirWritable(picturesDir) {
        cwd, _ := os.Getwd()
        base := filepath.Join(cwd, "media")
        picturesDir = filepath.Join(base, "Pictures")
        videosDir = filepath.Join(base, "Videos")
        audioDir = filepath.Join(base, "Music")
        documentsDir = filepath.Join(base, "Documents")
        avatarsDir = filepath.Join(base, "Pictures", "avatars")
        fmt.Println("📁 No UserDirs permission - storing media in app data dir:", base)
    }

    os.MkdirAll(picturesDir, 0755)
    os.MkdirAll(videosDir, 0755)
    os.MkdirAll(audioDir, 0755)
    os.MkdirAll(documentsDir, 0755)
    os.MkdirAll(avatarsDir, 0755)
}

func getDBConnectionString() string {
    if encryptionKey == nil || len(encryptionKey) == 0 {
        return "file:wa.db?_foreign_keys=on"
    }
    keyHex := hex.EncodeToString(encryptionKey)
    return fmt.Sprintf("file:wa.db?_foreign_keys=on&_pragma_key=x'%s'&_pragma_cipher_page_size=4096", keyHex)
}

func initDatabase() error {
    dbLog := waLog.Stdout("DB", "ERROR", true)
    var err error
    container, err = sqlstore.New(ctx, "sqlite3", getDBConnectionString(), dbLog)
    if err != nil {
        return fmt.Errorf("database error: %v", err)
    }
    return nil
}

func initClient() error {
    device, err := container.GetFirstDevice(ctx)
    if err != nil {
        return err
    }
    clientLog := waLog.Stdout("Client", "WARN", true)
    client = whatsmeow.NewClient(device, clientLog)
    // Reconnects laufen ueber unsere Ein-Verbindungs-Wache mit Backoff -
    // whatsmeows Sofort-Reconnect hat beim Zwei-Instanzen-Gerangel den
    // Session-Sturm befeuert, der in einer Server-Abmeldung endete
    client.EnableAutoReconnect = false
    client.AddEventHandler(eventHandler)
    return nil
}

func loadMessages() {
    msgMutex.Lock()
    defer msgMutex.Unlock()
    
    if err := LoadEncrypted(messagesFile, &messages); err != nil {
        data, err := os.ReadFile("messages.json")
        if err == nil {
            json.Unmarshal(data, &messages)
            fmt.Printf("📂 Migrated %d messages from unencrypted file\n", len(messages))
            os.Remove("messages.json")
            return
        }
        return
    }
    fmt.Printf("📂 Loaded %d messages (encrypted)\n", len(messages))
}

func loadRawMedia() {
    rawMediaMutex.Lock()
    defer rawMediaMutex.Unlock()
    if err := LoadEncrypted(rawMediaFile, &rawMedia); err == nil {
        fmt.Printf("📂 Loaded %d pending media keys\n", len(rawMedia))
    }
}

func saveRawMedia() {
    if !storesLoaded {
        return
    }
    rawMediaMutex.RLock()
    defer rawMediaMutex.RUnlock()
    if err := SaveEncrypted(rawMediaFile, rawMedia); err != nil {
        fmt.Printf("⚠️ Failed to save media keys: %v\n", err)
    }
}

func stashRawMedia(msgID string, msg *waE2E.Message) {
    data, err := proto.Marshal(msg)
    if err != nil {
        return
    }
    rawMediaMutex.Lock()
    rawMedia[msgID] = base64.StdEncoding.EncodeToString(data)
    rawMediaMutex.Unlock()
    go saveRawMedia()
}

// extractMedia liefert Typ, Mime, Dateiname, Groesse, Caption und den
// downloadbaren Teil einer Nachricht - fuer Live- und History-Pfad.
func extractMedia(msg *waE2E.Message) (mediaType, mimeType, fileName string, fileSize uint64, caption string, dl whatsmeow.DownloadableMessage) {
    switch {
    case msg.GetImageMessage() != nil:
        m := msg.GetImageMessage()
        return "image", m.GetMimetype(), "", m.GetFileLength(), m.GetCaption(), m
    case msg.GetVideoMessage() != nil:
        m := msg.GetVideoMessage()
        return "video", m.GetMimetype(), "", m.GetFileLength(), m.GetCaption(), m
    case msg.GetAudioMessage() != nil:
        m := msg.GetAudioMessage()
        return "audio", m.GetMimetype(), "", m.GetFileLength(), "", m
    case msg.GetDocumentMessage() != nil:
        m := msg.GetDocumentMessage()
        return "document", m.GetMimetype(), m.GetFileName(), m.GetFileLength(), m.GetCaption(), m
    case msg.GetStickerMessage() != nil:
        m := msg.GetStickerMessage()
        return "sticker", m.GetMimetype(), "", m.GetFileLength(), "", m
    }
    return "", "", "", 0, "", nil
}

// storesLoaded verhindert, dass ein Backend, das vor dem Laden der Stores
// anhaelt (Secrets-Halt, Fehlerpfad), beim Beenden leeren Zustand ueber
// volle Dateien schreibt - genau das hat messages.enc geleert.
var storesLoaded bool

func saveMessages() {
    if !storesLoaded {
        fmt.Println("💾 skip saveMessages: stores were never loaded")
        return
    }
    msgMutex.RLock()
    defer msgMutex.RUnlock()
    
    if err := SaveEncrypted(messagesFile, messages); err != nil {
        fmt.Printf("⚠️ Failed to save messages: %v\n", err)
    }
}

func loadContactsFromDisk() {
    contactsMutex.Lock()
    defer contactsMutex.Unlock()
    
    if err := LoadEncrypted(contactsFile, &contacts); err != nil {
        data, err := os.ReadFile("contacts.json")
        if err == nil {
            json.Unmarshal(data, &contacts)
            fmt.Printf("📂 Migrated %d contacts from unencrypted file\n", len(contacts))
            os.Remove("contacts.json")
            return
        }
        return
    }
    fmt.Printf("📂 Loaded %d contacts (encrypted)\n", len(contacts))
}

func saveContacts() {
    if !storesLoaded {
        return
    }
    contactsMutex.RLock()
    defer contactsMutex.RUnlock()
    
    if err := SaveEncrypted(contactsFile, contacts); err != nil {
        fmt.Printf("⚠️ Failed to save contacts: %v\n", err)
    }
}

func loadAvatarsFromDisk() {
    avatarsMutex.Lock()
    defer avatarsMutex.Unlock()
    
    if err := LoadEncrypted(avatarsFile, &avatars); err != nil {
        data, err := os.ReadFile("avatars.json")
        if err == nil {
            json.Unmarshal(data, &avatars)
            fmt.Printf("📂 Migrated %d avatars from unencrypted file\n", len(avatars))
            os.Remove("avatars.json")
            return
        }
        return
    }
    fmt.Printf("📂 Loaded %d avatars (encrypted)\n", len(avatars))
}

func saveAvatars() {
    if !storesLoaded {
        return
    }
    avatarsMutex.RLock()
    defer avatarsMutex.RUnlock()
    
    if err := SaveEncrypted(avatarsFile, avatars); err != nil {
        fmt.Printf("⚠️ Failed to save avatars: %v\n", err)
    }
}

func getMimeType(filename string) string {
    ext := strings.ToLower(filepath.Ext(filename))
    if mime, ok := mimeTypes[ext]; ok {
        return mime
    }
    return "application/octet-stream"
}

func getExtFromMime(mimeType string) string {
    if ext, ok := mimeToExt[mimeType]; ok {
        return ext
    }
    return ".bin"
}

func getMediaDir(mimeType string) string {
    switch {
    case strings.HasPrefix(mimeType, "image/"):
        return picturesDir
    case strings.HasPrefix(mimeType, "video/"):
        return videosDir
    case strings.HasPrefix(mimeType, "audio/"):
        return audioDir
    default:
        return documentsDir
    }
}

func downloadAvatar(jid string) string {
    avatarsMutex.RLock()
    path, ok := avatars[jid]
    avatarsMutex.RUnlock()
    if ok {
        if _, err := os.Stat(path); err == nil {
            return path // Cache-Treffer: unabhaengig von der Download-Policy
        }
    }

    // Nur der eigentliche Netz-Download unterliegt der Policy
    if !shouldAutoDownload("avatar") {
        return ""
    }

    if client == nil || !client.IsConnected() {
        return ""
    }

    var fullJid types.JID
    if len(jid) > 15 {
        fullJid = types.NewJID(jid, "g.us")
    } else {
        fullJid = types.NewJID(jid, "s.whatsapp.net")
    }

    pic, err := client.GetProfilePictureInfo(ctx, fullJid, &whatsmeow.GetProfilePictureParams{})
    if err != nil || pic == nil {
        return ""
    }

    resp, err := http.Get(pic.URL)
    if err != nil {
        return ""
    }
    defer resp.Body.Close()

    data, err := io.ReadAll(resp.Body)
    if err != nil {
        return ""
    }

    path = filepath.Join(avatarsDir, jid+".jpg")
    err = os.WriteFile(path, data, 0644)
    if err != nil {
        return ""
    }

    avatarsMutex.Lock()
    avatars[jid] = path
    avatarsMutex.Unlock()
    go saveAvatars()

    fmt.Printf("🖼️ Downloaded avatar for %s\n", jid)
    return path
}

func loadContacts() {
    if client.Store.ID == nil {
        return
    }
    contactsMutex.Lock()
    allContacts, _ := client.Store.Contacts.GetAllContacts(ctx)
    for jid, info := range allContacts {
        name := info.PushName
        if info.FullName != "" {
            name = info.FullName
        }
        if name != "" {
            contacts[jid.User] = name
        }
    }
    contactsMutex.Unlock()
    
    groups, _ := client.GetJoinedGroups(ctx)
    contactsMutex.Lock()
    for _, group := range groups {
        contacts[group.JID.User] = group.Name
    }
    contactsMutex.Unlock()
    
    fmt.Printf("📇 Loaded %d contacts/groups\n", len(contacts))
    go saveContacts()

    go func() {
        contactsMutex.RLock()
        jids := make([]string, 0, len(contacts))
        for jid := range contacts {
            jids = append(jids, jid)
        }
        contactsMutex.RUnlock()

        for _, jid := range jids {
            avatarsMutex.RLock()
            _, hasAvatar := avatars[jid]
            avatarsMutex.RUnlock()
            if !hasAvatar {
                downloadAvatar(jid)
                time.Sleep(100 * time.Millisecond)
            }
        }
    }()
}

func getContactName(jid string) string {
    if jid == "status" {
        return "Status updates"
    }
    contactsMutex.RLock()
    defer contactsMutex.RUnlock()
    if name, ok := contacts[jid]; ok {
        return name
    }
    return ""
}

func getAvatar(jid string) string {
    avatarsMutex.RLock()
    path, ok := avatars[jid]
    avatarsMutex.RUnlock()
    if ok {
        if _, err := os.Stat(path); err == nil {
            return path
        }
    }
    return ""
}

func downloadMedia(msgID string, msg whatsmeow.DownloadableMessage, mimeType string, origFileName string) (string, error) {
    // Ohne Deadline kann ein CDN-Stillstand den Aufruf endlos blockieren -
    // und damit ueber die QML-Wache jeden weiteren Download-Tap
    dctx, cancel := context.WithTimeout(ctx, 90*time.Second)
    defer cancel()
    data, err := client.Download(dctx, msg)
    if errors.Is(err, whatsmeow.ErrInvalidMediaHMAC) || errors.Is(err, whatsmeow.ErrInvalidMediaEncSHA256) {
        // Kanal-Medien: der Server re-hostet Newsletter-Uploads
        // UNVERSCHLUESSELT (mms-type "newsletter-*"), waehrend das Proto
        // noch den mediaKey des Autors traegt - die normale Entschluesselung
        // scheitert dann an der HMAC-Pruefung. Zweiter Versuch als
        // Plaintext-Download ueber den direct path.
        mt := whatsmeow.GetMediaType(msg)
        mms := map[whatsmeow.MediaType]string{
            whatsmeow.MediaImage: "image", whatsmeow.MediaAudio: "audio",
            whatsmeow.MediaVideo: "video", whatsmeow.MediaDocument: "document",
        }[mt]
        fmt.Printf("⬇️ %s: hmac mismatch - retrying as unencrypted newsletter media (%s)\n", msgID, mms)
        data, err = client.DownloadMediaWithPath(dctx, msg.GetDirectPath(), nil, msg.GetFileSHA256(), nil, mt, "newsletter-"+mms, true)
    }
    if err != nil {
        return "", err
    }
    ext := getExtFromMime(mimeType)
    var filename string
    if origFileName != "" {
        filename = fmt.Sprintf("%s_%s", msgID, origFileName)
    } else {
        filename = fmt.Sprintf("%s_%d%s", msgID, time.Now().Unix(), ext)
    }
    dir := getMediaDir(mimeType)
    path := filepath.Join(dir, filename)
    err = os.WriteFile(path, data, 0644)
    if err != nil {
        return "", err
    }
    fmt.Printf("📥 Downloaded: %s (%d bytes)\n", path, len(data))
    return path, nil
}

// Long-Polling: monotone Ereignisnummer + Broadcast-Kanal. /events haengt,
// bis sich evSeq bewegt - die Oberflaeche pollt nicht mehr blind alle 2 s,
// sondern bekommt Aenderungen sofort und schlaeft bei Stille.
var (
    evMu  sync.Mutex
    evSeq int64 = 1
    evCh        = make(chan struct{})
)

func bumpEvent() {
    evMu.Lock()
    evSeq++
    close(evCh)
    evCh = make(chan struct{})
    evMu.Unlock()
}

func addMessage(m Message) {
    msgMutex.Lock()
    for _, existing := range messages {
        if existing.ID == m.ID {
            msgMutex.Unlock()
            return
        }
    }
    messages = append(messages, m)
    msgMutex.Unlock()
    go saveMessages()
    bumpEvent()
}

// setMessagePinned markiert eine Nachricht als (nicht mehr) angepinnt.
func setMessagePinned(chatJid, msgID string, pinned bool) {
    msgMutex.Lock()
    for i := range messages {
        if messages[i].ID == msgID && (chatJid == "" || messages[i].ChatJID == chatJid) {
            messages[i].PinnedInChat = pinned
            break
        }
    }
    msgMutex.Unlock()
    bumpEvent()
    go saveMessages()
}

// updateLiveLocation aktualisiert den letzten Live-Standort desselben
// Absenders im Chat in place. Liefert false, wenn keiner existiert (dann
// wird die Nachricht normal als neuer Eintrag angelegt).
// haversineMeters: Distanz zweier Koordinaten in Metern
func haversineMeters(lat1, lon1, lat2, lon2 float64) float64 {
    const R = 6371000.0
    p1 := lat1 * math.Pi / 180
    p2 := lat2 * math.Pi / 180
    dp := (lat2 - lat1) * math.Pi / 180
    dl := (lon2 - lon1) * math.Pi / 180
    a := math.Sin(dp/2)*math.Sin(dp/2) + math.Cos(p1)*math.Cos(p2)*math.Sin(dl/2)*math.Sin(dl/2)
    return R * 2 * math.Atan2(math.Sqrt(a), math.Sqrt(1-a))
}

func updateLiveLocation(chatJid, sender string, lat, lon float64, ts int64) bool {
    if lat == 0 && lon == 0 {
        // Beim Beenden schickt WhatsApp oft ein letztes Paket ohne echte
        // Koordinaten - das darf die letzte bekannte Position nicht mit
        // 0/0 ueberschreiben (geo:0,0 scheitert dann stumm in Karten-Apps)
        return true // konsumieren, Blase friert beim letzten Stand ein
    }
    msgMutex.Lock()
    defer msgMutex.Unlock()
    for i := len(messages) - 1; i >= 0; i-- {
        m := &messages[i]
        if m.ChatJID == chatJid && m.Sender == sender && m.Live {
            m.Latitude, m.Longitude = lat, lon
            m.Timestamp = ts
            m.Text = "📍 Live location"
            go saveMessages()
            return true
        }
    }
    return false
}

// setChatEphemeral merkt sich den Ablauf-Timer eines Chats.
func setChatEphemeral(chatJid string, secs uint32) {
    chatSettingsMutex.Lock()
    cs := chatSettings[chatJid]
    if cs == nil {
        cs = &ChatSettings{}
        chatSettings[chatJid] = cs
    }
    cs.Ephemeral = secs
    chatSettingsMutex.Unlock()
    go saveChatSettings()
}

func getChatEphemeral(chatJid string) uint32 {
    chatSettingsMutex.RLock()
    defer chatSettingsMutex.RUnlock()
    if cs := chatSettings[chatJid]; cs != nil {
        return cs.Ephemeral
    }
    return 0
}

func ephemeralLabel(secs uint32) string {
    switch {
    case secs >= 7776000:
        return "90 days"
    case secs >= 604800:
        return "7 days"
    case secs >= 86400:
        return "24 hours"
    default:
        return fmt.Sprintf("%d s", secs)
    }
}

// cleanupEphemeral loescht lokal abgelaufene Nachrichten (Naeherung der
// WhatsApp-Semantik; laeuft periodisch).
func cleanupEphemeral() {
    now := time.Now().Unix()
    removedFiles := []string{}
    msgMutex.Lock()
    kept := messages[:0]
    for _, m := range messages {
        if m.Ephemeral > 0 && now > m.Timestamp+int64(m.Ephemeral) {
            if m.LocalPath != "" {
                removedFiles = append(removedFiles, m.LocalPath)
            }
            continue
        }
        kept = append(kept, m)
    }
    changed := len(kept) != len(messages)
    messages = kept
    msgMutex.Unlock()
    bumpEvent()
    for _, f := range removedFiles {
        os.Remove(f)
    }
    if changed {
        go saveMessages()
    }
}

// resolvePN maps a @lid JID to the corresponding phone-number JID if known,
// so chats are always keyed by phone number and never split into duplicates.
func resolvePN(jid types.JID, alt types.JID) types.JID {
    jid = jid.ToNonAD()
    if jid.Server != types.HiddenUserServer {
        return jid
    }
    if !alt.IsEmpty() && alt.Server == types.DefaultUserServer {
        return alt.ToNonAD()
    }
    if client != nil {
        if pn, err := client.Store.LIDs.GetPNForLID(context.Background(), jid); err == nil && !pn.IsEmpty() {
            return pn.ToNonAD()
        }
    }
    return jid
}

// getContextInfo liefert die ContextInfo (Zitate) des relevanten Teils.
type pollLike interface {
    GetName() string
    GetOptions() []*waE2E.PollCreationMessage_Option
    GetSelectableOptionsCount() uint32
}

func extractPoll(msg *waE2E.Message) (name string, options []string, multiple bool, ok bool) {
    var p pollLike
    switch {
    case msg.GetPollCreationMessageV3() != nil:
        p = msg.GetPollCreationMessageV3()
    case msg.GetPollCreationMessageV2() != nil:
        p = msg.GetPollCreationMessageV2()
    case msg.GetPollCreationMessage() != nil:
        p = msg.GetPollCreationMessage()
    default:
        return "", nil, false, false
    }
    for _, o := range p.GetOptions() {
        options = append(options, o.GetOptionName())
    }
    return p.GetName(), options, p.GetSelectableOptionsCount() != 1, true
}

// matchPollOptions uebersetzt Options-Hashes einer Stimme zurueck in Namen.
func matchPollOptions(hashes [][]byte, options []string) []string {
    known := whatsmeow.HashPollOptions(options)
    var out []string
    for _, h := range hashes {
        for i, k := range known {
            if bytes.Equal(h, k) {
                out = append(out, options[i])
            }
        }
    }
    return out
}

type mediaKeyed interface {
    GetMediaKey() []byte
}

// requestMediaRetry bittet das Telefon, ein abgelaufenes Medium neu
// hochzuladen. Die Antwort kommt asynchron als events.MediaRetry.
func requestMediaRetry(m *Message, dl whatsmeow.DownloadableMessage) error {
    mk, ok := dl.(mediaKeyed)
    if !ok || len(mk.GetMediaKey()) == 0 {
        return fmt.Errorf("no media key available")
    }
    chatJID := toChatJID(m.ChatJID)
    senderJID := types.NewJID(m.Sender, types.DefaultUserServer)
    info := &types.MessageInfo{
        ID: types.MessageID(m.ID),
        MessageSource: types.MessageSource{
            Chat:     chatJID,
            Sender:   senderJID,
            IsFromMe: m.FromMe,
        },
    }
    if err := client.SendMediaRetryReceipt(ctx, info, mk.GetMediaKey()); err != nil {
        return err
    }
    pendingRetriesMutex.Lock()
    pendingRetries[m.ID] = mk.GetMediaKey()
    pendingRetriesMutex.Unlock()
    return nil
}

// specialInfo bildet Standort/Kontakt/Umfrage/Einladung als Text ab.
func specialInfo(msg *waE2E.Message) (text, mediaType string, lat, lon float64) {
    if loc := msg.GetLocationMessage(); loc != nil {
        lat, lon = loc.GetDegreesLatitude(), loc.GetDegreesLongitude()
        text = strings.TrimSpace(loc.GetName() + " " + loc.GetAddress())
        if text == "" {
            text = fmt.Sprintf("%.5f, %.5f", lat, lon)
        }
        return "📍 " + text, "location", lat, lon
    }
    if loc := msg.GetLiveLocationMessage(); loc != nil {
        return "📍 Live location", "location", loc.GetDegreesLatitude(), loc.GetDegreesLongitude()
    }
    if cm := msg.GetContactMessage(); cm != nil {
        return "👤 " + cm.GetDisplayName(), "", 0, 0
    }
    if ca := msg.GetContactsArrayMessage(); ca != nil {
        names := []string{}
        for _, c := range ca.GetContacts() {
            names = append(names, c.GetDisplayName())
        }
        return "👤 " + strings.Join(names, ", "), "", 0, 0
    }
    if p := msg.GetPollCreationMessageV3(); p != nil {
        return pollText(p), "", 0, 0
    }
    if p := msg.GetPollCreationMessageV2(); p != nil {
        return pollText(p), "", 0, 0
    }
    if p := msg.GetPollCreationMessage(); p != nil {
        return pollText(p), "", 0, 0
    }
    if gi := msg.GetGroupInviteMessage(); gi != nil {
        return "👥 Group invite: " + gi.GetGroupName(), "", 0, 0
    }
    return "", "", 0, 0
}

// validateStoredPaths entfernt Verweise auf Dateien, die (z.B. nach dem
// Entzug der UserDirs-Permission) in der Sandbox nicht mehr sichtbar sind.
func validateStoredPaths() {
    removedAv := 0
    avatarsMutex.Lock()
    for jid, p := range avatars {
        if _, err := os.Stat(p); err != nil {
            delete(avatars, jid)
            removedAv++
        }
    }
    avatarsMutex.Unlock()
    if removedAv > 0 {
        go saveAvatars()
    }

    cleared := 0
    msgMutex.Lock()
    for i := range messages {
        if messages[i].LocalPath == "" {
            continue
        }
        if _, err := os.Stat(messages[i].LocalPath); err != nil {
            messages[i].LocalPath = ""
            cleared++
        }
    }
    msgMutex.Unlock()
    if cleared > 0 {
        go saveMessages()
    }
    if removedAv > 0 || cleared > 0 {
        fmt.Printf("🧹 Path validation: %d avatars re-queued, %d media paths cleared (files not accessible in sandbox)\n", removedAv, cleared)
    }
}

// onWifi ermittelt ueber die Default-Route, ob WLAN aktiv ist.
// wlan*/wlp* -> WiFi; rmnet*/ccmni*/wwan*/rndis* -> Mobilfunk.
func onWifi() bool {
    data, err := os.ReadFile("/proc/net/route")
    if err != nil {
        return true // im Zweifel nicht blockieren
    }
    for _, line := range strings.Split(string(data), "\n")[1:] {
        f := strings.Fields(line)
        if len(f) >= 2 && f[1] == "00000000" { // Default-Route
            iface := f[0]
            return strings.HasPrefix(iface, "wlan") || strings.HasPrefix(iface, "wlp")
        }
    }
    return true
}

// shouldAutoDownload prueft die Nutzer-Policy fuer einen Medientyp.
// Werte: "always" | "wifi" | "never"; Downloads per Antippen sind
// davon unabhaengig immer erlaubt.
func shouldAutoDownload(kind string) bool {
    prefsMutex.RLock()
    policy := prefs["autodl_"+kind]
    prefsMutex.RUnlock()
    if policy == "" {
        // Defaults: kleine Typen immer, grosse nur im WLAN
        switch kind {
        case "image", "sticker", "avatar":
            policy = "always"
        default:
            policy = "wifi"
        }
    }
    switch policy {
    case "never":
        return false
    case "wifi":
        return onWifi()
    default:
        return true
    }
}

// haltWithState laesst den HTTP-Server (nur /status, /reset, /quit) weiter
// antworten, initialisiert aber nichts mehr - die UI zeigt die Erklaerung.
func haltWithState(state, explanation string) {
    connState = state
    lastError = explanation
    fmt.Println("🛑 " + state + ": " + explanation)
    c := make(chan os.Signal, 1)
    signal.Notify(c, os.Interrupt, syscall.SIGTERM)
    <-c
    os.Exit(0)
}

func dirWritable(dir string) bool {
    if err := os.MkdirAll(dir, 0755); err != nil {
        return false
    }
    probe := filepath.Join(dir, ".probe")
    if err := os.WriteFile(probe, []byte("x"), 0644); err != nil {
        return false
    }
    os.Remove(probe)
    return true
}

func toChatJID(to string) types.JID {
    if len(to) > 15 {
        return types.NewJID(to, types.GroupServer)
    }
    return types.NewJID(to, types.DefaultUserServer)
}

func pollText(p pollLike) string {
    t := "📊 Poll: " + p.GetName()
    for _, o := range p.GetOptions() {
        t += "\n• " + o.GetOptionName()
    }
    return t
}

func getContextInfo(msg *waE2E.Message) *waE2E.ContextInfo {
    switch {
    case msg.GetExtendedTextMessage() != nil:
        return msg.GetExtendedTextMessage().GetContextInfo()
    case msg.GetImageMessage() != nil:
        return msg.GetImageMessage().GetContextInfo()
    case msg.GetVideoMessage() != nil:
        return msg.GetVideoMessage().GetContextInfo()
    case msg.GetAudioMessage() != nil:
        return msg.GetAudioMessage().GetContextInfo()
    case msg.GetDocumentMessage() != nil:
        return msg.GetDocumentMessage().GetContextInfo()
    case msg.GetStickerMessage() != nil:
        return msg.GetStickerMessage().GetContextInfo()
    case msg.GetLocationMessage() != nil:
        return msg.GetLocationMessage().GetContextInfo()
    }
    return nil
}

// quotedSnippet extrahiert eine kurze Vorschau der zitierten Nachricht.
func quotedSnippet(q *waE2E.Message) string {
    if q == nil {
        return ""
    }
    t := q.GetConversation()
    if t == "" {
        t = q.GetExtendedTextMessage().GetText()
    }
    if t == "" {
        switch {
        case q.GetImageMessage() != nil:
            t = "🖼 " + q.GetImageMessage().GetCaption()
        case q.GetVideoMessage() != nil:
            t = "🎬 " + q.GetVideoMessage().GetCaption()
        case q.GetAudioMessage() != nil:
            t = "🎵 Audio"
        case q.GetDocumentMessage() != nil:
            t = "📄 " + q.GetDocumentMessage().GetFileName()
        case q.GetStickerMessage() != nil:
            t = "Sticker"
        case q.GetLocationMessage() != nil:
            t = "📍 Location"
        }
    }
    if len(t) > 120 {
        t = t[:120] + "…"
    }
    return strings.TrimSpace(t)
}

// updateMessage sucht eine Nachricht per Chat+ID und wendet fn an.
func updateMessage(chatJid, msgID string, fn func(*Message)) bool {
    msgMutex.Lock()
    defer msgMutex.Unlock()
    for i := range messages {
        if messages[i].ID == msgID && (chatJid == "" || messages[i].ChatJID == chatJid) {
            fn(&messages[i])
            go saveMessages()
            bumpEvent()
            return true
        }
    }
    return false
}

func eventHandler(evt interface{}) {
    switch v := evt.(type) {
    case *events.Message:
        var text string
        var mediaType, mimeType, fileName, localPath string
        var fileSize uint64
        
        msg := v.Message
        
        if msg.Conversation != nil {
            text = *msg.Conversation
        } else if msg.ExtendedTextMessage != nil {
            text = msg.ExtendedTextMessage.GetText()
        }

        var latitude, longitude float64

        // Reaktionen: Zielnachricht aktualisieren, keine neue Nachricht
        if re := msg.GetReactionMessage(); re != nil {
            targetID := re.GetKey().GetID()
            emoji := re.GetText() // leer = Reaktion entfernt
            reactor := resolvePN(v.Info.Sender, v.Info.SenderAlt).User
            updateMessage("", targetID, func(m *Message) {
                if m.Reactions == nil {
                    m.Reactions = make(map[string]string)
                }
                if emoji == "" {
                    delete(m.Reactions, reactor)
                } else {
                    m.Reactions[reactor] = emoji
                }
            })
            return
        }

        // Protokoll: Loeschen ("fuer alle") und Bearbeiten
        if pm := msg.GetProtocolMessage(); pm != nil {
            switch pm.GetType() {
            case waE2E.ProtocolMessage_REVOKE:
                updateMessage("", pm.GetKey().GetID(), func(m *Message) {
                    m.Revoked = true
                    m.Text = "🚫 This message was deleted"
                    m.MediaType = ""
                    m.LocalPath = ""
                })
                return
            case waE2E.ProtocolMessage_MESSAGE_EDIT:
                if em := pm.GetEditedMessage(); em != nil {
                    newText := em.GetConversation()
                    if newText == "" {
                        newText = em.GetExtendedTextMessage().GetText()
                    }
                    // Caption-Edits: bearbeitete Bild-/Video-Beschriftungen
                    if newText == "" {
                        newText = em.GetImageMessage().GetCaption()
                    }
                    if newText == "" {
                        newText = em.GetVideoMessage().GetCaption()
                    }
                    editID := pm.GetKey().GetID()
                    if newText != "" {
                        found := updateMessage("", editID, func(m *Message) {
                            m.Text = newText
                            m.Edited = true
                        })
                        // Stille war hier schon einmal ein Fehler: jeder
                        // Edit hinterlaesst eine Logspur, gefunden oder nicht
                        fmt.Printf("✏️ edit for %s (found=%v): %.60q\n", editID, found, newText)
                    } else {
                        fmt.Printf("✏️ edit for %s with EMPTY text - unhandled shape: %v\n", editID, em)
                    }
                }
                return
            case waE2E.ProtocolMessage_EPHEMERAL_SETTING:
                secs := pm.GetEphemeralExpiration()
                epChat := resolvePN(v.Info.Chat, types.EmptyJID).User
                epSender := resolvePN(v.Info.Sender, types.EmptyJID).User
                if v.Info.IsFromMe && client.Store.ID != nil {
                    epSender = client.Store.ID.User
                }
                setChatEphemeral(epChat, secs)
                label := "Disappearing messages turned off"
                if secs > 0 {
                    label = "Disappearing messages set to " + ephemeralLabel(secs)
                }
                addMessage(Message{
                    ID: v.Info.ID, Sender: epSender, Text: "⏳ " + label,
                    Timestamp: v.Info.Timestamp.Unix(), FromMe: v.Info.IsFromMe, ChatJID: epChat,
                })
                return
            default:
                return // andere Protokollnachrichten still ignorieren
            }
        }

        // Standort (auch Live-Standort: erster Fix)
        if loc := msg.GetLocationMessage(); loc != nil {
            mediaType = "location"
            latitude = loc.GetDegreesLatitude()
            longitude = loc.GetDegreesLongitude()
            text = strings.TrimSpace(loc.GetName() + " " + loc.GetAddress())
            if text == "" {
                text = fmt.Sprintf("%.5f, %.5f", latitude, longitude)
            }
            text = "📍 " + text
        } else if loc := msg.GetLiveLocationMessage(); loc != nil {
            mediaType = "location"
            latitude = loc.GetDegreesLatitude()
            longitude = loc.GetDegreesLongitude()
            text = "📍 Live location"
        }

        // Kontakt-vCards
        if cm := msg.GetContactMessage(); cm != nil {
            text = "👤 " + cm.GetDisplayName()
        } else if ca := msg.GetContactsArrayMessage(); ca != nil {
            names := []string{}
            for _, c := range ca.GetContacts() {
                names = append(names, c.GetDisplayName())
            }
            text = "👤 " + strings.Join(names, ", ")
        }

        // Umfragen: strukturiert ablegen
        var pollName string
        var pollOptions []string
        var pollMultiple bool
        if n, opts, multi, ok := extractPoll(msg); ok {
            pollName, pollOptions, pollMultiple = n, opts, multi
            mediaType = "poll"
            text = "📊 " + n
        }

        // Eingehende Poll-Stimme: Zielumfrage aktualisieren, keine neue Nachricht
        if pu := msg.GetPollUpdateMessage(); pu != nil {
            voter := resolvePN(v.Info.Sender, v.Info.SenderAlt).User
            targetID := pu.GetPollCreationMessageKey().GetID()
            if vote, err := client.DecryptPollVote(ctx, v); err == nil {
                updateMessage("", targetID, func(m *Message) {
                    if m.PollVoters == nil {
                        m.PollVoters = make(map[string][]string)
                    }
                    m.PollVoters[voter] = matchPollOptions(vote.GetSelectedOptions(), m.PollOptions)
                    if len(m.PollVoters[voter]) == 0 {
                        delete(m.PollVoters, voter) // Stimme zurueckgezogen
                    }
                })
            } else {
                fmt.Printf("⚠️ Could not decrypt poll vote for %s: %v\n", targetID, err)
            }
            return
        }

        // Gruppen-Einladung
        if gi := msg.GetGroupInviteMessage(); gi != nil {
            text = "👥 Group invite: " + gi.GetGroupName()
        }

        // Zitat/Antwort auslesen
        var quotedID, quotedText, quotedSender string
        var mentions []string
        var forwarded bool
        var ephemeral uint32
        if ci := getContextInfo(msg); ci != nil {
            if ci.GetStanzaID() != "" {
                quotedID = ci.GetStanzaID()
                quotedText = quotedSnippet(ci.GetQuotedMessage())
                if p := ci.GetParticipant(); p != "" {
                    if pj, err := types.ParseJID(p); err == nil {
                        quotedSender = resolvePN(pj, types.EmptyJID).User
                    }
                }
            }
            for _, mj := range ci.GetMentionedJID() {
                if pj, err := types.ParseJID(mj); err == nil {
                    mentions = append(mentions, resolvePN(pj, types.EmptyJID).User)
                }
            }
            forwarded = ci.GetIsForwarded() || ci.GetForwardingScore() > 0
            ephemeral = ci.GetExpiration()
        }

        isLive := msg.GetLiveLocationMessage() != nil
        
        if msg.ImageMessage != nil {
            mediaType = "image"
            mimeType = msg.ImageMessage.GetMimetype()
            fileSize = msg.ImageMessage.GetFileLength()
            if c := msg.ImageMessage.GetCaption(); c != "" {
                text = c
            }
            if !shouldAutoDownload("image") {
                stashRawMedia(v.Info.ID, msg)
            } else if path, err := downloadMedia(v.Info.ID, msg.ImageMessage, mimeType, ""); err == nil {
                localPath = path
            } else {
                fmt.Printf("⚠️ Media download failed (%s), keeping key for retry: %v\n", v.Info.ID, err)
                stashRawMedia(v.Info.ID, msg)
            }
        }
        
        if msg.VideoMessage != nil {
            mediaType = "video"
            mimeType = msg.VideoMessage.GetMimetype()
            fileSize = msg.VideoMessage.GetFileLength()
            if c := msg.VideoMessage.GetCaption(); c != "" {
                text = c
            }
            if !shouldAutoDownload("video") {
                stashRawMedia(v.Info.ID, msg)
            } else if path, err := downloadMedia(v.Info.ID, msg.VideoMessage, mimeType, ""); err == nil {
                localPath = path
            } else {
                fmt.Printf("⚠️ Media download failed (%s), keeping key for retry: %v\n", v.Info.ID, err)
                stashRawMedia(v.Info.ID, msg)
            }
        }
        
        if msg.AudioMessage != nil {
            mediaType = "audio"
            mimeType = msg.AudioMessage.GetMimetype()
            fileSize = msg.AudioMessage.GetFileLength()
            if !shouldAutoDownload("audio") {
                stashRawMedia(v.Info.ID, msg)
            } else if path, err := downloadMedia(v.Info.ID, msg.AudioMessage, mimeType, ""); err == nil {
                localPath = path
            } else {
                fmt.Printf("⚠️ Media download failed (%s), keeping key for retry: %v\n", v.Info.ID, err)
                stashRawMedia(v.Info.ID, msg)
            }
        }
        
        if msg.DocumentMessage != nil {
            mediaType = "document"
            mimeType = msg.DocumentMessage.GetMimetype()
            fileName = msg.DocumentMessage.GetFileName()
            fileSize = msg.DocumentMessage.GetFileLength()
            if c := msg.DocumentMessage.GetCaption(); c != "" {
                text = c
            }
            if !shouldAutoDownload("document") {
                stashRawMedia(v.Info.ID, msg)
            } else if path, err := downloadMedia(v.Info.ID, msg.DocumentMessage, mimeType, fileName); err == nil {
                localPath = path
            } else {
                fmt.Printf("⚠️ Media download failed (%s), keeping key for retry: %v\n", v.Info.ID, err)
                stashRawMedia(v.Info.ID, msg)
            }
        }
        
        if msg.StickerMessage != nil {
            mediaType = "sticker"
            mimeType = msg.StickerMessage.GetMimetype()
            if !shouldAutoDownload("sticker") {
                stashRawMedia(v.Info.ID, msg)
            } else if path, err := downloadMedia(v.Info.ID, msg.StickerMessage, mimeType, ""); err == nil {
                localPath = path
            } else {
                fmt.Printf("⚠️ Media download failed (%s), keeping key for retry: %v\n", v.Info.ID, err)
                stashRawMedia(v.Info.ID, msg)
            }
        }
        
        // WhatsApp increasingly addresses DMs with @lid JIDs instead of the
        // phone number JID. Without resolving LID -> phone number, incoming
        // messages get keyed under a different chat ID and show up as a new,
        // separate chat instead of the existing one.
        chatJID := v.Info.Chat.ToNonAD()
        senderJID := resolvePN(v.Info.Sender, v.Info.SenderAlt)
        if chatJID.Server == types.HiddenUserServer {
            var alt types.JID
            if v.Info.IsFromMe {
                alt = v.Info.RecipientAlt
            } else {
                alt = v.Info.SenderAlt
            }
            chatJID = resolvePN(chatJID, alt)
        }
        chatJid := chatJID.User
        if chatJID.Server == types.BroadcastServer && chatJID.User == "status" {
            chatJid = "status"
            fmt.Printf("📸 Status update from %s (media=%s, text=%d chars)\n",
                senderJID.User, mediaType, len(text))
        }
        sender := senderJID.User
        senderIsLid := senderJID.Server == types.HiddenUserServer
        if v.Info.IsFromMe {
            sender = client.Store.ID.User
            senderIsLid = false
        }

        // Nachricht im Chat anpinnen/loesen (kommt als eigene Nachricht)
        if pin := msg.GetPinInChatMessage(); pin != nil && pin.GetKey() != nil {
            setMessagePinned(chatJid, pin.GetKey().GetID(), pin.GetType() == waE2E.PinInChatMessage_PIN_FOR_ALL)
            return
        }

        // Gruppen-Einladung als interaktive Nachricht ablegen
        if inv := msg.GetGroupInviteMessage(); inv != nil {
            addMessage(Message{
                ID: v.Info.ID, Sender: sender, SenderIsLid: senderIsLid, Timestamp: v.Info.Timestamp.Unix(),
                FromMe: v.Info.IsFromMe, ChatJID: chatJid,
                Text: "👥 Invitation: " + inv.GetGroupName(),
                InviteGroupJID:   inv.GetGroupJID(),
                InviteGroupName:  inv.GetGroupName(),
                InviteCode:       inv.GetInviteCode(),
                InviteExpiration: inv.GetInviteExpiration(),
                InviteFrom:       sender,
                Ephemeral:        ephemeral,
            })
            return
        }

        // Live-Standort-Updates ersetzen den letzten Fix desselben Absenders
        if isLive && updateLiveLocation(chatJid, sender, latitude, longitude, v.Info.Timestamp.Unix()) {
            return
        }
        if v.Info.PushName != "" && !v.Info.IsFromMe {
            contactsMutex.Lock()
            contacts[sender] = v.Info.PushName
            contactsMutex.Unlock()
            go saveContacts()
        }
        
        if text != "" || mediaType != "" {
            addMessage(Message{
                ID: v.Info.ID, Sender: sender, SenderIsLid: senderIsLid, Text: text, Timestamp: v.Info.Timestamp.Unix(),
                FromMe: v.Info.IsFromMe, ChatJID: chatJid, MediaType: mediaType,
                MimeType: mimeType, FileName: fileName, FileSize: fileSize, LocalPath: localPath,
                Latitude: latitude, Longitude: longitude,
                QuotedID: quotedID, QuotedText: quotedText, QuotedSender: quotedSender,
                PollName: pollName, PollOptions: pollOptions, PollMultiple: pollMultiple,
                Mentions: mentions, Forwarded: forwarded, Live: isLive, Ephemeral: ephemeral,
            })
            if mediaType != "" {
                fmt.Printf("📩 %s: [%s] %s\n", chatJid, mediaType, text)
            } else {
                fmt.Printf("📩 %s: %s\n", chatJid, text)
            }
            if !v.Info.IsFromMe && chatJid != "status" {
                senderName := v.Info.PushName
                if senderName == "" {
                    senderName = sender
                }
                title := senderName
                preview := text
                if preview == "" {
                    preview = "[" + mediaType + "]"
                }
                // Gruppen: Titel = Gruppenname, Absender gehoert in den Text -
                // sonst sieht die Benachrichtigung aus, als kaeme sie von der
                // Person statt aus der Gruppe
                if v.Info.IsGroup {
                    if gname := getContactName(chatJid); gname != "" && gname != chatJid {
                        title = gname
                        preview = senderName + ": " + preview
                    }
                }
                if len(preview) > 120 {
                    preview = preview[:120] + "…"
                }
                go notifyIncoming(chatJid, title, preview)
            }
        }
        
    case *events.MediaRetry:
        pendingRetriesMutex.Lock()
        mediaKey, ok := pendingRetries[string(v.MessageID)]
        delete(pendingRetries, string(v.MessageID))
        pendingRetriesMutex.Unlock()
        if !ok {
            break
        }
        if v.Error != nil || v.Ciphertext == nil {
            fmt.Printf("⚠️ Media retry failed for %s (phone offline or media gone)\n", v.MessageID)
            break
        }
        retryData, err := whatsmeow.DecryptMediaRetryNotification(v, mediaKey)
        if err != nil || retryData.GetResult() != waMmsRetry.MediaRetryNotification_SUCCESS {
            fmt.Printf("⚠️ Media retry unsuccessful for %s: %v / %v\n", v.MessageID, err, retryData.GetResult())
            break
        }
        msgID := string(v.MessageID)
        rawMediaMutex.RLock()
        b64, ok2 := rawMedia[msgID]
        rawMediaMutex.RUnlock()
        if !ok2 {
            break
        }
        data, err := base64.StdEncoding.DecodeString(b64)
        if err != nil {
            break
        }
        var full waE2E.Message
        if err := proto.Unmarshal(data, &full); err != nil {
            break
        }
        // Neuen DirectPath in den downloadbaren Teil schreiben
        newPath := retryData.GetDirectPath()
        switch {
        case full.GetImageMessage() != nil:
            full.GetImageMessage().DirectPath = proto.String(newPath)
        case full.GetVideoMessage() != nil:
            full.GetVideoMessage().DirectPath = proto.String(newPath)
        case full.GetAudioMessage() != nil:
            full.GetAudioMessage().DirectPath = proto.String(newPath)
        case full.GetDocumentMessage() != nil:
            full.GetDocumentMessage().DirectPath = proto.String(newPath)
        case full.GetStickerMessage() != nil:
            full.GetStickerMessage().DirectPath = proto.String(newPath)
        }
        _, mimeType, fileName, _, _, dl := extractMedia(&full)
        if dl == nil {
            break
        }
        if path, err := downloadMedia(msgID, dl, mimeType, fileName); err == nil {
            updateMessage("", msgID, func(m *Message) { m.LocalPath = path })
            // Key mit frischem DirectPath behalten (Re-Download-Policy)
            if nd, merr := proto.Marshal(&full); merr == nil {
                rawMediaMutex.Lock()
                rawMedia[msgID] = base64.StdEncoding.EncodeToString(nd)
                rawMediaMutex.Unlock()
                go saveRawMedia()
            }
            fmt.Printf("📥 Media retry succeeded for %s\n", msgID)
        } else {
            // aktualisierten Proto aufheben, naechster /download-Versuch nutzt ihn
            if nd, merr := proto.Marshal(&full); merr == nil {
                rawMediaMutex.Lock()
                rawMedia[msgID] = base64.StdEncoding.EncodeToString(nd)
                rawMediaMutex.Unlock()
                go saveRawMedia()
            }
            fmt.Printf("⚠️ Download after retry failed for %s: %v\n", msgID, err)
        }

    case *events.CallOffer:
        activeCallsMutex.Lock()
        activeCalls[v.CallID] = false
        activeCallsMutex.Unlock()
        fmt.Printf("📞 Incoming call from %s\n", v.From.User)

    case *events.CallOfferNotice:
        activeCallsMutex.Lock()
        activeCalls[v.CallID] = false
        activeCallsMutex.Unlock()
        fmt.Printf("📞 Incoming %s call (%s) from %s\n", v.Media, v.Type, v.From.User)

    case *events.CallAccept:
        activeCallsMutex.Lock()
        activeCalls[v.CallID] = true
        activeCallsMutex.Unlock()

    case *events.CallTerminate:
        activeCallsMutex.Lock()
        accepted, known := activeCalls[v.CallID]
        delete(activeCalls, v.CallID)
        activeCallsMutex.Unlock()
        if !known {
            break
        }
        caller := v.CallCreator
        if caller.IsEmpty() {
            caller = v.From
        }
        callerPN := resolvePN(caller, types.EmptyJID)
        // Eigene abgehende Anrufe (am Telefon gestartet) nicht protokollieren
        if client != nil && client.Store.ID != nil && callerPN.User == client.Store.ID.User {
            break
        }
        chatJid := callerPN.User
        if !v.GroupJID.IsEmpty() {
            chatJid = v.GroupJID.ToNonAD().User
        }
        text := "📞 Missed call"
        if accepted {
            text = "📞 Incoming call (answered on your phone)"
        }
        addMessage(Message{
            ID: "call-" + v.CallID, Sender: chatJid, Text: text,
            Timestamp: v.Timestamp.Unix(), FromMe: false, ChatJID: chatJid,
        })
        fmt.Printf("%s from %s\n", text, chatJid)

    case *events.UndecryptableMessage:
        tag := ""
        if v.Info.Chat.Server == types.BroadcastServer && v.Info.Chat.User == "status" {
            tag = " [STATUS!]"
        }
        fmt.Printf("🔓 Undecryptable message%s from %s in %s (type=%s) - retry receipt sent\n",
            tag, v.Info.Sender.User, v.Info.Chat.String(), v.Info.Type)

    case *events.PushNameSetting:
        // Push-Name gerade gesetzt (z.B. nach frischem Pairing): Presence
        // sofort senden, damit Status-Broadcasts freigeschaltet werden
        go func() {
            if err := client.SendPresence(ctx, types.PresenceAvailable); err == nil {
                fmt.Println("👋 Presence: available (push name arrived via app state)")
            }
        }()

    case *events.Connected:
        lastConnectedAt = time.Now()
        consecReconnects = 0
        // Available-Presence senden: ohne sie stellt WhatsApp keine
        // Status-Broadcasts (Stories) an dieses Geraet zu. Nebenwirkung wie
        // bei WhatsApp Web: solange verbunden, gilt das Geraet als online.
        go func() {
            // Ohne Push-Namen schlaegt SendPresence fehl - nach einem
            // frischen Pairing trifft er erst per App-State-Sync ein.
            // Statt aufzugeben: bis zu 2 Minuten darauf warten und die
            // Presence nachschieben, sonst kommen nie Status-Updates.
            for attempt := 0; attempt < 24; attempt++ {
                if client.Store.PushName != "" {
                    if err := client.SendPresence(ctx, types.PresenceAvailable); err != nil {
                        fmt.Printf("⚠️ SendPresence failed: %v\n", err)
                    } else {
                        if attempt > 0 {
                            fmt.Printf("👋 Presence: available after waiting for push name (%ds)\n", attempt*5)
                        } else {
                            fmt.Println("👋 Presence: available (status updates enabled)")
                        }
                    }
                    return
                }
                if attempt == 0 {
                    fmt.Println("⏳ No push name yet - waiting for app state sync to enable statuses...")
                }
                time.Sleep(5 * time.Second)
            }
            fmt.Println("⚠️ Push name still missing after 2 min - statuses stay disabled until next connect")
        }()
        isConnected = true
        connState = "connected"
        lastError = ""
        fmt.Println("✅ Connected")
        go func() {
            time.Sleep(5 * time.Second)
            refreshChannelNames()
        }()
        go func() {
            time.Sleep(2 * time.Second)
            loadContacts()
            // Diagnose: wie viele Kontakte kennt der whatsmeow-Store?
            // Eigene Status gehen nur an Kontakte mit FullName - nach einem
            // frischen Pairing kann der Store leer sein, bis der App-State-
            // Sync vom Telefon durch ist.
            countContacts := func() (int, int) {
                all, cerr := client.Store.Contacts.GetAllContacts(ctx)
                if cerr != nil {
                    return -1, -1
                }
                withName := 0
                for _, c := range all {
                    if len(c.FullName) > 0 {
                        withName++
                    }
                }
                return len(all), withName
            }
            total, withName := countContacts()
            fmt.Printf("📇 whatsmeow contact store: %d contacts, %d with full name (status reach)\n",
                total, withName)
            // Der initiale App-State-Sync (Kontaktliste, Pin/Mute/Archiv vom
            // Telefon) passiert in whatsmeow NICHT automatisch - er muss
            // explizit angefordert werden (wie es auch mautrix-whatsapp nach
            // dem Login tut). Ohne ihn bleibt der Kontakt-Store leer und
            // eigene Status erreichen niemanden.
            if withName == 0 {
                fmt.Println("📇 Contact store empty - requesting full app state sync from phone...")
                for _, name := range []appstate.WAPatchName{
                    appstate.WAPatchCriticalBlock,
                    appstate.WAPatchCriticalUnblockLow,
                    appstate.WAPatchRegularHigh,
                    appstate.WAPatchRegular,
                    appstate.WAPatchRegularLow,
                } {
                    if serr := client.FetchAppState(ctx, name, true, false); serr != nil {
                        fmt.Printf("📇 app state sync %s failed: %v\n", name, serr)
                    }
                }
                total, withName = countContacts()
                fmt.Printf("📇 after app state sync: %d contacts, %d with full name\n", total, withName)
                // Beweissicherung: gespeicherte Patch-Versionen. Version > 0
                // bei 0 Kontakten bedeutet: Patches kamen an und wurden
                // angewendet, der serverseitige App-State enthaelt aber
                // schlicht (noch) keine Kontakte - das Telefon muss seine
                // Daten erst hochladen (z.B. nach frischer Neuverbindung).
                for _, name := range []appstate.WAPatchName{
                    appstate.WAPatchCriticalUnblockLow,
                    appstate.WAPatchRegular,
                } {
                    if v, _, verr := client.Store.AppState.GetAppStateVersion(ctx, string(name)); verr == nil {
                        fmt.Printf("📇 app state %s stored version: %d\n", name, v)
                    }
                }
            }
        }()
        
    case *events.Receipt:
        // Ebene 2 der Ungelesen-Logik: liest man den Chat am TELEFON,
        // verteilt WhatsApp ein Receipt an alle Geraete - read-self bei
        // deaktivierten Lesebestaetigungen, sonst read vom eigenen JID
        if v.Type == types.ReceiptTypeReadSelf ||
            (v.Type == types.ReceiptTypeRead && client.Store.ID != nil && v.MessageSource.Sender.User == client.Store.ID.User) {
            chat := v.MessageSource.Chat.User
            cs := getChatSettings(chat)
            ts := v.Timestamp.Unix()
            chatSettingsMutex.Lock()
            if ts > cs.LastOpened {
                cs.LastOpened = ts
            }
            chatSettingsMutex.Unlock()
            go saveChatSettings()
            fmt.Printf("📖 read on phone: %s\n", chat)
        }

    case *events.PairError:
        // Der Grund fuer ein Scheitern NACH angenommenem Code (Telefon
        // zeigt nur "there was an error") steckt genau hier - vorher
        // wurde dieses Event stumm verworfen
        lastError = "Pairing failed: " + v.Error.Error()
        connState = "waiting_for_pair"
        pairCode = ""
        fmt.Printf("❌ PairError: %v (id=%s, platform=%s)\n", v.Error, v.ID, v.Platform)

    case *events.PairSuccess:
        isConnected = true
        connState = "connected"
        lastError = ""
        pairCode = ""
        fmt.Println("✅ Paired!")
        
    case *events.LoggedOut:
        isConnected = false
        connState = "logged_out"
        lastError = "Logged out by server"
        pairCode = ""
        fmt.Println("❌ Logged out by server")

    case *events.Disconnected:
        isConnected = false
        if connState == "logged_out" || connState == "relogin_required" {
            break
        }
        connState = "reconnecting"
        // Kurzlebige Verbindungen deuten auf Gerangel/Instabilitaet:
        // Backoff waechst. Nach >2 min stabiler Verbindung zaehlt es
        // als Einzelfall und der Zaehler faellt zurueck.
        if time.Since(lastConnectedAt) > 2*time.Minute {
            consecReconnects = 1
        } else {
            consecReconnects++
        }
        fmt.Println("🔌 Disconnected - scheduling guarded reconnect")
        connectWithGuard("auto-reconnect")

    case *events.ConnectFailure:
        isConnected = false
        connState = "error"
        lastError = fmt.Sprintf("Connect failure: %s", v.Reason.String())
        fmt.Printf("❌ %s\n", lastError)
        rs := strings.ToLower(v.Reason.String())
        if !strings.Contains(rs, "logged") && !strings.Contains(rs, "ban") &&
            !strings.Contains(rs, "outdated") && !strings.Contains(rs, "unauthorized") {
            consecReconnects++
            connectWithGuard("connect-failure")
        }

    case *events.ClientOutdated:
        isConnected = false
        connState = "error"
        lastError = "Client outdated - app update required"
        fmt.Println("❌ Client outdated")

    case *events.StreamReplaced:
        isConnected = false
        connState = "error"
        lastError = "Stream replaced - logged in elsewhere?"
        fmt.Println("❌ Stream replaced")

    case *events.TemporaryBan:
        isConnected = false
        connState = "error"
        lastError = fmt.Sprintf("Temporary ban: %s (expires %s)", v.Code.String(), v.Expire.String())
        fmt.Printf("❌ %s\n", lastError)

    case *events.KeepAliveTimeout:
        connState = "reconnecting"
        fmt.Println("⚠️ Keepalive timeout")
        
    case *events.HistorySync:
        fmt.Printf("📜 History sync: %d conversations\n", len(v.Data.Conversations))
        for _, conv := range v.Data.Conversations {
            jidStr := conv.GetID()
            if parsed, err := types.ParseJID(jidStr); err == nil {
                jidStr = resolvePN(parsed, types.EmptyJID).String()
            }
            name := conv.GetName()
            if name != "" {
                contactsMutex.Lock()
                contacts[jidStr] = name
                contactsMutex.Unlock()
            }
            chatJid := jidStr
            if idx := strings.Index(jidStr, "@"); idx > 0 {
                chatJid = jidStr[:idx]
            }
            for _, hm := range conv.Messages {
                if hm.Message == nil || hm.Message.Message == nil {
                    continue
                }
                msg := hm.Message.Message
                var text string
                if msg.Conversation != nil {
                    text = *msg.Conversation
                } else if msg.ExtendedTextMessage != nil {
                    text = msg.ExtendedTextMessage.GetText()
                }
                mediaType, mimeType, fileName, fileSize, caption, _ := extractMedia(msg)
                if caption != "" {
                    text = caption
                }
                var latitude, longitude float64
                if text == "" && mediaType == "" {
                    text, mediaType, latitude, longitude = specialInfo(msg)
                }
                var pollName string
                var pollOptions []string
                var pollMultiple bool
                if n, opts, multi, ok := extractPoll(msg); ok {
                    pollName, pollOptions, pollMultiple = n, opts, multi
                    mediaType = "poll"
                    text = "📊 " + n
                }
                if text != "" || mediaType != "" {
                    fromMe := hm.Message.GetKey().GetFromMe()
                    ts := int64(hm.Message.GetMessageTimestamp())
                    msgID := hm.Message.GetKey().GetID()
                    if mediaType != "" {
                        stashRawMedia(msgID, msg)
                    }
                    // Bei 1:1-Chats IST der Chatpartner der Absender. Bei
                    // Gruppen war dieser Rueckfall falsch: sender wurde die
                    // Gruppen-JID, und die Oberflaeche fand dazu prompt den
                    // GRUPPENNAMEN in ihrer Kontaktkarte - so stand ueber
                    // fremden Nachrichten der Name der Gruppe. Lieber leer
                    // lassen und die Zeile weglassen als etwas Falsches
                    // behaupten.
                    sender := ""
                    if !strings.Contains(chatJid, "-") {
                        sender = chatJid
                    }
                    if p := hm.Message.GetKey().GetParticipant(); p != "" {
                        if pj, err := types.ParseJID(p); err == nil {
                            sender = resolvePN(pj, types.EmptyJID).User
                        }
                    }
                    addMessage(Message{
                        ID: msgID, Sender: sender, Text: text, Timestamp: ts,
                        FromMe: fromMe, ChatJID: chatJid,
                        MediaType: mediaType, MimeType: mimeType,
                        FileName: fileName, FileSize: fileSize,
                        Latitude: latitude, Longitude: longitude,
                        PollName: pollName, PollOptions: pollOptions, PollMultiple: pollMultiple,
                    })
                }
            }
        }
        go saveContacts()
        fmt.Printf("📜 Total messages: %d\n", len(messages))
    }
}

func getChats() []Chat {
    msgMutex.RLock()
    defer msgMutex.RUnlock()
    // LastOpened-Marker vorab einsammeln (Ebene 1 der Ungelesen-Logik)
    lastOpened := map[string]int64{}
    chatSettingsMutex.RLock()
    for j, cs := range chatSettings {
        lastOpened[j] = cs.LastOpened
    }
    chatSettingsMutex.RUnlock()
    unread := map[string]int{}
    chatMap := make(map[string]*Chat)
    for _, msg := range messages {
        jid := msg.ChatJID
        if jid == "" {
            jid = msg.Sender
        }
        if !msg.FromMe && msg.Timestamp > lastOpened[jid] {
            unread[jid]++
        }
        isGroup := len(jid) > 15
        lastMsg := msg.Text
        if msg.MediaType != "" && lastMsg == "" {
            lastMsg = "[" + msg.MediaType + "]"
        }
        if c, ok := chatMap[jid]; ok {
            if msg.Timestamp > c.LastTime {
                c.LastMessage = lastMsg
                c.LastTime = msg.Timestamp
                c.FromMe = msg.FromMe
            }
        } else {
            chatMap[jid] = &Chat{
                JID: jid, Name: getContactName(jid), LastMessage: lastMsg,
                LastTime: msg.Timestamp, FromMe: msg.FromMe, IsGroup: isGroup,
                Avatar: getAvatar(jid),
            }
        }
    }
    chats := make([]Chat, 0, len(chatMap))
    chatSettingsMutex.RLock()
    for _, c := range chatMap {
        if c.JID == "status" {
            continue // eigene Status-Seite (attached page), nicht in der Chatliste
        }
        if cs, ok := chatSettings[c.JID]; ok {
            c.Pinned, c.Muted, c.Archived, c.Ephemeral = cs.Pinned, cs.Muted, cs.Archived, cs.Ephemeral
        }
        c.Unread = unread[c.JID]
        knownChannelsMutex.RLock()
        c.IsChannel = knownChannels[c.JID]
        knownChannelsMutex.RUnlock()
        chats = append(chats, *c)
    }
    chatSettingsMutex.RUnlock()
    sort.Slice(chats, func(i, j int) bool {
        a, b := chats[i], chats[j]
        if a.Archived != b.Archived {
            return !a.Archived // archivierte ans Ende
        }
        if a.Pinned != b.Pinned {
            return a.Pinned // gepinnte nach vorne
        }
        return a.LastTime > b.LastTime
    })
    return chats
}

func getMessagesForChat(jid string) []Message {
    msgMutex.RLock()
    defer msgMutex.RUnlock()
    var result []Message
    for _, msg := range messages {
        // Sender-Fallback NUR fuer Altnachrichten ohne ChatJID - sonst
        // erscheinen Gruppen-Beitraege einer Person auch im 1:1-Chat
        if msg.ChatJID == jid || (msg.ChatJID == "" && msg.Sender == jid) {
            result = append(result, msg)
        }
    }
    sort.Slice(result, func(i, j int) bool { return result[i].Timestamp < result[j].Timestamp })
    return result
}

func sendMedia(to string, filePath string, caption string) error {
    data, err := os.ReadFile(filePath)
    if err != nil {
        return err
    }
    fileName := filepath.Base(filePath)
    mimeType := getMimeType(fileName)
    var jid types.JID
    if to == "status" {
        jid = types.StatusBroadcastJID // eigener Medien-Status
    } else if len(to) > 15 {
        jid = types.NewJID(to, "g.us")
    } else {
        jid = types.NewJID(to, "s.whatsapp.net")
    }
    var mediaType whatsmeow.MediaType
    var mediaTypeStr string
    if strings.HasPrefix(mimeType, "image/") {
        mediaType = whatsmeow.MediaImage
        mediaTypeStr = "image"
    } else if strings.HasPrefix(mimeType, "video/") {
        mediaType = whatsmeow.MediaVideo
        mediaTypeStr = "video"
    } else if strings.HasPrefix(mimeType, "audio/") {
        mediaType = whatsmeow.MediaAudio
        mediaTypeStr = "audio"
    } else {
        mediaType = whatsmeow.MediaDocument
        mediaTypeStr = "document"
    }
    uploaded, err := client.Upload(ctx, data, mediaType)
    if err != nil {
        return fmt.Errorf("upload failed: %v", err)
    }
    var msg *waE2E.Message
    fileLen := uint64(len(data))
    switch mediaType {
    case whatsmeow.MediaImage:
        msg = &waE2E.Message{ImageMessage: &waE2E.ImageMessage{
            URL: &uploaded.URL, DirectPath: &uploaded.DirectPath, MediaKey: uploaded.MediaKey,
            Mimetype: &mimeType, FileEncSHA256: uploaded.FileEncSHA256, FileSHA256: uploaded.FileSHA256,
            FileLength: &fileLen, Caption: &caption,
        }}
    case whatsmeow.MediaVideo:
        msg = &waE2E.Message{VideoMessage: &waE2E.VideoMessage{
            URL: &uploaded.URL, DirectPath: &uploaded.DirectPath, MediaKey: uploaded.MediaKey,
            Mimetype: &mimeType, FileEncSHA256: uploaded.FileEncSHA256, FileSHA256: uploaded.FileSHA256,
            FileLength: &fileLen, Caption: &caption,
        }}
    case whatsmeow.MediaAudio:
        msg = &waE2E.Message{AudioMessage: &waE2E.AudioMessage{
            URL: &uploaded.URL, DirectPath: &uploaded.DirectPath, MediaKey: uploaded.MediaKey,
            Mimetype: &mimeType, FileEncSHA256: uploaded.FileEncSHA256, FileSHA256: uploaded.FileSHA256,
            FileLength: &fileLen,
        }}
    default:
        msg = &waE2E.Message{DocumentMessage: &waE2E.DocumentMessage{
            URL: &uploaded.URL, DirectPath: &uploaded.DirectPath, MediaKey: uploaded.MediaKey,
            Mimetype: &mimeType, FileEncSHA256: uploaded.FileEncSHA256, FileSHA256: uploaded.FileSHA256,
            FileLength: &fileLen, FileName: &fileName, Caption: &caption,
        }}
    }
    resp, err := client.SendMessage(ctx, jid, msg)
    if err != nil {
        return err
    }
    addMessage(Message{
        ID: resp.ID, Sender: client.Store.ID.User, Text: caption, Timestamp: time.Now().Unix(),
        FromMe: true, ChatJID: to, MediaType: mediaTypeStr, MimeType: mimeType,
        FileName: fileName, FileSize: fileLen, LocalPath: filePath,
    })
    fmt.Printf("📤 Sent %s to %s\n", fileName, to)
    return nil
}

// sendVoice sendet eine echte WhatsApp-Sprachnachricht: nur die
// Kombination aus PTT-Flag, "audio/ogg; codecs=opus" und gesetzter Dauer
// laesst Android/iOS/Web sie als Voice Note (Inline-Player in der Blase)
// rendern - sonst erscheint nur ein generisches Audio-Attachment.
func sendVoice(to string, filePath string, seconds uint32) error {
    data, err := os.ReadFile(filePath)
    if err != nil {
        return err
    }
    var jid types.JID
    if len(to) > 15 {
        jid = types.NewJID(to, "g.us")
    } else {
        jid = types.NewJID(to, "s.whatsapp.net")
    }
    uploaded, err := client.Upload(ctx, data, whatsmeow.MediaAudio)
    if err != nil {
        return fmt.Errorf("upload failed: %v", err)
    }
    mimeType := "audio/ogg; codecs=opus"
    ptt := true
    fileLen := uint64(len(data))
    msg := &waE2E.Message{AudioMessage: &waE2E.AudioMessage{
        URL: &uploaded.URL, DirectPath: &uploaded.DirectPath, MediaKey: uploaded.MediaKey,
        Mimetype: &mimeType, FileEncSHA256: uploaded.FileEncSHA256, FileSHA256: uploaded.FileSHA256,
        FileLength: &fileLen, PTT: &ptt, Seconds: &seconds,
    }}
    resp, err := client.SendMessage(ctx, jid, msg)
    if err != nil {
        return err
    }
    addMessage(Message{
        ID: resp.ID, Sender: client.Store.ID.User, Text: "", Timestamp: time.Now().Unix(),
        FromMe: true, ChatJID: to, MediaType: "audio", MimeType: mimeType,
        FileName: filepath.Base(filePath), FileSize: fileLen, LocalPath: filePath,
    })
    fmt.Printf("🎤 Sent voice note to %s (%ds, %d bytes)\n", to, seconds, fileLen)
    return nil
}

func main() {
    // Initialize paths first
    initPaths()
    redirectDaemonOutput()
    daemonTakeover()
    go startReplyService()
    go daemonWatchdog()

    // Bind the HTTP port FIRST, before the (potentially slow) Secrets
    // handshake and DB initialization. The launcher and the UI can then
    // reach /status immediately (state "starting") instead of assuming
    // the backend failed, and the port file always matches reality.
    // Loopback only - the API must never be reachable from the network.
    var listener net.Listener
    var port int
    for p := 8085; p <= 8089; p++ {
        l, lerr := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", p))
        if lerr == nil {
            listener = l
            port = p
            break
        }
        fmt.Printf("⚠️ Port %d unavailable: %v\n", p, lerr)
    }
    if listener == nil {
        fmt.Println("❌ No free port in 8085-8089, exiting")
        os.Exit(1)
    }
    boundPort = port
    os.WriteFile("backend.port", []byte(fmt.Sprintf("%d", port)), 0600)
    fmt.Printf("🚀 Backend listening on http://127.0.0.1:%d (initializing…)\n", port)
    go http.Serve(listener, nil)

    http.HandleFunc("/daemon/restart", func(w http.ResponseWriter, r *http.Request) {
        // Selbst-Update des Daemons: nach einem RPM-Update laeuft noch der
        // alte Prozess. Ein sauberes /quit wird absichtlich NICHT neu
        // gestartet - deshalb hier Exit-Code 1, damit Restart=on-failure
        // greift und systemd den frisch installierten Binary startet.
        if os.Getenv("WA_DAEMON") != "1" {
            http.Error(w, "not a daemon", 400)
            return
        }
        fmt.Println("🔄 Daemon restart requested (version upgrade) - exiting 1 for systemd")
        saveMessages()
        saveContacts()
        saveRawMedia()
        releasePortFile()
        json.NewEncoder(w).Encode(map[string]bool{"ok": true})
        go func() {
            time.Sleep(300 * time.Millisecond)
            if client != nil {
                client.Disconnect()
            }
            os.Exit(1)
        }()
    })

    http.HandleFunc("/quit", func(w http.ResponseWriter, r *http.Request) {
        fmt.Println("👋 Quit requested (update?), saving and exiting...")
        saveMessages()
        saveContacts()
        saveRawMedia()
        releasePortFile()
        json.NewEncoder(w).Encode(map[string]bool{"ok": true})
        go func() {
            time.Sleep(300 * time.Millisecond)
            if client != nil {
                client.Disconnect()
            }
            os.Exit(0)
        }()
    })

    // /reset: nur im Zustand relogin_required erlaubt - loescht die lokale
    // Datenbank, damit nach dem Neustart frisch (verschluesselt) gepairt wird
    http.HandleFunc("/reset", func(w http.ResponseWriter, r *http.Request) {
        if connState != "relogin_required" && connState != "secrets_error" {
            http.Error(w, "reset only allowed when relogin is required or secrets are unreachable", 403)
            return
        }
        for _, f := range []string{"wa.db", "wa.db-wal", "wa.db-shm"} {
            os.Remove(f)
        }
        fmt.Println("🗑️ Local database removed - restart backend to pair again")
        json.NewEncoder(w).Encode(map[string]bool{"ok": true})
        go func() {
            time.Sleep(300 * time.Millisecond)
            os.Exit(0)
        }()
    })

    // /status sofort registrieren, damit Launcher und UI den Zustand
    // "starting" sehen, waehrend Secrets/DB noch initialisieren
    http.HandleFunc("/status", func(w http.ResponseWriter, r *http.Request) {
        w.Header().Set("Content-Type", "application/json")
        phone := ""
        if client != nil && client.Store != nil && client.Store.ID != nil {
            phone = client.Store.ID.User
        }
        state := connState
        if client == nil && state == "" {
            // HTTP laeuft schon, Initialisierung noch nicht fertig.
            // Gesetzte Halt-Zustaende (relogin_required, secrets_error)
            // duerfen NICHT ueberschrieben werden - der Client bleibt dort
            // absichtlich nil.
            state = "starting"
        }
        json.NewEncoder(w).Encode(map[string]interface{}{
            "connected": isConnected,
            "pairCode":  pairCode,
            "phone":     phone,
            "state":     state,
            "lastError": lastError,
            "version":   version,
            "daemon":    isDaemon,
            "network":   netState,
            "paired":    client != nil && client.Store != nil && client.Store.ID != nil,
        })
    })

    
    // Initialize Sailfish Secrets. On a cold boot sailfishsecretsd may not
    // be ready yet - retry briefly with backoff. Init and key retrieval are
    // retried independently, so a transient key error does not force a full
    // re-init, and the total wait is capped at ~8 s.
    var err error
    secretsReady := false
    for attempt := 0; attempt < 8; attempt++ {
        if !secretsReady {
            if err = InitSecrets(); err != nil {
                fmt.Printf("⏳ Secrets init not ready (attempt %d/8): %v\n", attempt+1, err)
                time.Sleep(time.Duration(200+attempt*250) * time.Millisecond)
                continue
            }
            secretsReady = true
        }
        if encryptionKey, err = GetOrCreateKey(); err == nil {
            break
        }
        if IsOwnershipError(err) || err == ErrKeyHandoverRequested || err == ErrKeyExported {
            // Identitaets-Konflikt bzw. Uebergabe: Retries aendern daran nichts
            break
        }
        fmt.Printf("⏳ Key not ready (attempt %d/8): %v\n", attempt+1, err)
        time.Sleep(time.Duration(200+attempt*250) * time.Millisecond)
    }
    // Secrets-only-Policy: Verschluesselung kommt ausschliesslich aus
    // Sailfish Secrets. Eine Datenbank, die ohne Secrets angelegt wurde
    // (Klartext-SQLite-Header), wird nicht weiterbetrieben - der Nutzer
    // wird zum Zuruecksetzen und Neu-Pairing aufgefordert. Ohne Secrets
    // wird auch keine neue Datenbank angelegt.
    legacyPlaintextDB := false
    if f, ferr := os.Open("wa.db"); ferr == nil {
        hdr := make([]byte, 16)
        n, _ := f.Read(hdr)
        f.Close()
        legacyPlaintextDB = n >= 16 && bytes.HasPrefix(hdr, []byte("SQLite format 3\x00"))
    }
    if legacyPlaintextDB {
        haltWithState("relogin_required",
            "Your local database was created without Sailfish Secrets and is stored "+
                "UNENCRYPTED. To protect your messages, this app now requires Sailfish "+
                "Secrets. Please tap 'Reset & pair again' - this deletes the local "+
                "database (your chats stay on your phone and will re-sync) and creates "+
                "a new, encrypted one.")
    }
    if err != nil {
        // Kein Anhalten mehr - der Zustand ist selbstheilend. Zwei Faelle:
        // (a) Schluessel gehoert einer anderen Identitaet: nur ein App-Start
        //     kann uebergeben; nach ein paar Minuten erfolgloser Versuche
        //     klopft der Daemon per Benachrichtigung an.
        // (b) Secrets (noch) nicht verfuegbar - der Normalfall beim Boot,
        //     solange das Geraet gesperrt ist: stilles Warten, das
        //     Entsperren heilt von selbst.
        // Wichtig: KEINE Ursachen-Fiktion im Text - der Fehlercode sagt nur,
        // was er sagt.
        isOwn := err == ErrKeyHandoverRequested || err == ErrKeyExported || IsOwnershipError(err)
        connState = "secrets_error"
        if isOwn {
            lastError = "The encryption key is currently owned by a different " +
            "application identity - for example an earlier install or start " +
            "method. Nothing is lost and there is nothing to type: open the " +
            "app once from the app grid. It hands the key over inside " +
            "Sailfish Secrets automatically (the key never touches the " +
            "disk), and this instance picks it up by itself within a few " +
            "seconds - same messages, no re-pairing."
        } else {
            lastError = "Waiting for Sailfish Secrets (" + err.Error() + ") - " +
                "this resolves automatically once the service is available, " +
                "typically right after unlocking the device."
        }
        fmt.Printf("🛑 secrets_error: waiting (ownership=%v), retrying every 10 s\n", isOwn)
        tries := 0
        for {
            time.Sleep(10 * time.Second)
            if encryptionKey, err = GetOrCreateKey(); err == nil {
                connState = ""
                lastError = ""
                fmt.Println("🔐 Key acquired - continuing startup")
                break
            }
            tries++
            if err == ErrKeyHandoverRequested || IsOwnershipError(err) {
                lastError = "The encryption key is currently owned by a different " +
            "application identity - for example an earlier install or start " +
            "method. Nothing is lost and there is nothing to type: open the " +
            "app once from the app grid. It hands the key over inside " +
            "Sailfish Secrets automatically (the key never touches the " +
            "disk), and this instance picks it up by itself within a few " +
            "seconds - same messages, no re-pairing."
                if tries >= 18 { // ~3 Minuten: das loest sich nicht von allein
                    notifySetupHint("Background service needs a one-time key handover: please open the WhatsApp app once. Everything continues automatically afterwards.")
                }
            } else {
                lastError = "Waiting for Sailfish Secrets (" + err.Error() + ") - " +
                    "this resolves automatically once the service is available, " +
                    "typically right after unlocking the device."
            }
        }
    }

    
    // Daemon-Selbst-Update OHNE App: die installierte Version steht in
    // /usr/share/harbour-whatsapp/VERSION (im Jail lesbar). Weicht sie von
    // der eigenen ab, geordnet mit Exit 1 aussteigen - Restart=on-failure
    // zieht den frisch installierten Binary hoch. Der QML-Trigger aus
    // 0.9.177 bleibt als schnellerer Weg bestehen; dieser Pfad deckt
    // reine Daemon-Nutzer ab, die die App nach Updates nie oeffnen.
    if isDaemon {
        go func() {
            for {
                time.Sleep(5 * time.Minute)
                iv := ""
                if b, rerr := os.ReadFile("/usr/share/harbour-whatsapp/VERSION"); rerr == nil {
                    iv = strings.TrimSpace(string(b))
                } else if b, derr := os.ReadFile("/usr/share/applications/harbour-whatsapp-daemon.desktop"); derr == nil {
                    // VERSION liegt ausserhalb des Daemon-Jails - das eigene
                    // Desktop-File ist dagegen whitelisted und traegt seit
                    // 0.9.182 einen X-Whatsapp-Version-Stempel aus der Spec
                    for _, ln := range strings.Split(string(b), "\n") {
                        if strings.HasPrefix(ln, "X-Whatsapp-Version=") {
                            iv = strings.TrimSpace(strings.TrimPrefix(ln, "X-Whatsapp-Version="))
                            break
                        }
                    }
                } else if !versionPollErrLogged {
                    versionPollErrLogged = true
                    fmt.Printf("⚠ self-update poller: no readable version source (%v / %v)\n", rerr, derr)
                }
                if iv != "" && iv != version {
                    fmt.Printf("🔄 installed version %s != running %s - self-updating via exit 1\n", iv, version)
                    saveMessages()
                    saveContacts()
                    saveRawMedia()
                    releasePortFile()
                    os.Exit(1)
                }
            }
        }()
    }

    // Laufzeit-Waechter der Besitzerseite: trifft die Uebergabe-Bitte erst
    // ein, waehrend wir schon laufen, exportieren wir sie im Betrieb -
    // die bittende Seite (Retry-Schleife) bedient sich dann von selbst
    go func() {
        for {
            time.Sleep(15 * time.Second)
            if len(encryptionKey) != 32 {
                continue
            }
            if _, merr := os.Stat(".want-key-handover"); merr == nil {
                if _, eerr := exportKeyForHandover(secrets.collectionName, encryptionKey); eerr == nil {
                    os.Remove(".want-key-handover")
                    fmt.Println("🔐 Key handed over to requesting identity (runtime)")
                }
            }
        }
    }()

    // Initialize encrypted database
    if err := initDatabase(); err != nil {
        fmt.Printf("❌ Database error: %v\n", err)
        // Selbsthilfe direkt ins Log: die haeufigste Ursache ist eine
        // unlesbare wa.db (alter Klartext-Bestand oder fremder Schluessel) -
        // ohne diesen Hinweis kostete genau dieser Fall drei Support-Runden
        if strings.Contains(err.Error(), "not a database") {
            fmt.Println("💡 wa.db is unreadable (old install or wrong key). Fresh start: delete ~/.local/share/harbour/harbour-whatsapp (NOT ~/.local/share/harbour-whatsapp - that legacy folder is unused) and pair again.")
        }
        return
    }
    fmt.Println("🔐 Database initialized with encryption")
    
    // Initialize WhatsApp client
    if err := initClient(); err != nil {
        fmt.Printf("❌ Client error: %v\n", err)
        return
    }
    
    // Load encrypted data files
    loadMessages()
    loadRawMedia()
    loadChatSettings()
    loadKnownChannels()
    loadPrefs()
    validateStoredPaths()
    loadContactsFromDisk()
    loadAvatarsFromDisk()
    storesLoaded = true
    // Daemon-Fruehausstieg VOR dem WhatsApp-Connect: eine enabled Unit
    // startet bei jedem Login - sind Benachrichtigungen aus, darf der
    // Daemon dabei keine Sekunde Praesenz zeigen (vorher fing ihn erst
    // der 30s-Watchdog, mit aufgebauter Verbindung)
    if isDaemon {
        prefsMutex.RLock()
        notif := prefs["notifications"] == "1"
        prefsMutex.RUnlock()
        if !notif {
            fmt.Println("🔔 daemon exiting before connect: notifications disabled")
            os.Exit(0)
        }
    }

    if client.Store.ID == nil {
        fmt.Println("📱 No device ID - need to pair")
        connState = "waiting_for_pair"
    } else {
        fmt.Println("📱 Device ID found, connecting...")
        connState = "connecting"
    }
    connectWithGuard("startup")
    go watchNetwork()
    go connectionWatchdog()


    http.HandleFunc("/pair", func(w http.ResponseWriter, r *http.Request) {
        if client == nil {
            http.Error(w, "backend still starting, try again in a moment", 503)
            return
        }
        phone := r.URL.Query().Get("phone")
        if phone == "" {
            http.Error(w, "phone required", 400)
            return
        }
        for i := 0; i < 30; i++ {
            if client.IsConnected() {
                break
            }
            time.Sleep(500 * time.Millisecond)
        }
        if !client.IsConnected() {
            http.Error(w, "not connected to WhatsApp servers", 500)
            return
        }
        code, err := client.PairPhone(ctx, phone, true, whatsmeow.PairClientChrome, "Chrome (Linux)")
        if err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
        pairCode = code
        fmt.Printf("📱 Pairing code: %s\n", code)
        w.Header().Set("Content-Type", "application/json")
        json.NewEncoder(w).Encode(map[string]string{"code": code})
    })

    http.HandleFunc("/logout", func(w http.ResponseWriter, r *http.Request) {
        fmt.Println("🚪 Logging out...")
        client.Disconnect()
        if client.Store.ID != nil {
            client.Logout(ctx)
        }
        isConnected = false
        pairCode = ""
        
        msgMutex.Lock()
        messages = []Message{}
        msgMutex.Unlock()
        bumpEvent()
        
        contactsMutex.Lock()
        contacts = make(map[string]string)
        contactsMutex.Unlock()
        
        avatarsMutex.Lock()
        avatars = make(map[string]string)
        avatarsMutex.Unlock()
        
        ClearAllSecrets()
        
        os.Remove("wa.db")
        os.Remove("wa.db-shm")
        os.Remove("wa.db-wal")
        os.Remove(messagesFile)
        os.Remove(contactsFile)
        os.Remove(rawMediaFile)
        os.Remove(avatarsFile)
        os.RemoveAll(avatarsDir)
        os.MkdirAll(avatarsDir, 0755)
        
        fmt.Println("✅ Logged out successfully")
        w.Write([]byte("ok"))
        
        go func() {
            time.Sleep(time.Second)
            
            encryptionKey, _ = RegenerateKey()
            
            if err := initDatabase(); err != nil {
                fmt.Printf("❌ Database reinit error: %v\n", err)
                return
            }
            
            if err := initClient(); err != nil {
                fmt.Printf("❌ Client reinit error: %v\n", err)
                return
            }
            
            connectWithGuard("re-pair")
            fmt.Println("📱 Ready for new pairing")
        }()
    })

    http.HandleFunc("/chats/read-all", func(w http.ResponseWriter, r *http.Request) {
        now := time.Now().Unix()
        n := 0
        for _, c := range getChats() {
            if c.Unread == 0 {
                continue
            }
            cs := getChatSettings(c.JID)
            chatSettingsMutex.Lock()
            cs.LastOpened = now
            chatSettingsMutex.Unlock()
            n++
        }
        saveChatSettings()
        fmt.Printf("📖 marked %d chats as read\n", n)
        fmt.Fprintf(w, "ok (%d chats)", n)
    })

    http.HandleFunc("/ui/state", func(w http.ResponseWriter, r *http.Request) {
        uiStateMutex.Lock()
        wasActive := uiActive
        uiActive = r.URL.Query().Get("active") == "1"
        nowActive := uiActive
        uiLastSeen = time.Now()
        uiStateMutex.Unlock()
        // App kam in den Vordergrund: Ereignisansicht aufraeumen
        if nowActive && !wasActive {
            go clearAllNotifications()
        }
        w.Write([]byte("ok"))
    })

    http.HandleFunc("/chat/opened", func(w http.ResponseWriter, r *http.Request) {
        chat := r.URL.Query().Get("chat")
        if chat == "" {
            http.Error(w, "chat required", 400)
            return
        }
        cs := getChatSettings(chat)
        chatSettingsMutex.Lock()
        cs.LastOpened = time.Now().Unix()
        chatSettingsMutex.Unlock()
        saveChatSettings()
        clearNotification(chat)
        // Ohne bump erfaehrt die Long-Polling-UI nicht, dass der
        // Ungelesen-Zaehler geloescht wurde - er blieb stehen, bis
        // zufaellig ein anderes Ereignis kam (oder das 60-s-Netz)
        bumpEvent()
        w.Write([]byte("ok"))
    })

    http.HandleFunc("/chats", func(w http.ResponseWriter, r *http.Request) {
        uiStateMutex.Lock()
        uiLastSeen = time.Now()
        uiStateMutex.Unlock()
        w.Header().Set("Content-Type", "application/json")
        json.NewEncoder(w).Encode(getChats())
    })

    http.HandleFunc("/contacts", func(w http.ResponseWriter, r *http.Request) {
        w.Header().Set("Content-Type", "application/json")
        contactsMutex.RLock()
        json.NewEncoder(w).Encode(contacts)
        contactsMutex.RUnlock()
    })

    http.HandleFunc("/avatar/", func(w http.ResponseWriter, r *http.Request) {
        jid := strings.TrimPrefix(r.URL.Path, "/avatar/")
        if jid == "" {
            http.Error(w, "jid required", 400)
            return
        }
        path := getAvatar(jid)
        if path == "" {
            path = downloadAvatar(jid)
        }
        if path != "" {
            http.ServeFile(w, r, path)
        } else {
            http.Error(w, "not found", 404)
        }
    })

    http.HandleFunc("/events", func(w http.ResponseWriter, r *http.Request) {
        since, _ := strconv.ParseInt(r.URL.Query().Get("since"), 10, 64)
        deadline := time.NewTimer(25 * time.Second)
        defer deadline.Stop()
        for {
            evMu.Lock()
            cur := evSeq
            ch := evCh
            evMu.Unlock()
            if cur != since {
                w.Header().Set("Content-Type", "application/json")
                fmt.Fprintf(w, `{"seq":%d}`, cur)
                return
            }
            select {
            case <-ch:
            case <-deadline.C:
                w.Header().Set("Content-Type", "application/json")
                fmt.Fprintf(w, `{"seq":%d}`, cur)
                return
            case <-r.Context().Done():
                return
            }
        }
    })

    http.HandleFunc("/messages", func(w http.ResponseWriter, r *http.Request) {
        jid := r.URL.Query().Get("jid")
        w.Header().Set("Content-Type", "application/json")
        if jid != "" {
            json.NewEncoder(w).Encode(annotateSenders(getMessagesForChat(jid)))
        } else {
            msgMutex.RLock()
            json.NewEncoder(w).Encode(messages)
            msgMutex.RUnlock()
        }
    })

    // Eigenen Status loeschen (Revoke, wie "fuer alle loeschen")
    http.HandleFunc("/status/delete", func(w http.ResponseWriter, r *http.Request) {
        id := r.URL.Query().Get("id")
        if id == "" {
            http.Error(w, "id required", 400)
            return
        }
        revoke := client.BuildRevoke(types.StatusBroadcastJID, types.EmptyJID, id)
        if _, err := client.SendMessage(context.Background(), types.StatusBroadcastJID, revoke); err != nil {
            fmt.Printf("📸 Status delete failed: %v\n", err)
            http.Error(w, err.Error(), 500)
            return
        }
        fmt.Printf("📸 Status deleted (id=%s)\n", id)
        updateMessage("status", id, func(m *Message) {
            m.Revoked = true
            m.Text = ""
            m.MediaType = ""
            m.LocalPath = ""
        })
        json.NewEncoder(w).Encode(map[string]bool{"ok": true})
    })

    // Eigenen Text-Status posten. WhatsApp verteilt ihn serverseitig
    // gemaess der Status-Privatsphaere des Kontos (wie vom Telefon aus).
    http.HandleFunc("/status/post", func(w http.ResponseWriter, r *http.Request) {
        text := r.URL.Query().Get("text")
        if text == "" {
            http.Error(w, "text required", 400)
            return
        }
        bg := uint32(0xFF075E54) // WhatsApp-Gruen als Standard-Hintergrund
        if bgHex := r.URL.Query().Get("bg"); bgHex != "" {
            if v, perr := strconv.ParseUint(bgHex, 16, 32); perr == nil {
                bg = uint32(v)
            }
        }
        fg := uint32(0xFFFFFFFF)
        font := waE2E.ExtendedTextMessage_SYSTEM
        msg := &waE2E.Message{
            ExtendedTextMessage: &waE2E.ExtendedTextMessage{
                Text:           &text,
                BackgroundArgb: &bg,
                TextArgb:       &fg,
                Font:           &font,
            },
        }
        resp, err := client.SendMessage(context.Background(), types.StatusBroadcastJID, msg)
        if err != nil {
            fmt.Printf("📸 Status post failed: %v\n", err)
            http.Error(w, err.Error(), 500)
            return
        }
        fmt.Printf("📸 Status posted (id=%s)\n", resp.ID)
        // Lokal ablegen, damit er sofort im eigenen Feed erscheint
        addMessage(Message{
            ID:        resp.ID,
            ChatJID:   "status",
            Sender:    client.Store.ID.User,
            Text:      text,
            Timestamp: resp.Timestamp.Unix(),
            FromMe:    true,
        })
        json.NewEncoder(w).Encode(map[string]interface{}{"ok": true, "id": resp.ID})
    })

    http.HandleFunc("/send", func(w http.ResponseWriter, r *http.Request) {
        to := r.URL.Query().Get("to")
        text := r.URL.Query().Get("text")
        if to == "" || text == "" {
            http.Error(w, "to and text required", 400)
            return
        }
        var jid types.JID
        if len(to) > 15 {
            jid = types.NewJID(to, "g.us")
        } else {
            jid = types.NewJID(to, "s.whatsapp.net")
        }
        quoteID := r.URL.Query().Get("quoteId")
        quoteSender := r.URL.Query().Get("quoteSender")
        quoteText := r.URL.Query().Get("quoteText")
        mentionsParam := r.URL.Query().Get("mentions") // kommaseparierte Nummern
        ephemeral := getChatEphemeral(to)

        var mentionJIDs []string
        var mentionNums []string
        for _, n := range strings.Split(mentionsParam, ",") {
            if n = strings.TrimSpace(n); n != "" {
                mentionJIDs = append(mentionJIDs, n+"@"+types.DefaultUserServer)
                mentionNums = append(mentionNums, n)
            }
        }

        ci := &waE2E.ContextInfo{}
        needCI := false
        if quoteID != "" {
            participant := quoteSender
            if participant == "" && client.Store.ID != nil {
                participant = client.Store.ID.User
            }
            ci.StanzaID = proto.String(quoteID)
            ci.Participant = proto.String(participant + "@" + types.DefaultUserServer)
            ci.QuotedMessage = &waE2E.Message{Conversation: proto.String(quoteText)}
            needCI = true
        }
        if len(mentionJIDs) > 0 {
            ci.MentionedJID = mentionJIDs
            needCI = true
        }
        if ephemeral > 0 {
            ci.Expiration = proto.Uint32(ephemeral)
            needCI = true
        }
        var msg *waE2E.Message
        if needCI {
            msg = &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{
                Text:        proto.String(text),
                ContextInfo: ci,
            }}
        } else {
            msg = &waE2E.Message{Conversation: proto.String(text)}
        }
        resp, err := client.SendMessage(ctx, jid, msg)
        if err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
        addMessage(Message{
            ID: resp.ID, Sender: client.Store.ID.User, Text: text,
            Timestamp: time.Now().Unix(), FromMe: true, ChatJID: to,
            QuotedID: quoteID, QuotedText: quoteText, QuotedSender: quoteSender,
            Mentions: mentionNums, Ephemeral: ephemeral,
        })
        w.Write([]byte("ok"))
    })

    // Aeltere Nachrichten eines Chats vom Telefon anfordern (On-Demand-
    // History-Sync). Anker ist die aelteste bekannte Nachricht des Chats.
    http.HandleFunc("/history/request", func(w http.ResponseWriter, r *http.Request) {
        chat := r.URL.Query().Get("chat")
        if chat == "" {
            http.Error(w, "chat required", 400)
            return
        }
        var oldest *Message
        msgMutex.RLock()
        for i := range messages {
            if messages[i].ChatJID != chat || messages[i].ID == "" {
                continue
            }
            if oldest == nil || messages[i].Timestamp < oldest.Timestamp {
                m := messages[i]
                oldest = &m
            }
        }
        msgMutex.RUnlock()
        var info *types.MessageInfo
        anchored := oldest != nil
        if anchored {
            info = &types.MessageInfo{
                ID: types.MessageID(oldest.ID),
                MessageSource: types.MessageSource{
                    Chat:     toChatJID(oldest.ChatJID),
                    Sender:   types.NewJID(oldest.Sender, types.DefaultUserServer),
                    IsFromMe: oldest.FromMe,
                },
                Timestamp: time.Unix(oldest.Timestamp, 0),
            }
        } else {
            // Kein Anker (z.B. nach Datenverlust): fabrizierter Cursor
            // "jetzt" - der Zeitstempel ist die eigentliche Blaettermarke
            info = &types.MessageInfo{
                ID: types.MessageID(""),
                MessageSource: types.MessageSource{
                    Chat:     toChatJID(chat),
                    Sender:   *client.Store.ID,
                    IsFromMe: true,
                },
                Timestamp: time.Now(),
            }
        }
        req := client.BuildHistorySyncRequest(info, 100)
        _, err := client.SendMessage(ctx, client.Store.ID.ToNonAD(), req, whatsmeow.SendRequestExtra{Peer: true})
        if err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
        if anchored {
            fmt.Printf("📜 Requested on-demand history for %s (before %s)\n", chat, oldest.ID)
            w.Write([]byte("requested - messages arrive from your phone within seconds (phone must be online)"))
        } else {
            fmt.Printf("📜 Requested on-demand history for %s (no anchor, cursor=now)\n", chat)
            w.Write([]byte("requested without anchor (cursor: now) - if nothing arrives within a minute, send one message in this chat and try again"))
        }
    })

    // ---- Live-Standort teilen: Start/Update/Stop ----
    // WhatsApp-Live-Location ist ein Strom: das Startpaket plus periodische
    // LiveLocationMessages mit steigender SequenceNumber. Empfaenger (auch
    // wir selbst, s. updateLiveLocation) kollabieren nach Absender+Chat.
    type liveShare struct {
        Seq      int64
        Until    time.Time
        MsgID    string
        Started  time.Time
        LastSent time.Time
        LastLat  float64
        LastLon  float64
    }
    liveShares := map[string]*liveShare{}
    var liveSharesMutex sync.Mutex

    sendLive := func(to string, lat, lon float64, seq int64, timeOffset uint32) (string, error) {
        var jid types.JID
        if len(to) > 15 {
            jid = types.NewJID(to, "g.us")
        } else {
            jid = types.NewJID(to, "s.whatsapp.net")
        }
        // Angleichung an offizielle Sender, damit Empfaenger-Clients die
        // Updates in die bestehende Live-Blase kollabieren statt jedes als
        // neue Nachricht zu zeigen: SequenceNumber = Unix-Millis (nicht
        // 1,2,3...), TimeOffset = Sekunden seit Share-Start, KEINE leere
        // Caption mitsenden
        ll := &waE2E.LiveLocationMessage{
            DegreesLatitude:  proto.Float64(lat),
            DegreesLongitude: proto.Float64(lon),
            SequenceNumber:   proto.Int64(seq),
            TimeOffset:       proto.Uint32(timeOffset),
        }
        if eph := getChatEphemeral(to); eph > 0 {
            ll.ContextInfo = &waE2E.ContextInfo{Expiration: proto.Uint32(eph)}
        }
        resp, err := client.SendMessage(ctx, jid, &waE2E.Message{LiveLocationMessage: ll})
        if err != nil {
            return "", err
        }
        return resp.ID, nil
    }

    http.HandleFunc("/live/start", func(w http.ResponseWriter, r *http.Request) {
        to := r.URL.Query().Get("to")
        lat, e1 := strconv.ParseFloat(r.URL.Query().Get("lat"), 64)
        lon, e2 := strconv.ParseFloat(r.URL.Query().Get("lon"), 64)
        minutes, _ := strconv.Atoi(r.URL.Query().Get("minutes"))
        if to == "" || e1 != nil || e2 != nil || minutes <= 0 {
            http.Error(w, "to, lat, lon, minutes required", 400)
            return
        }
        seq := time.Now().UnixMilli()
        id, err := sendLive(to, lat, lon, seq, 0)
        if err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
        now := time.Now()
        liveSharesMutex.Lock()
        liveShares[to] = &liveShare{Seq: seq, Until: now.Add(time.Duration(minutes) * time.Minute),
            MsgID: id, Started: now, LastSent: now, LastLat: lat, LastLon: lon}
        liveSharesMutex.Unlock()
        addMessage(Message{
            ID: id, Sender: client.Store.ID.User, Text: "📍 Live location",
            Timestamp: time.Now().Unix(), FromMe: true, ChatJID: to,
            MediaType: "location", Latitude: lat, Longitude: lon, Live: true,
            Ephemeral: getChatEphemeral(to),
        })
        w.Write([]byte("ok"))
    })

    http.HandleFunc("/live/update", func(w http.ResponseWriter, r *http.Request) {
        to := r.URL.Query().Get("to")
        lat, e1 := strconv.ParseFloat(r.URL.Query().Get("lat"), 64)
        lon, e2 := strconv.ParseFloat(r.URL.Query().Get("lon"), 64)
        if to == "" || e1 != nil || e2 != nil {
            http.Error(w, "to, lat, lon required", 400)
            return
        }
        liveSharesMutex.Lock()
        sh := liveShares[to]
        if sh == nil {
            liveSharesMutex.Unlock()
            http.Error(w, "no active share for this chat", 404)
            return
        }
        if time.Now().After(sh.Until) {
            delete(liveShares, to)
            liveSharesMutex.Unlock()
            http.Error(w, "share expired", 410)
            return
        }
        // Drossel: senden nur bei >=45s Abstand ODER >=75m Bewegung -
        // 20s-GPS-Takt erzeugte sonst Hunderte Nachrichten bei Empfaengern,
        // deren Client die Updates nicht kollabiert
        moved := haversineMeters(sh.LastLat, sh.LastLon, lat, lon)
        if time.Since(sh.LastSent) < 45*time.Second && moved < 75 {
            liveSharesMutex.Unlock()
            // Eigene Blase trotzdem aktualisieren
            updateLiveLocation(to, client.Store.ID.User, lat, lon, time.Now().Unix())
            w.Write([]byte("throttled"))
            return
        }
        seq := time.Now().UnixMilli()
        sh.Seq = seq
        sh.LastSent = time.Now()
        sh.LastLat, sh.LastLon = lat, lon
        offset := uint32(time.Since(sh.Started).Seconds())
        liveSharesMutex.Unlock()
        if _, err := sendLive(to, lat, lon, seq, offset); err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
        fmt.Printf("📍 live update sent to %s (moved %.0fm, offset %ds)\n", to, moved, offset)
        updateLiveLocation(to, client.Store.ID.User, lat, lon, time.Now().Unix())
        w.Write([]byte("ok"))
    })

    http.HandleFunc("/live/stop", func(w http.ResponseWriter, r *http.Request) {
        to := r.URL.Query().Get("to")
        liveSharesMutex.Lock()
        sh := liveShares[to]
        delete(liveShares, to)
        liveSharesMutex.Unlock()
        if sh != nil {
            updateMessage(to, sh.MsgID, func(m *Message) {
                m.Live = false
                m.Text = "📍 Live location ended"
            })
        }
        w.Write([]byte("ok"))
    })

    // Statischen Standort senden
    http.HandleFunc("/send/location", func(w http.ResponseWriter, r *http.Request) {
        to := r.URL.Query().Get("to")
        latS := r.URL.Query().Get("lat")
        lonS := r.URL.Query().Get("lon")
        name := r.URL.Query().Get("name")
        lat, err1 := strconv.ParseFloat(latS, 64)
        lon, err2 := strconv.ParseFloat(lonS, 64)
        if to == "" || err1 != nil || err2 != nil {
            http.Error(w, "to, lat, lon required", 400)
            return
        }
        var jid types.JID
        if len(to) > 15 {
            jid = types.NewJID(to, "g.us")
        } else {
            jid = types.NewJID(to, "s.whatsapp.net")
        }
        loc := &waE2E.LocationMessage{
            DegreesLatitude:  proto.Float64(lat),
            DegreesLongitude: proto.Float64(lon),
        }
        if name != "" {
            loc.Name = proto.String(name)
        }
        if eph := getChatEphemeral(to); eph > 0 {
            loc.ContextInfo = &waE2E.ContextInfo{Expiration: proto.Uint32(eph)}
        }
        resp, err := client.SendMessage(ctx, jid, &waE2E.Message{LocationMessage: loc})
        if err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
        label := name
        if label == "" {
            label = fmt.Sprintf("%.5f, %.5f", lat, lon)
        }
        addMessage(Message{
            ID: resp.ID, Sender: client.Store.ID.User, Text: "📍 " + label,
            Timestamp: time.Now().Unix(), FromMe: true, ChatJID: to,
            MediaType: "location", Latitude: lat, Longitude: lon,
            Ephemeral: getChatEphemeral(to),
        })
        w.Write([]byte("ok"))
    })

    // Weiterleiten: Text 1:1 mit Forwarded-Flag; Medien werden aus der
    // lokalen Datei neu hochgeladen (erscheinen beim Empfaenger als Original)
    http.HandleFunc("/msg/forward", func(w http.ResponseWriter, r *http.Request) {
        to := r.URL.Query().Get("to")
        id := r.URL.Query().Get("id")
        if to == "" || id == "" {
            http.Error(w, "to and id required", 400)
            return
        }
        var src *Message
        msgMutex.RLock()
        for i := range messages {
            if messages[i].ID == id {
                m := messages[i]
                src = &m
                break
            }
        }
        msgMutex.RUnlock()
        if src == nil {
            http.Error(w, "message not found", 404)
            return
        }
        if src.MediaType != "" && src.LocalPath != "" {
            if err := sendMedia(to, src.LocalPath, src.Text); err != nil {
                http.Error(w, err.Error(), 500)
                return
            }
            w.Write([]byte("ok"))
            return
        }
        var jid types.JID
        if len(to) > 15 {
            jid = types.NewJID(to, "g.us")
        } else {
            jid = types.NewJID(to, "s.whatsapp.net")
        }
        fwd := &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{
            Text: proto.String(src.Text),
            ContextInfo: &waE2E.ContextInfo{
                IsForwarded:     proto.Bool(true),
                ForwardingScore: proto.Uint32(1),
            },
        }}
        resp, err := client.SendMessage(ctx, jid, fwd)
        if err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
        addMessage(Message{
            ID: resp.ID, Sender: client.Store.ID.User, Text: src.Text,
            Timestamp: time.Now().Unix(), FromMe: true, ChatJID: to, Forwarded: true,
        })
        w.Write([]byte("ok"))
    })

    // Nachricht im Chat anpinnen/loesen (fuer alle)
    http.HandleFunc("/msg/pin", func(w http.ResponseWriter, r *http.Request) {
        chat := r.URL.Query().Get("chat")
        id := r.URL.Query().Get("id")
        senderNum := r.URL.Query().Get("sender")
        unpin := r.URL.Query().Get("unpin") == "1"
        fromMe := r.URL.Query().Get("fromMe") == "1"
        if chat == "" || id == "" {
            http.Error(w, "chat and id required", 400)
            return
        }
        var jid types.JID
        if len(chat) > 15 {
            jid = types.NewJID(chat, "g.us")
        } else {
            jid = types.NewJID(chat, "s.whatsapp.net")
        }
        pinType := waE2E.PinInChatMessage_PIN_FOR_ALL
        if unpin {
            pinType = waE2E.PinInChatMessage_UNPIN_FOR_ALL
        }
        key := &waCommon.MessageKey{
            RemoteJID: proto.String(jid.String()),
            ID:        proto.String(id),
            FromMe:    proto.Bool(fromMe),
        }
        if jid.Server == types.GroupServer && !fromMe && senderNum != "" {
            key.Participant = proto.String(senderNum + "@" + types.DefaultUserServer)
        }
        pin := &waE2E.Message{PinInChatMessage: &waE2E.PinInChatMessage{
            Key:               key,
            Type:              &pinType,
            SenderTimestampMS: proto.Int64(time.Now().UnixMilli()),
        }}
        if _, err := client.SendMessage(ctx, jid, pin); err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
        setMessagePinned(chat, id, !unpin)
        w.Write([]byte("ok"))
    })

    // Ablaufende Nachrichten fuer einen Chat setzen (0 = aus)
    http.HandleFunc("/chat/disappearing", func(w http.ResponseWriter, r *http.Request) {
        chat := r.URL.Query().Get("jid")
        secsStr := r.URL.Query().Get("seconds")
        secs, _ := strconv.ParseUint(secsStr, 10, 32)
        if chat == "" {
            http.Error(w, "jid required", 400)
            return
        }
        var jid types.JID
        if len(chat) > 15 {
            jid = types.NewJID(chat, "g.us")
        } else {
            jid = types.NewJID(chat, "s.whatsapp.net")
        }
        if err := client.SetDisappearingTimer(ctx, jid, time.Duration(secs)*time.Second, time.Now()); err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
        setChatEphemeral(chat, uint32(secs))
        w.Write([]byte("ok"))
    })

    // Chat leeren (nur lokal): alle Nachrichten + Mediendateien des Chats
    http.HandleFunc("/chat/clear", func(w http.ResponseWriter, r *http.Request) {
        chat := r.URL.Query().Get("jid")
        if chat == "" {
            http.Error(w, "jid required", 400)
            return
        }
        removed := []string{}
        msgMutex.Lock()
        kept := messages[:0]
        for _, m := range messages {
            if m.ChatJID == chat {
                if m.LocalPath != "" {
                    removed = append(removed, m.LocalPath)
                }
                continue
            }
            kept = append(kept, m)
        }
        messages = kept
        msgMutex.Unlock()
        bumpEvent()
        for _, f := range removed {
            os.Remove(f)
        }
        saveMessages()
        w.Write([]byte("ok"))
    })

    // Chat loeschen (lokal): leeren + Einstellungen entfernen
    http.HandleFunc("/chat/delete", func(w http.ResponseWriter, r *http.Request) {
        chat := r.URL.Query().Get("jid")
        if chat == "" {
            http.Error(w, "jid required", 400)
            return
        }
        removed := []string{}
        msgMutex.Lock()
        kept := messages[:0]
        for _, m := range messages {
            if m.ChatJID == chat {
                if m.LocalPath != "" {
                    removed = append(removed, m.LocalPath)
                }
                continue
            }
            kept = append(kept, m)
        }
        messages = kept
        msgMutex.Unlock()
        bumpEvent()
        for _, f := range removed {
            os.Remove(f)
        }
        chatSettingsMutex.Lock()
        delete(chatSettings, chat)
        chatSettingsMutex.Unlock()
        saveMessages()
        saveChatSettings()
        w.Write([]byte("ok"))
    })

    // Gruppenbeschreibung setzen
    http.HandleFunc("/group/desc", func(w http.ResponseWriter, r *http.Request) {
        chat := r.URL.Query().Get("jid")
        text := r.URL.Query().Get("text")
        if chat == "" {
            http.Error(w, "jid required", 400)
            return
        }
        jid := types.NewJID(chat, "g.us")
        if err := client.SetGroupTopic(ctx, jid, "", "", text); err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
        invalidateGroupInfo(chat)
        w.Write([]byte("ok"))
    })

    // Beitrittsanfragen einer Gruppe auflisten
    http.HandleFunc("/group/requests", func(w http.ResponseWriter, r *http.Request) {
        chat := r.URL.Query().Get("jid")
        if chat == "" {
            http.Error(w, "jid required", 400)
            return
        }
        reqs, err := client.GetGroupRequestParticipants(ctx, types.NewJID(chat, "g.us"))
        if err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
        type reqEntry struct {
            Number string `json:"number"`
            Name   string `json:"name"`
            Time   int64  `json:"time"`
        }
        out := []reqEntry{}
        contactsMutex.RLock()
        for _, rq := range reqs {
            num := resolvePN(rq.JID, types.EmptyJID).User
            out = append(out, reqEntry{Number: num, Name: contacts[num], Time: rq.RequestedAt.Unix()})
        }
        contactsMutex.RUnlock()
        w.Header().Set("Content-Type", "application/json")
        json.NewEncoder(w).Encode(out)
    })

    // Beitrittsanfragen genehmigen/ablehnen (numbers kommasepariert)
    http.HandleFunc("/group/requests/update", func(w http.ResponseWriter, r *http.Request) {
        chat := r.URL.Query().Get("jid")
        numbers := r.URL.Query().Get("numbers")
        action := r.URL.Query().Get("action")
        if chat == "" || numbers == "" || (action != "approve" && action != "reject") {
            http.Error(w, "jid, numbers, action=approve|reject required", 400)
            return
        }
        var jids []types.JID
        for _, n := range strings.Split(numbers, ",") {
            if n = strings.TrimSpace(n); n != "" {
                jids = append(jids, types.NewJID(n, types.DefaultUserServer))
            }
        }
        change := whatsmeow.ParticipantChangeApprove
        if action == "reject" {
            change = whatsmeow.ParticipantChangeReject
        }
        if _, err := client.UpdateGroupRequestParticipants(ctx, types.NewJID(chat, "g.us"), jids, change); err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
        w.Write([]byte("ok"))
    })

    // Einer Gruppe per empfangener Einladungsnachricht beitreten
    http.HandleFunc("/group/joininvite", func(w http.ResponseWriter, r *http.Request) {
        id := r.URL.Query().Get("id")
        if id == "" {
            http.Error(w, "id required", 400)
            return
        }
        var src *Message
        msgMutex.RLock()
        for i := range messages {
            if messages[i].ID == id && messages[i].InviteCode != "" {
                m := messages[i]
                src = &m
                break
            }
        }
        msgMutex.RUnlock()
        if src == nil {
            http.Error(w, "invite not found", 404)
            return
        }
        gjid, err := types.ParseJID(src.InviteGroupJID)
        if err != nil {
            http.Error(w, "bad group jid: "+err.Error(), 400)
            return
        }
        inviter := types.NewJID(src.InviteFrom, types.DefaultUserServer)
        if err := client.JoinGroupWithInvite(ctx, gjid, inviter, src.InviteCode, src.InviteExpiration); err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
        w.Write([]byte("ok"))
    })

    http.HandleFunc("/sendmedia", func(w http.ResponseWriter, r *http.Request) {
        if r.Method != "POST" {
            http.Error(w, "POST required", 405)
            return
        }
        to := r.URL.Query().Get("to")
        caption := r.URL.Query().Get("caption")
        filePath := r.URL.Query().Get("file")
        if filePath != "" {
            err := sendMedia(to, filePath, caption)
            if err != nil {
                http.Error(w, err.Error(), 500)
                return
            }
            w.Write([]byte("ok"))
            return
        }
        r.ParseMultipartForm(100 << 20)
        file, header, err := r.FormFile("file")
        if err != nil {
            http.Error(w, "file required", 400)
            return
        }
        defer file.Close()
        tempPath := filepath.Join(documentsDir, "upload_"+header.Filename)
        out, err := os.Create(tempPath)
        if err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
        io.Copy(out, file)
        out.Close()
        err = sendMedia(to, tempPath, caption)
        if err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
        w.Write([]byte("ok"))
    })

    http.HandleFunc("/download", func(w http.ResponseWriter, r *http.Request) {
        msgID := r.URL.Query().Get("id")
        fmt.Printf("⬇️ /download id=%s\n", msgID)
        if msgID == "" {
            http.Error(w, "missing id", 400)
            return
        }
        // Schon vorhanden?
        msgMutex.RLock()
        var target *Message
        for i := range messages {
            if messages[i].ID == msgID {
                target = &messages[i]
                break
            }
        }
        msgMutex.RUnlock()
        if target == nil {
            http.Error(w, "unknown message", 404)
            return
        }
        if target.LocalPath != "" {
            if _, serr := os.Stat(target.LocalPath); serr == nil {
                json.NewEncoder(w).Encode(map[string]string{"path": target.LocalPath})
                return
            }
            // Datei wurde geloescht (Storage-Clear, Dateimanager, Ephemeral-
            // Cleanup) - Pfad verwerfen und unten neu herunterladen
            msgMutex.Lock()
            for i := range messages {
                if messages[i].ID == msgID {
                    messages[i].LocalPath = ""
                    break
                }
            }
            msgMutex.Unlock()
            bumpEvent()
        }
        rawMediaMutex.RLock()
        b64, ok := rawMedia[msgID]
        rawMediaMutex.RUnlock()
        if !ok {
            fmt.Printf("⬇️ /download %s: no raw media key stored\n", msgID)
            http.Error(w, "no media key stored for this message", 404)
            return
        }
        data, err := base64.StdEncoding.DecodeString(b64)
        if err != nil {
            http.Error(w, "corrupt media key", 500)
            return
        }
        var full waE2E.Message
        if err := proto.Unmarshal(data, &full); err != nil {
            http.Error(w, "corrupt media key", 500)
            return
        }
        _, mimeType, fileName, _, _, dl := extractMedia(&full)
        if dl == nil {
            http.Error(w, "not a downloadable message", 500)
            return
        }
        path, err := downloadMedia(msgID, dl, mimeType, fileName)
        if err != nil {
            // Abgelaufen oder an die alte Session gebunden (403 nach einem
            // Re-Pairing!): Telefon um Neu-Upload bitten, Antwort kommt
            // asynchron als events.MediaRetry
            if errors.Is(err, whatsmeow.ErrMediaDownloadFailedWith403) ||
                errors.Is(err, whatsmeow.ErrMediaDownloadFailedWith404) ||
                errors.Is(err, whatsmeow.ErrMediaDownloadFailedWith410) {
                if rerr := requestMediaRetry(target, dl); rerr == nil {
                    w.WriteHeader(202)
                    w.Write([]byte("media expired - requested re-upload from your phone, try again in a moment (phone must be online)"))
                    return
                } else {
                    fmt.Printf("⚠️ media retry request failed for %s: %v\n", msgID, rerr)
                }
            }
            fmt.Printf("⬇️ /download %s: failed: %v\n", msgID, err)
            http.Error(w, fmt.Sprintf("download failed: %v (media may have expired on WhatsApp servers)", err), 502)
            return
        }
        msgMutex.Lock()
        for i := range messages {
            if messages[i].ID == msgID {
                messages[i].LocalPath = path
                break
            }
        }
        msgMutex.Unlock()
        go saveMessages()
        // Ohne bump erfaehrt die Long-Polling-UI nie vom fertigen
        // Download - die Blase blieb beim Platzhalter haengen
        bumpEvent()
        // Medien-Schluessel bewusst behalten: erlaubt erneuten Download,
        // falls die Datei spaeter unzugaenglich wird
        json.NewEncoder(w).Encode(map[string]string{"path": path})
    })

    http.HandleFunc("/react", func(w http.ResponseWriter, r *http.Request) {
        chat := r.URL.Query().Get("chat")
        msgID := r.URL.Query().Get("id")
        sender := r.URL.Query().Get("sender") // Absender der Zielnachricht
        emoji := r.URL.Query().Get("emoji")   // leer = Reaktion entfernen
        if chat == "" || msgID == "" || sender == "" {
            http.Error(w, "chat, id and sender required", 400)
            return
        }
        chatJID := toChatJID(chat)
        senderJID := types.NewJID(sender, types.DefaultUserServer)
        _, err := client.SendMessage(ctx, chatJID, client.BuildReaction(chatJID, senderJID, types.MessageID(msgID), emoji))
        if err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
        me := client.Store.ID.User
        updateMessage(chat, msgID, func(m *Message) {
            if m.Reactions == nil {
                m.Reactions = make(map[string]string)
            }
            if emoji == "" {
                delete(m.Reactions, me)
            } else {
                m.Reactions[me] = emoji
            }
        })
        w.Write([]byte("ok"))
    })

    http.HandleFunc("/revoke", func(w http.ResponseWriter, r *http.Request) {
        chat := r.URL.Query().Get("chat")
        msgID := r.URL.Query().Get("id")
        if chat == "" || msgID == "" {
            http.Error(w, "chat and id required", 400)
            return
        }
        chatJID := toChatJID(chat)
        _, err := client.SendMessage(ctx, chatJID, client.BuildRevoke(chatJID, types.EmptyJID, types.MessageID(msgID)))
        if err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
        updateMessage(chat, msgID, func(m *Message) {
            m.Revoked = true
            m.Text = "🚫 This message was deleted"
            m.MediaType = ""
            m.LocalPath = ""
        })
        w.Write([]byte("ok"))
    })

    http.HandleFunc("/edit", func(w http.ResponseWriter, r *http.Request) {
        chat := r.URL.Query().Get("chat")
        msgID := r.URL.Query().Get("id")
        text := r.URL.Query().Get("text")
        if chat == "" || msgID == "" || text == "" {
            http.Error(w, "chat, id and text required", 400)
            return
        }
        chatJID := toChatJID(chat)
        _, err := client.SendMessage(ctx, chatJID, client.BuildEdit(chatJID, types.MessageID(msgID), &waE2E.Message{Conversation: proto.String(text)}))
        if err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
        updateMessage(chat, msgID, func(m *Message) {
            m.Text = text
            m.Edited = true
        })
        w.Write([]byte("ok"))
    })

    http.HandleFunc("/profile", func(w http.ResponseWriter, r *http.Request) {
        name := ""
        if client != nil && client.Store != nil {
            name = client.Store.PushName
        }
        about := ""
        avatar := ""
        if client != nil && client.Store.ID != nil {
            own := types.NewJID(client.Store.ID.User, types.DefaultUserServer)
            if info, err := client.GetUserInfo(ctx, []types.JID{own}); err == nil {
                if ui, ok := info[own]; ok {
                    about = ui.Status
                }
            }
            // Eigenes Profilbild holen (CDN-URL, unverschluesselt)
            if pp, err := client.GetProfilePictureInfo(ctx, own, nil); err == nil && pp != nil && pp.URL != "" {
                if resp, err := http.Get(pp.URL); err == nil {
                    defer resp.Body.Close()
                    if data, err := io.ReadAll(resp.Body); err == nil && len(data) > 0 {
                        p := filepath.Join(avatarsDir, "own_profile_"+pp.ID+".jpg")
                        if err := os.WriteFile(p, data, 0644); err == nil {
                            avatar = p
                        }
                    }
                }
            }
        }
        json.NewEncoder(w).Encode(map[string]string{"name": name, "about": about, "avatar": avatar})
    })

    http.HandleFunc("/userinfo", func(w http.ResponseWriter, r *http.Request) {
        // Kontakt-Info fuer die Profilseite: About-Text bei Kontakten,
        // Topic und Mitgliederzahl bei Gruppen
        jid := r.URL.Query().Get("jid")
        if jid == "" || client == nil || !client.IsConnected() {
            http.Error(w, "unavailable", 503)
            return
        }
        out := map[string]interface{}{}
        if len(jid) > 15 {
            gj := types.NewJID(jid, "g.us")
            if gi, err := client.GetGroupInfo(ctx, gj); err == nil && gi != nil {
                out["topic"] = gi.Topic
                out["participants"] = len(gi.Participants)
            }
        } else {
            uj := types.NewJID(jid, "s.whatsapp.net")
            if infos, err := client.GetUserInfo(ctx, []types.JID{uj}); err == nil {
                if ui, ok := infos[uj]; ok {
                    out["status"] = ui.Status
                }
            }
        }
        json.NewEncoder(w).Encode(out)
    })

    http.HandleFunc("/prefs", func(w http.ResponseWriter, r *http.Request) {
        if !storesLoaded {
            // Vor dem Laden wuerde eine leere Map geliefert und die UI
            // fiele auf Defaults zurueck ("Wi-Fi only" statt gespeichertem
            // Wert) - 503 laesst die UI kurz spaeter erneut fragen
            http.Error(w, "starting", 503)
            return
        }
        prefsMutex.RLock()
        defer prefsMutex.RUnlock()
        json.NewEncoder(w).Encode(prefs)
    })

    http.HandleFunc("/prefs/set", func(w http.ResponseWriter, r *http.Request) {
        if !storesLoaded {
            // Ein Save vor dem Laden wuerde prefs.enc mit einer
            // Ein-Eintrag-Map ueberschreiben und alle anderen
            // Einstellungen verlieren
            http.Error(w, "starting", 503)
            return
        }
        key := r.URL.Query().Get("key")
        value := r.URL.Query().Get("value")
        if key == "" {
            http.Error(w, "key required", 400)
            return
        }
        prefsMutex.Lock()
        prefs[key] = value
        prefsMutex.Unlock()
        prefsMutex.RLock()
        SaveEncrypted(prefsFile, prefs)
        prefsMutex.RUnlock()
        w.Write([]byte("ok"))
    })

    http.HandleFunc("/setprofile", func(w http.ResponseWriter, r *http.Request) {
        name := r.URL.Query().Get("name")
        about := r.URL.Query().Get("about")
        hasAbout := r.URL.Query().Get("hasAbout") == "1"
        if name != "" && client.Store.PushName != name {
            if err := client.SendAppState(ctx, appstate.BuildSettingPushName(name)); err != nil {
                http.Error(w, "name: "+err.Error(), 500)
                return
            }
            client.Store.PushName = name
            client.Store.Save(ctx)
        }
        if hasAbout {
            // Seit whatsmeow vom 06.08.2026 nimmt SetStatusMessage eine
            // Struktur statt einer Zeichenkette - der Server versteht dort
            // nun auch Emoji und Ablaufzeit. Wir setzen weiterhin nur den
            // Text; Text ist ein Zeiger, damit "leer setzen" von "nicht
            // aendern" unterscheidbar bleibt.
            if err := client.SetStatusMessage(ctx, types.SetStatusInput{Text: &about}); err != nil {
                http.Error(w, "about: "+err.Error(), 500)
                return
            }
        }
        w.Write([]byte("ok"))
    })

    http.HandleFunc("/setphoto", func(w http.ResponseWriter, r *http.Request) {
        filePath := r.URL.Query().Get("file")
        if filePath == "" {
            http.Error(w, "file required", 400)
            return
        }
        data, err := os.ReadFile(filePath)
        if err != nil {
            http.Error(w, err.Error(), 400)
            return
        }
        // WhatsApp erwartet JPEG: dekodieren (jpg/png/gif) und re-enkodieren
        img, _, err := image.Decode(bytes.NewReader(data))
        if err != nil {
            http.Error(w, "unsupported image: "+err.Error(), 400)
            return
        }
        var buf bytes.Buffer
        if err := jpeg.Encode(&buf, img, &jpeg.Options{Quality: 85}); err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
        if _, err := client.SetGroupPhoto(ctx, types.EmptyJID, buf.Bytes()); err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
        w.Write([]byte("ok"))
    })

    // Aeltere Nachrichten vom Telefon anfordern (ON_DEMAND HistorySync)
    http.HandleFunc("/loadolder", func(w http.ResponseWriter, r *http.Request) {
        chat := r.URL.Query().Get("chat")
        if chat == "" {
            http.Error(w, "chat required", 400)
            return
        }
        // aelteste bekannte Nachricht dieses Chats suchen
        msgMutex.RLock()
        var oldest *Message
        for i := range messages {
            if messages[i].ChatJID != chat {
                continue
            }
            if oldest == nil || messages[i].Timestamp < oldest.Timestamp {
                oldest = &messages[i]
            }
        }
        msgMutex.RUnlock()
        if oldest == nil {
            http.Error(w, "no known messages in this chat yet", 404)
            return
        }
        info := &types.MessageInfo{
            ID:        types.MessageID(oldest.ID),
            Timestamp: time.Unix(oldest.Timestamp, 0),
            MessageSource: types.MessageSource{
                Chat:     toChatJID(chat),
                IsFromMe: oldest.FromMe,
            },
        }
        req := client.BuildHistorySyncRequest(info, 50)
        if _, err := client.SendMessage(ctx, client.Store.ID.ToNonAD(), req, whatsmeow.SendRequestExtra{Peer: true}); err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
        w.Write([]byte("requested 50 older messages from your phone - they will appear shortly (phone must be online)"))
    })

    // Kontakt blockieren/entblocken
    http.HandleFunc("/block", func(w http.ResponseWriter, r *http.Request) {
        jidStr := r.URL.Query().Get("jid")
        action := r.URL.Query().Get("action") // block | unblock
        if jidStr == "" || (action != "block" && action != "unblock") {
            http.Error(w, "jid and action=block|unblock required", 400)
            return
        }
        act := events.BlocklistChangeActionBlock
        if action == "unblock" {
            act = events.BlocklistChangeActionUnblock
        }
        if _, err := client.UpdateBlocklist(ctx, types.NewJID(jidStr, types.DefaultUserServer), act); err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
        w.Write([]byte("ok"))
    })

    // Pin / Mute / Archive (Server-Sync per AppState + lokale Anzeige)
    http.HandleFunc("/chatsetting", func(w http.ResponseWriter, r *http.Request) {
        chat := r.URL.Query().Get("chat")
        action := r.URL.Query().Get("action")
        if chat == "" || action == "" {
            http.Error(w, "chat and action required", 400)
            return
        }
        jid := toChatJID(chat)
        var patch appstate.PatchInfo
        cs := getChatSettings(chat)
        switch action {
        case "pin":
            patch = appstate.BuildPin(jid, true)
            cs.Pinned = true
        case "unpin":
            patch = appstate.BuildPin(jid, false)
            cs.Pinned = false
        case "mute":
            patch = appstate.BuildMute(jid, true, 0) // 0 = dauerhaft
            cs.Muted = true
        case "unmute":
            patch = appstate.BuildMute(jid, false, 0)
            cs.Muted = false
        case "archive":
            patch = appstate.BuildArchive(jid, true, time.Time{}, nil)
            cs.Archived = true
        case "unarchive":
            patch = appstate.BuildArchive(jid, false, time.Time{}, nil)
            cs.Archived = false
        default:
            http.Error(w, "unknown action", 400)
            return
        }
        // Lokal-first: Der lokale Zustand ist bereits gesetzt und wird
        // JETZT synchron persistiert - vorher konnte ein fehlgeschlagener
        // App-State-Sync (z.B. kurz nach frischem Pairing) per early
        // return das Speichern verhindern: UI zeigte den Pin aus dem
        // Speicher, nach Neustart war er weg (Nutzerbericht).
        saveChatSettings()
        if err := client.SendAppState(ctx, patch); err != nil {
            fmt.Printf("⚠️ app state sync for %s/%s failed (kept locally): %v\n", chat, action, err)
            w.Write([]byte("ok (local only - server sync failed)"))
            return
        }
        w.Write([]byte("ok"))
    })

    // Gruppen: erstellen / verlassen / umbenennen / Foto / Invite-Link / Teilnehmer
    http.HandleFunc("/group/create", func(w http.ResponseWriter, r *http.Request) {
        name := r.URL.Query().Get("name")
        parts := r.URL.Query().Get("participants") // Kommagetrennte Nummern
        if name == "" || parts == "" {
            http.Error(w, "name and participants required", 400)
            return
        }
        var jids []types.JID
        for _, p := range strings.Split(parts, ",") {
            p = strings.TrimSpace(p)
            if p != "" {
                jids = append(jids, types.NewJID(p, types.DefaultUserServer))
            }
        }
        gi, err := client.CreateGroup(ctx, whatsmeow.ReqCreateGroup{Name: name, Participants: jids})
        if err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
        gjid := gi.JID.ToNonAD().User
        // Gruppenname merken und System-Eintrag anlegen, damit die neue
        // Gruppe sofort in der Chatliste erscheint
        contactsMutex.Lock()
        contacts[gjid] = name
        contactsMutex.Unlock()
        go saveContacts()
        addMessage(Message{
            ID: "groupcreate-" + gjid, Sender: client.Store.ID.User,
            Text: "👥 Group \"" + name + "\" created",
            Timestamp: time.Now().Unix(), FromMe: true, ChatJID: gjid,
        })
        json.NewEncoder(w).Encode(map[string]string{"jid": gjid})
    })

    http.HandleFunc("/group/leave", func(w http.ResponseWriter, r *http.Request) {
        chat := r.URL.Query().Get("chat")
        if err := client.LeaveGroup(ctx, types.NewJID(chat, types.GroupServer)); err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
        invalidateGroupInfo(chat)
        w.Write([]byte("ok"))
    })

    http.HandleFunc("/group/rename", func(w http.ResponseWriter, r *http.Request) {
        chat := r.URL.Query().Get("chat")
        name := r.URL.Query().Get("name")
        if err := client.SetGroupName(ctx, types.NewJID(chat, types.GroupServer), name); err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
        invalidateGroupInfo(chat)
        w.Write([]byte("ok"))
    })

    http.HandleFunc("/group/photo", func(w http.ResponseWriter, r *http.Request) {
        chat := r.URL.Query().Get("chat")
        filePath := r.URL.Query().Get("file")
        data, err := os.ReadFile(filePath)
        if err != nil {
            http.Error(w, err.Error(), 400)
            return
        }
        img, _, err := image.Decode(bytes.NewReader(data))
        if err != nil {
            fmt.Printf("🖼️ group photo decode failed: %v\n", err)
            http.Error(w, "unsupported image: "+err.Error(), 400)
            return
        }
        // WhatsApps Server akzeptiert nur quadratische Baseline-JPEGs bis
        // ~640x640 (die offiziellen Clients croppen/skalieren vor dem
        // Upload; Originalgroessen werden mit not-acceptable abgelehnt)
        img = cropScaleSquare(img, 640)
        var buf bytes.Buffer
        jpeg.Encode(&buf, img, &jpeg.Options{Quality: 82})
        if _, err := client.SetGroupPhoto(ctx, types.NewJID(chat, types.GroupServer), buf.Bytes()); err != nil {
            fmt.Printf("🖼️ SetGroupPhoto failed for %s: %v\n", chat, err)
            http.Error(w, err.Error(), 500)
            return
        }
        fmt.Printf("🖼️ group photo updated for %s (%d bytes)\n", chat, buf.Len())
        invalidateGroupInfo(chat)
        w.Write([]byte("ok"))
    })

    http.HandleFunc("/group/invitelink", func(w http.ResponseWriter, r *http.Request) {
        chat := r.URL.Query().Get("chat")
        link, err := client.GetGroupInviteLink(ctx, types.NewJID(chat, types.GroupServer), false)
        if err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
        json.NewEncoder(w).Encode(map[string]string{"link": link})
    })

    // Kanal-Verzeichnis: gemerkte akzeptierte Input-Varianten
    dirListVariant := -1
    dirSearchVariant := -1
    _ = dirSearchVariant

    // Gruppeninfo-Cache: das UI bekommt sofort die letzte bekannte Antwort,
    // der Server-Roundtrip (bei 80 Teilnehmern spuerbar) laeuft im
    // Hintergrund und aktualisiert den Cache fuer das naechste Oeffnen.
    buildGroupInfoJSON := func(chat string) ([]byte, error) {
        gi, err := client.GetGroupInfo(ctx, types.NewJID(chat, types.GroupServer))
        if err != nil {
            return nil, err
        }
        type P struct {
            Number  string `json:"number"`
            Name    string `json:"name"`
            IsAdmin bool   `json:"isAdmin"`
        }
        var ps []P
        contactsMutex.RLock()
        for _, p := range gi.Participants {
            pn := resolvePN(p.JID, p.PhoneNumber)
            ps = append(ps, P{Number: pn.User, Name: contacts[pn.User], IsAdmin: p.IsAdmin || p.IsSuperAdmin})
        }
        contactsMutex.RUnlock()
        buf, err := json.Marshal(map[string]interface{}{
            "name": gi.Name, "participants": ps,
        })
        if err != nil {
            return nil, err
        }
        groupInfoCacheMutex.Lock()
        groupInfoCache[chat] = groupInfoCacheEntry{JSON: buf, At: time.Now()}
        groupInfoCacheMutex.Unlock()
        return buf, nil
    }

    http.HandleFunc("/group/info", func(w http.ResponseWriter, r *http.Request) {
        chat := r.URL.Query().Get("chat")
        groupInfoCacheMutex.Lock()
        entry, ok := groupInfoCache[chat]
        groupInfoCacheMutex.Unlock()
        if ok {
            // Cache liefern; wenn aelter als 1 Minute, im Hintergrund
            // auffrischen (das UI pollt nicht, sieht es beim naechsten Mal)
            if time.Since(entry.At) > time.Minute {
                go buildGroupInfoJSON(chat)
            }
            w.Header().Set("Content-Type", "application/json")
            w.Write(entry.JSON)
            return
        }
        buf, err := buildGroupInfoJSON(chat)
        if err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
        w.Header().Set("Content-Type", "application/json")
        w.Write(buf)
    })

    http.HandleFunc("/group/info-old-disabled", func(w http.ResponseWriter, r *http.Request) {
        chat := r.URL.Query().Get("chat")
        gi, err := client.GetGroupInfo(ctx, types.NewJID(chat, types.GroupServer))
        if err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
        type P struct {
            Number  string `json:"number"`
            Name    string `json:"name"`
            IsAdmin bool   `json:"isAdmin"`
        }
        var ps []P
        contactsMutex.RLock()
        for _, p := range gi.Participants {
            pn := resolvePN(p.JID, p.PhoneNumber)
            ps = append(ps, P{Number: pn.User, Name: contacts[pn.User], IsAdmin: p.IsAdmin || p.IsSuperAdmin})
        }
        contactsMutex.RUnlock()
        json.NewEncoder(w).Encode(map[string]interface{}{
            "name": gi.Name, "participants": ps,
        })
    })

    http.HandleFunc("/group/participants", func(w http.ResponseWriter, r *http.Request) {
        chat := r.URL.Query().Get("chat")
        action := r.URL.Query().Get("action") // add | remove
        numbers := r.URL.Query().Get("numbers")
        var jids []types.JID
        for _, p := range strings.Split(numbers, ",") {
            p = strings.TrimSpace(p)
            if p != "" {
                jids = append(jids, types.NewJID(p, types.DefaultUserServer))
            }
        }
        var change whatsmeow.ParticipantChange
        switch action {
        case "add":
            change = whatsmeow.ParticipantChangeAdd
        case "remove":
            change = whatsmeow.ParticipantChangeRemove
        case "promote":
            change = whatsmeow.ParticipantChangePromote
        case "demote":
            change = whatsmeow.ParticipantChangeDemote
        default:
            http.Error(w, "action=add|remove|promote|demote required", 400)
            return
        }
        if _, err := client.UpdateGroupParticipants(ctx, types.NewJID(chat, types.GroupServer), jids, change); err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
        invalidateGroupInfo(chat)
        w.Write([]byte("ok"))
    })

    // Abonnierte Kanaele auflisten
    http.HandleFunc("/channels", func(w http.ResponseWriter, r *http.Request) {
        metas, err := client.GetSubscribedNewsletters(ctx)
        if err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
        type C struct {
            JID         string `json:"jid"`
            Name        string `json:"name"`
            Subscribers int    `json:"subscribers"`
        }
        var out []C
        for _, m := range metas {
            out = append(out, C{JID: m.ID.User, Name: m.ThreadMeta.Name.Text, Subscribers: m.ThreadMeta.SubscriberCount})
            markChannel(m.ID.User)
            // Den Namen auch MERKEN: bisher ging er nur an die Kanalseite,
            // und in der Chatliste stand die nackte Kennung - eine
            // 18-stellige Ziffernfolge, an der niemand einen Kanal erkennt
            rememberChannelName(m.ID.User, m.ThreadMeta.Name.Text)
        }
        json.NewEncoder(w).Encode(out)
    })

    // Kanalnachrichten laden (in den Nachrichtenspeicher)
    http.HandleFunc("/channel/messages", func(w http.ResponseWriter, r *http.Request) {
        jidStr := r.URL.Query().Get("jid")
        if jidStr == "" {
            http.Error(w, "jid required", 400)
            return
        }
        n, err := importNewsletterMessages(types.NewJID(jidStr, types.NewsletterServer), 50)
        if err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
        json.NewEncoder(w).Encode(map[string]int{"imported": n})
    })

    // Kanal folgen per Invite-Link (https://whatsapp.com/channel/KEY)
    // Kanal-Verzeichnis: Suche und Empfehlungen (MEX-Query, gleiche
    // GraphQL-Schnittstelle wie die offiziellen Clients)
    http.HandleFunc("/channels/search", func(w http.ResponseWriter, r *http.Request) {
        query := r.URL.Query().Get("query")
        cursor := r.URL.Query().Get("cursor")
        limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
        if limit <= 0 {
            limit = 30
        }
        if limit > 500 {
            limit = 500
        }
        view := "RECOMMENDED"
        if query != "" {
            view = "SEARCH"
        }
        base := func() map[string]any {
            m := map[string]any{"view": view, "limit": limit}
            if query != "" {
                m["search_text"] = query
            }
            return m
        }
        // Der Server beantwortet unvollstaendige Variablen mit einem nackten
        // 400 - also plausible Formen durchprobieren und jede Absage loggen,
        // damit die funktionierende dokumentiert ist
        variants := []map[string]any{}
        v1 := base()
        v1["start_cursor"] = cursor
        v1["filters"] = map[string]any{"country_codes": []string{}}
        variants = append(variants, v1)
        v2 := base()
        v2["start_cursor"] = cursor
        variants = append(variants, v2)
        v3 := base()
        v3["start_cursor"] = cursor
        v3["filters"] = map[string]any{"country_codes": []string{"AT"}}
        variants = append(variants, v3)
        v4 := base()
        v4["filters"] = map[string]any{"country_codes": []string{}}
        variants = append(variants, v4)
        // Suche laeuft NICHT ueber die Listen-doc_id (8 Varianten sauber
        // mit 400 abgelehnt - eigene persistierte Query). Wenn die echte
        // Such-doc_id bekannt ist (.dir-search-docid, aus dem WA-Web-Bundle
        // via DevTools-Quelltextsuche), wird sie mit den wa-js-Feldern
        // benutzt; sonst faellt die Suche direkt auf den lokalen Filter.
        isRateLimit := func(err error) bool {
            return err != nil && (strings.Contains(err.Error(), "429") || strings.Contains(strings.ToLower(err.Error()), "rate"))
        }
        // Such-doc_id aus dem WA-Web-Schema (@vinikjkkj/wa-mex:
        // FetchNewsletterDirectorySearchResults); .dir-search-docid
        // kann sie weiterhin ueberschreiben, falls sie je rotiert
        searchDocID := "26301059626252132"
        if query != "" {
            if b, ferr := os.ReadFile(".dir-search-docid"); ferr == nil && strings.TrimSpace(string(b)) != "" {
                searchDocID = strings.TrimSpace(string(b))
            }
            variants = nil // Listen-Varianten sind fuer die Suche nutzlos
        }
        runCascade := func(vars []map[string]any, remembered *int) (json.RawMessage, error) {
            var raw json.RawMessage
            var err error
            order := make([]int, 0, len(vars))
            if *remembered >= 0 && *remembered < len(vars) {
                order = append(order, *remembered)
            }
            for i := range vars {
                if i != *remembered {
                    order = append(order, i)
                }
            }
            for _, i := range order {
                raw, err = client.DangerousInternals().SendMexIQ(ctx, "6190824427689257", map[string]any{"input": vars[i]})
                if err == nil {
                    if *remembered != i {
                        fmt.Printf("📡 directory variant %d accepted (remembered)\n", i+1)
                    }
                    *remembered = i
                    return raw, nil
                }
                if isRateLimit(err) {
                    // Sofort abbrechen: weitere Varianten wuerden das Limit
                    // nur tiefer ausschoepfen
                    fmt.Printf("📡 rate limited - aborting cascade: %v\n", err)
                    return nil, fmt.Errorf("rate-limited: %w", err)
                }
                fmt.Printf("📡 directory variant %d rejected: %v\n", i+1, err)
            }
            return nil, err
        }
        var raw json.RawMessage
        var err error
        if query != "" && searchDocID != "" {
            // Echte Online-Suche mit nachgeruesteter doc_id: drei plausible
            // Variablen-Formen (wa-js-Parameter in snake_case zuerst)
            // Exakte Variablen-Struktur laut wa-mex-Typdefinition:
            // {fetch_status_metadata?, input:{search_text, categories,
            //  limit, start_cursor}}
            in := map[string]any{"search_text": query, "categories": []string{}, "limit": limit, "start_cursor": cursor}
            sv := []map[string]any{
                {"input": in},
                {"fetch_status_metadata": true, "input": in},
            }
            for i, vars := range sv {
                raw, err = client.DangerousInternals().SendMexIQ(ctx, searchDocID, vars)
                if err == nil {
                    fmt.Printf("📡 search doc_id variant %d accepted\n", i+1)
                    break
                }
                if isRateLimit(err) {
                    break
                }
                fmt.Printf("📡 search doc_id variant %d rejected: %v\n", i+1, err)
            }
        } else if query == "" {
            raw, err = runCascade(variants, &dirListVariant)
        } else {
            err = fmt.Errorf("no search doc id configured")
        }
        localFilter := false
        if err != nil && query != "" {
            // Die Such-Query-ID ist oeffentlich nicht bekannt (auch Baileys
            // kennt keine). Fallback: Empfehlungen ueber DIESELBE Kaskade
            // holen (nicht eine fest verdrahtete Form, die der Server
            // womoeglich genauso ablehnt) und lokal filtern.
            fbBase := func() map[string]any {
                return map[string]any{"view": "RECOMMENDED", "limit": limit}
            }
            f1 := fbBase()
            f1["start_cursor"] = cursor
            f1["filters"] = map[string]any{"country_codes": []string{}}
            f2 := fbBase()
            f2["start_cursor"] = cursor
            f3 := fbBase()
            f3["filters"] = map[string]any{"country_codes": []string{}}
            f4 := fbBase()
            raw, err = runCascade([]map[string]any{f1, f2, f3, f4}, &dirListVariant)
            if err == nil {
                localFilter = true
                fmt.Println("📡 search fell back to locally filtered recommendations")
            }
        }
        if err != nil {
            if isRateLimit(err) {
                http.Error(w, "WhatsApp rate limit reached - wait a minute and try again", 429)
                return
            }
            http.Error(w, "directory query rejected (all variants): "+err.Error(), 502)
            return
        }
        // Antwort defensiv parsen: erstes Feld mit "result"->"newsletters"
        // oder direkt ein Array unter einem xwa2_*-Schluessel
        var top map[string]json.RawMessage
        if err := json.Unmarshal(raw, &top); err != nil {
            http.Error(w, "unexpected directory response", 502)
            return
        }
        type dirEntry struct {
            JID         string `json:"jid"`
            Name        string `json:"name"`
            Description string `json:"description"`
            Subscribers int64  `json:"subscribers"`
            Verified    bool   `json:"verified"`
        }
        out := []dirEntry{}
        var scan func(v json.RawMessage)
        scan = func(v json.RawMessage) {
            var arr []json.RawMessage
            if json.Unmarshal(v, &arr) == nil {
                for _, el := range arr {
                    var nl struct {
                        ID             string `json:"id"`
                        ThreadMetadata struct {
                            Name             struct{ Text string `json:"text"` } `json:"name"`
                            Description      struct{ Text string `json:"text"` } `json:"description"`
                            SubscribersCount string `json:"subscribers_count"`
                            Verification     string `json:"verification"`
                        } `json:"thread_metadata"`
                    }
                    if json.Unmarshal(el, &nl) == nil && nl.ID != "" {
                        subs, _ := strconv.ParseInt(nl.ThreadMetadata.SubscribersCount, 10, 64)
                        out = append(out, dirEntry{
                            JID:         nl.ID,
                            Name:        nl.ThreadMetadata.Name.Text,
                            Description: nl.ThreadMetadata.Description.Text,
                            Subscribers: subs,
                            Verified:    nl.ThreadMetadata.Verification == "VERIFIED",
                        })
                    }
                }
                return
            }
            var obj map[string]json.RawMessage
            if json.Unmarshal(v, &obj) == nil {
                for _, sub := range obj {
                    scan(sub)
                }
            }
        }
        for _, v := range top {
            scan(v)
        }
        nextCursor := ""
        hasNext := false
        var scanCursor func(v json.RawMessage)
        scanCursor = func(v json.RawMessage) {
            var obj map[string]json.RawMessage
            if json.Unmarshal(v, &obj) != nil {
                return
            }
            for k, sub := range obj {
                switch k {
                case "end_cursor", "next_cursor", "start_cursor_next":
                    var cs string
                    if json.Unmarshal(sub, &cs) == nil && cs != "" {
                        nextCursor = cs
                    }
                case "has_next_page":
                    var b bool
                    if json.Unmarshal(sub, &b) == nil && b {
                        hasNext = true
                    }
                default:
                    scanCursor(sub)
                }
            }
        }
        for _, v := range top {
            scanCursor(v)
        }
        if !hasNext {
            // Manche Antworten haben nur end_cursor ohne has_next_page-Flag;
            // dann signalisiert eine volle Seite "mehr vorhanden"
            hasNext = nextCursor != "" && len(out) >= limit
        }
        if localFilter {
            q := strings.ToLower(query)
            filtered := out[:0]
            for _, e := range out {
                if strings.Contains(strings.ToLower(e.Name), q) || strings.Contains(strings.ToLower(e.Description), q) {
                    filtered = append(filtered, e)
                }
            }
            out = filtered
        }
        resp := map[string]any{"results": out, "localFilter": localFilter}
        if hasNext && nextCursor != "" {
            resp["nextCursor"] = nextCursor
        }
        fmt.Printf("📡 Channel directory: query=%q cursor=%q -> %d results (localFilter=%v, next=%v)\n", query, cursor, len(out), localFilter, hasNext)
        w.Header().Set("Content-Type", "application/json")
        json.NewEncoder(w).Encode(resp)
    })

    http.HandleFunc("/channel/follow", func(w http.ResponseWriter, r *http.Request) {
        if j := r.URL.Query().Get("jid"); j != "" {
            njid, err := types.ParseJID(j)
            if err != nil {
                http.Error(w, "bad jid: "+err.Error(), 400)
                return
            }
            if err := client.FollowNewsletter(ctx, njid); err != nil {
                http.Error(w, err.Error(), 500)
                return
            }
            markChannel(njid.User)
            importNewsletterMessages(njid, 50)
            w.Write([]byte("ok"))
            return
        }
        link := r.URL.Query().Get("link")
        key := link
        if idx := strings.LastIndex(link, "/channel/"); idx >= 0 {
            key = link[idx+len("/channel/"):]
        }
        key = strings.TrimSpace(strings.Trim(key, "/"))
        if key == "" {
            http.Error(w, "link required", 400)
            return
        }
        meta, err := client.GetNewsletterInfoWithInvite(ctx, key)
        if err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
        if err := client.FollowNewsletter(ctx, meta.ID); err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
        importNewsletterMessages(meta.ID, 50)
        json.NewEncoder(w).Encode(map[string]string{"jid": meta.ID.User, "name": meta.ThreadMeta.Name.Text})
    })

    http.HandleFunc("/channel/unfollow", func(w http.ResponseWriter, r *http.Request) {
        jidStr := r.URL.Query().Get("jid")
        if err := client.UnfollowNewsletter(ctx, types.NewJID(jidStr, types.NewsletterServer)); err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
        w.Write([]byte("ok"))
    })

    // Gruppe per Invite-Link beitreten (https://chat.whatsapp.com/CODE)
    http.HandleFunc("/group/join", func(w http.ResponseWriter, r *http.Request) {
        link := r.URL.Query().Get("link")
        code := link
        if idx := strings.LastIndex(link, "/"); idx >= 0 {
            code = link[idx+1:]
        }
        code = strings.TrimSpace(code)
        if code == "" {
            http.Error(w, "link required", 400)
            return
        }
        jid, err := client.JoinGroupWithLink(ctx, code)
        if err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
        json.NewEncoder(w).Encode(map[string]string{"jid": jid.User})
    })

    // Community: verknuepfte Untergruppen
    http.HandleFunc("/group/subgroups", func(w http.ResponseWriter, r *http.Request) {
        chat := r.URL.Query().Get("chat")
        subs, err := client.GetSubGroups(ctx, types.NewJID(chat, types.GroupServer))
        if err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
        type G struct {
            JID  string `json:"jid"`
            Name string `json:"name"`
        }
        var out []G
        for _, g := range subs {
            out = append(out, G{JID: g.JID.User, Name: g.Name})
        }
        json.NewEncoder(w).Encode(out)
    })

    // Volltextsuche ueber Nachrichten und Chatnamen
    http.HandleFunc("/search", func(w http.ResponseWriter, r *http.Request) {
        q := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("q")))
        chatFilter := r.URL.Query().Get("chat")
        if len(q) < 2 {
            http.Error(w, "query too short", 400)
            return
        }
        type Hit struct {
            ChatJID   string `json:"chatJid"`
            ChatName  string `json:"chatName"`
            MsgID     string `json:"msgId,omitempty"`
            Snippet   string `json:"snippet"`
            Timestamp int64  `json:"timestamp"`
            Kind      string `json:"kind"` // chat | message
        }
        var hits []Hit
        seenChats := make(map[string]bool)

        // Chats, deren Name passt (nur ohne Chat-Filter)
        for _, c := range getChats() {
            if chatFilter != "" {
                break
            }
            if strings.Contains(strings.ToLower(c.Name), q) || strings.Contains(c.JID, q) {
                hits = append(hits, Hit{ChatJID: c.JID, ChatName: c.Name,
                    Snippet: c.LastMessage, Timestamp: c.LastTime, Kind: "chat"})
                seenChats[c.JID] = true
            }
        }

        // Nachrichten, deren Text passt (neueste zuerst, max 50)
        msgMutex.RLock()
        for i := len(messages) - 1; i >= 0 && len(hits) < 60; i-- {
            m := &messages[i]
            if m.Revoked || m.Text == "" {
                continue
            }
            if chatFilter != "" && m.ChatJID != chatFilter {
                continue
            }
            if !strings.Contains(strings.ToLower(m.Text), q) {
                continue
            }
            snippet := m.Text
            if idx := strings.Index(strings.ToLower(snippet), q); idx > 40 {
                snippet = "…" + snippet[idx-30:]
            }
            if len(snippet) > 140 {
                snippet = snippet[:140] + "…"
            }
            hits = append(hits, Hit{ChatJID: m.ChatJID, ChatName: getContactName(m.ChatJID),
                MsgID: m.ID, Snippet: snippet, Timestamp: m.Timestamp, Kind: "message"})
        }
        msgMutex.RUnlock()

        sort.Slice(hits, func(i, j int) bool {
            if hits[i].Kind != hits[j].Kind {
                return hits[i].Kind == "chat" // Chat-Treffer zuerst
            }
            return hits[i].Timestamp > hits[j].Timestamp
        })
        if len(hits) > 50 {
            hits = hits[:50]
        }
        json.NewEncoder(w).Encode(hits)
    })

    http.HandleFunc("/send/voice", func(w http.ResponseWriter, r *http.Request) {
        to := r.URL.Query().Get("to")
        file := r.URL.Query().Get("file")
        secs, _ := strconv.Atoi(r.URL.Query().Get("seconds"))
        if to == "" || file == "" {
            http.Error(w, "to and file required", 400)
            return
        }
        if err := sendVoice(to, file, uint32(secs)); err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
        w.Write([]byte("ok"))
    })

    http.HandleFunc("/permcheck", func(w http.ResponseWriter, r *http.Request) {
        data, err := os.ReadFile("/usr/share/applications/harbour-whatsapp.desktop")
        d := string(data)
        contacts := err == nil && strings.Contains(d, "Contacts;") && strings.Contains(d, "Privileged;")
        // Die drei Medien-Marken EINZELN melden. Frueher gab es nur ein
        // gemeinsames Ja/Nein - ein Teil-Grant (etwa ohne RemovableMedia,
        // also ohne SD-Karte) sah dadurch aus wie "gar nichts erteilt",
        // und wer den Befehl schon ausgefuehrt hatte, suchte den Fehler
        // anderswo. Der GRANT-Befehl haengt nur Fehlendes an, ein zweiter
        // Lauf ist also gefahrlos - das muss die App aber auch sagen.
        var mediaMissing []string
        for _, want := range []string{"UserDirs", "MediaIndexing", "RemovableMedia"} {
            if err != nil || !strings.Contains(d, want+";") {
                mediaMissing = append(mediaMissing, want)
            }
        }
        if mediaMissing == nil {
            mediaMissing = []string{}
        }
        media := len(mediaMissing) == 0
        location := err == nil && strings.Contains(d, "Location;")
        mic := err == nil && strings.Contains(d, "Microphone;")
        sensors := err == nil && strings.Contains(d, "Sensors;")
        audio := err == nil && strings.Contains(d, ";Audio;")
        json.NewEncoder(w).Encode(map[string]interface{}{
            "contactsPermission": contacts, "mediaPermission": media,
            "locationPermission": location, "micPermission": mic,
            "sensorsPermission": sensors, "audioPermission": audio,
            "mediaMissing": mediaMissing,
            // Was in der Datei steht, ist nicht, was der Prozess darf:
            // sailjail wendet das Profil beim START an. Wer gerade erteilt
            // hat, liest hier sonst "granted" und wundert sich ueber
            // "permission denied" - genau dieser Irrtum kostete Feldzeit
            "mediaAccessEffective": mediaAccessEffective(),
        })
    })

    http.HandleFunc("/storage", func(w http.ResponseWriter, r *http.Request) {
        type Cat struct {
            Bytes int64 `json:"bytes"`
            Files int   `json:"files"`
        }
        dirSize := func(dirs ...string) Cat {
            var c Cat
            seen := make(map[string]bool)
            for _, d := range dirs {
                if d == "" || seen[d] {
                    continue
                }
                seen[d] = true
                filepath.Walk(d, func(p string, info os.FileInfo, err error) error {
                    if err == nil && !info.IsDir() {
                        c.Bytes += info.Size()
                        c.Files++
                    }
                    return nil
                })
            }
            return c
        }
        // Avatare separat, Bilder ohne avatars-Unterordner
        av := dirSize(avatarsDir)
        pics := dirSize(picturesDir)
        pics.Bytes -= av.Bytes
        pics.Files -= av.Files
        if pics.Bytes < 0 {
            pics.Bytes, pics.Files = 0, 0
        }
        json.NewEncoder(w).Encode(map[string]Cat{
            "images":    pics,
            "videos":    dirSize(videosDir),
            "audio":     dirSize(audioDir),
            "documents": dirSize(documentsDir),
            "avatars":   av,
        })
    })

    http.HandleFunc("/storage/clear", func(w http.ResponseWriter, r *http.Request) {
        t := r.URL.Query().Get("type")
        var dirs []string
        var mediaTypes []string
        switch t {
        case "images":
            dirs = []string{picturesDir}
            mediaTypes = []string{"image", "sticker"}
        case "videos":
            dirs = []string{videosDir}
            mediaTypes = []string{"video"}
        case "audio":
            dirs = []string{audioDir}
            mediaTypes = []string{"audio"}
        case "documents":
            dirs = []string{documentsDir}
            mediaTypes = []string{"document"}
        case "avatars":
            dirs = []string{avatarsDir}
        default:
            http.Error(w, "type=images|videos|audio|documents|avatars required", 400)
            return
        }
        removed := 0
        for _, d := range dirs {
            filepath.Walk(d, func(p string, info os.FileInfo, err error) error {
                if err != nil || info.IsDir() {
                    return nil
                }
                if t == "images" && strings.HasPrefix(p, avatarsDir) {
                    return nil // Avatare nicht mit Bildern loeschen
                }
                if os.Remove(p) == nil {
                    removed++
                }
                return nil
            })
        }
        if t == "avatars" {
            avatarsMutex.Lock()
            avatars = make(map[string]string)
            avatarsMutex.Unlock()
            go saveAvatars()
        } else {
            msgMutex.Lock()
            for i := range messages {
                for _, mt := range mediaTypes {
                    if messages[i].MediaType == mt {
                        messages[i].LocalPath = ""
                    }
                }
            }
            msgMutex.Unlock()
            bumpEvent()
            go saveMessages()
        }
        json.NewEncoder(w).Encode(map[string]int{"removed": removed})
    })

    http.HandleFunc("/pollvote", func(w http.ResponseWriter, r *http.Request) {
        chat := r.URL.Query().Get("chat")
        msgID := r.URL.Query().Get("id")
        optsParam := r.URL.Query().Get("options") // ||-getrennt, leer = Stimme zurueckziehen
        if chat == "" || msgID == "" {
            http.Error(w, "chat and id required", 400)
            return
        }
        msgMutex.RLock()
        var target *Message
        for i := range messages {
            if messages[i].ID == msgID && messages[i].ChatJID == chat {
                target = &messages[i]
                break
            }
        }
        msgMutex.RUnlock()
        if target == nil || target.MediaType != "poll" {
            http.Error(w, "unknown poll", 404)
            return
        }
        var selected []string
        if optsParam != "" {
            selected = strings.Split(optsParam, "||")
        }
        pollInfo := &types.MessageInfo{
            ID: types.MessageID(msgID),
            MessageSource: types.MessageSource{
                Chat:     toChatJID(chat),
                Sender:   types.NewJID(target.Sender, types.DefaultUserServer),
                IsFromMe: target.FromMe,
            },
        }
        voteMsg, err := client.BuildPollVote(ctx, pollInfo, selected)
        if err != nil {
            http.Error(w, "cannot vote on this poll: "+err.Error()+" (polls imported from history have no message secret)", 500)
            return
        }
        if _, err := client.SendMessage(ctx, toChatJID(chat), voteMsg); err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
        me := client.Store.ID.User
        updateMessage(chat, msgID, func(m *Message) {
            if m.PollVoters == nil {
                m.PollVoters = make(map[string][]string)
            }
            if len(selected) == 0 {
                delete(m.PollVoters, me)
            } else {
                m.PollVoters[me] = selected
            }
        })
        w.Write([]byte("ok"))
    })

    http.HandleFunc("/poll/create", func(w http.ResponseWriter, r *http.Request) {
        chat := r.URL.Query().Get("chat")
        name := strings.TrimSpace(r.URL.Query().Get("name"))
        optsParam := r.URL.Query().Get("options") // ||-getrennt
        multiple := r.URL.Query().Get("multiple") == "1"
        var options []string
        for _, o := range strings.Split(optsParam, "||") {
            if o = strings.TrimSpace(o); o != "" {
                options = append(options, o)
            }
        }
        if chat == "" || name == "" || len(options) < 2 {
            http.Error(w, "chat, name and at least 2 options required", 400)
            return
        }
        if len(options) > 12 {
            http.Error(w, "at most 12 options", 400)
            return
        }
        selectable := 1
        if multiple {
            selectable = 0 // 0 = beliebig viele
        }
        msg := client.BuildPollCreation(name, options, selectable)
        resp, err := client.SendMessage(ctx, toChatJID(chat), msg)
        if err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
        addMessage(Message{
            ID: resp.ID, Sender: client.Store.ID.User,
            Text: "📊 " + name, Timestamp: time.Now().Unix(),
            FromMe: true, ChatJID: chat, MediaType: "poll",
            PollName: name, PollOptions: options, PollMultiple: multiple,
        })
        w.Write([]byte("ok"))
    })


    http.HandleFunc("/reload", func(w http.ResponseWriter, r *http.Request) {
        loadContacts()
        w.Write([]byte("ok"))
    })

    fmt.Println("✅ Initialization complete")

    // Abgelaufene (ephemere) Nachrichten periodisch lokal entfernen
    go func() {
        for {
            cleanupEphemeral()
            time.Sleep(15 * time.Minute)
        }
    }()

    c := make(chan os.Signal, 1)
    signal.Notify(c, os.Interrupt, syscall.SIGTERM)
    <-c
    saveMessages()
    saveContacts()
    saveAvatars()
    releasePortFile()
    client.Disconnect()
}

// Die Portdatei zeigt nach einem Prozessende sonst auf einen toten Port -
// jeder Leser (App-Neustart, Skript, Daemon) rennt dann gegen eine
// geschlossene Tuer. Nur loeschen, wenn WIR darin stehen: laeuft parallel
// eine zweite Instanz auf einem anderen Port, gehoert der Eintrag ihr.
func releasePortFile() {
    b, err := os.ReadFile("backend.port")
    if err != nil {
        return
    }
    if strings.TrimSpace(string(b)) == fmt.Sprintf("%d", boundPort) {
        os.Remove("backend.port")
    }
}

// nudgeConnect: das Netz ist zurueck - Backoff verwerfen und sofort ran
func nudgeConnect(reason string) {
    consecReconnects = 0
    select {
    case connectWake <- struct{}{}:
    default:
    }
    connectWithGuard(reason)
}

// watchNetwork: connman auf dem System-Bus melden lassen, wenn WLAN,
// mobile Daten oder das Ende des Flugmodus die Verbindung zurueckbringen.
// Die Berechtigung dafuer steckt bereits in Internet.permission, die
// Connman.permission einbindet (talk + broadcast). Faellt das aus, traegt
// der periodische Waechter allein - deshalb hier nur Meldung, kein Abbruch
// der uebrigen Arbeit.
func watchNetwork() {
    conn, err := dbus.SystemBus()
    if err != nil {
        fmt.Printf("⚠ connman: no system bus (%v) - periodic check only\n", err)
        return
    }
    obj := conn.Object("net.connman", "/")
    var props map[string]dbus.Variant
    if cerr := obj.Call("net.connman.Manager.GetProperties", 0).Store(&props); cerr == nil {
        if v, ok := props["State"]; ok {
            if str, ok := v.Value().(string); ok && str != "" {
                netState = str
            }
        }
    } else {
        fmt.Printf("⚠ connman: GetProperties failed (%v)\n", cerr)
    }
    if merr := conn.AddMatchSignal(
        dbus.WithMatchInterface("net.connman.Manager"),
        dbus.WithMatchMember("PropertyChanged"),
    ); merr != nil {
        fmt.Printf("⚠ connman: signal subscription failed (%v) - periodic check only\n", merr)
        return
    }
    ch := make(chan *dbus.Signal, 16)
    conn.Signal(ch)
    fmt.Printf("📶 connman watcher active (state=%s)\n", netState)
    for sig := range ch {
        if sig.Name != "net.connman.Manager.PropertyChanged" || len(sig.Body) < 2 {
            continue
        }
        name, _ := sig.Body[0].(string)
        v, ok := sig.Body[1].(dbus.Variant)
        if !ok {
            continue
        }
        connected := client != nil && client.IsConnected()
        if reason := handleNetworkProperty(name, v.Value(), connected); reason != "" {
            nudgeConnect(reason)
        }
    }
}

// handleNetworkProperty pflegt netState und sagt, ob ein Verbindungsversuch
// faellig ist. Ausgelagert, damit die Fallunterscheidung ohne D-Bus pruefbar
// ist. Rueckgabe "" heisst: nichts zu tun.
func handleNetworkProperty(name string, val interface{}, connected bool) string {
    switch name {
    case "State":
        str, _ := val.(string)
        if str == "" || str == netState {
            return ""
        }
        netState = str
        fmt.Printf("📶 network state: %s\n", str)
        if (str == "ready" || str == "online") && !connected {
            return "network-up"
        }
    case "OfflineMode":
        off, ok := val.(bool)
        if !ok {
            return ""
        }
        fmt.Printf("📶 offline mode: %v\n", off)
        if !off && !connected {
            return "flight-mode-off"
        }
    }
    return ""
}

// connectionWatchdog: Grundsicherung ohne Bus und ohne Berechtigung.
// Sollten wir verbunden sein, sind es aber nicht, wird ueber die Wache ein
// Versuch angestossen; deren Backoff verhindert weiterhin jeden Sturm.
func connectionWatchdog() {
    for {
        time.Sleep(60 * time.Second)
        if client == nil || client.Store == nil || client.Store.ID == nil {
            continue
        }
        if watchdogShouldConnect(connState, client.IsConnected(), netState) {
            connectWithGuard("watchdog")
        }
    }
}

// watchdogShouldConnect: sollten wir verbunden sein, sind es aber nicht?
// Bei bekanntem Funkloch schweigen - "unknown" gilt als "probier es".
func watchdogShouldConnect(state string, connected bool, net string) bool {
    switch state {
    case "logged_out", "relogin_required", "waiting_for_pair", "standby":
        return false
    }
    if connected {
        return false
    }
    if net == "offline" || net == "idle" {
        return false
    }
    return true
}

// redirectDaemonOutput: der Daemon hatte als einziger Teil kein lesbares
// Protokoll. systemd schickt seine Ausgabe ins Journal, das auf dem Geraet
// fluechtig ist (Storage=volatile, RuntimeMaxUse=1M) und dem Nutzer ohne
// Gruppenmitgliedschaft verschlossen bleibt - ausgerechnet die Instanz,
// die unbeaufsichtigt laufen soll, protokollierte ins Nichts.
//
// Getauscht werden die Dateideskriptoren 1 und 2 statt os.Stdout: nur so
// folgt auch whatsmeows eigener Logger, der sich sein Ziel selbst holt.
// Eigene Datei statt backend.log, weil start_backend.py jene beim
// App-Start stutzt und ersetzt - der Daemon schriebe danach in einen
// geloeschten Inode weiter.
func redirectDaemonOutput() {
    if !isDaemon {
        return
    }
    const name = "daemon.log"
    // Beim Start stutzen wie backend.log, sonst waechst es unbegrenzt
    if st, err := os.Stat(name); err == nil && st.Size() > 512*1024 {
        if b, rerr := os.ReadFile(name); rerr == nil && len(b) > 128*1024 {
            os.WriteFile(name, append([]byte("[log trimmed at startup]\n"),
                b[len(b)-128*1024:]...), 0600)
        }
    }
    f, err := os.OpenFile(name, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
    if err != nil {
        fmt.Printf("⚠ daemon log: %v (output stays in the journal)\n", err)
        return
    }
    // Dup3 statt Dup2: auf arm64 gibt es Dup2 nicht
    if err := unix.Dup3(int(f.Fd()), 1, 0); err != nil {
        fmt.Printf("⚠ daemon log: stdout redirect failed: %v\n", err)
        return
    }
    if err := unix.Dup3(int(f.Fd()), 2, 0); err != nil {
        fmt.Printf("⚠ daemon log: stderr redirect failed: %v\n", err)
    }
    fmt.Printf("📝 daemon log opened (%s in %s)\n", name, workDirName())
}

func workDirName() string {
    if d, err := os.Getwd(); err == nil {
        return d
    }
    return "?"
}

// mediaAccessEffective probiert, was das Profil des LAUFENDEN Prozesses
// tatsaechlich hergibt, statt die Desktop-Datei zu lesen. Ohne UserDirs
// sind diese Ordner im Jail nicht zu oeffnen.
func mediaAccessEffective() bool {
    home, err := os.UserHomeDir()
    if err != nil {
        return false
    }
    for _, d := range []string{"Pictures", "Documents", "Videos"} {
        if f, oerr := os.Open(home + "/" + d); oerr == nil {
            f.Close()
            return true
        }
    }
    return false
}

// annotateSenders klaert beim AUSLIEFERN, ob hinter einem Absender eine
// echte Rufnummer steckt. Beim Empfang wird das Kennzeichen bereits gesetzt,
// aber alle frueher gespeicherten Nachrichten haben es nicht - und genau die
// sieht man in der Statusliste. Zwei Stufen:
//
//  1. Nachschlagen: laesst sich der Wert als LID aufloesen, kennen wir die
//     echte Nummer und setzen sie ein. Fuer eine gewoehnliche Rufnummer
//     schlaegt das Nachschlagen einfach fehl, es kostet also nichts.
//  2. Plausibilitaet: bleibt es unklar, entscheidet die Laendervorwahl.
//     LIDs sind 13 bis 15 Ziffern lang und beginnen mit Folgen, die es als
//     Vorwahl nicht gibt (518, 609, 717 ...). Lieber "unbekannt" anzeigen
//     als eine Ziffernfolge, die wie eine fremde Rufnummer aussieht.
func annotateSenders(in []Message) []Message {
    out := make([]Message, len(in))
    copy(out, in)
    for i := range out {
        if out[i].FromMe || out[i].Sender == "" || out[i].SenderIsLid {
            continue
        }
        if client != nil {
            lid := types.JID{User: out[i].Sender, Server: types.HiddenUserServer}
            if pn, err := client.Store.LIDs.GetPNForLID(context.Background(), lid); err == nil && !pn.IsEmpty() {
                out[i].Sender = pn.ToNonAD().User
                continue
            }
        }
        if !plausiblePhoneNumber(out[i].Sender) {
            out[i].SenderIsLid = true
        }
    }
    // Bekannt heisst: wir haben einen Namen dazu. Alles andere waere geraten.
    contactsMutex.RLock()
    for i := range out {
        if name, ok := contacts[out[i].Sender]; ok && name != "" {
            out[i].SenderKnown = true
        }
    }
    contactsMutex.RUnlock()
    return out
}

// plausiblePhoneNumber prueft nur das Offensichtliche: beginnt der Wert mit
// einer existierenden Laendervorwahl und ist er nicht laenger als eine
// Rufnummer sein kann (E.164 erlaubt 15 Stellen, in der Praxis sind es
// selten mehr als 13)?
func plausiblePhoneNumber(n string) bool {
    if len(n) < 8 || len(n) > 15 {
        return false
    }
    for _, c := range n {
        if c < '0' || c > '9' {
            return false
        }
    }
    if len(n) >= 14 {
        // So lange Rufnummern gibt es praktisch nicht, LIDs dagegen schon
        return false
    }
    for _, cc := range callingCodes {
        if strings.HasPrefix(n, cc) {
            return true
        }
    }
    return false
}

// Existierende Laendervorwahlen (ITU-T E.164). Bewusst vollstaendig genug,
// dass keine echte Nummer faelschlich als LID gilt.
var callingCodes = []string{
    "1", "20", "211", "212", "213", "216", "218", "220", "221", "222", "223",
    "224", "225", "226", "227", "228", "229", "230", "231", "232", "233",
    "234", "235", "236", "237", "238", "239", "240", "241", "242", "243",
    "244", "245", "246", "248", "249", "250", "251", "252", "253", "254",
    "255", "256", "257", "258", "260", "261", "262", "263", "264", "265",
    "266", "267", "268", "269", "27", "290", "291", "297", "298", "299",
    "30", "31", "32", "33", "34", "350", "351", "352", "353", "354", "355",
    "356", "357", "358", "359", "36", "370", "371", "372", "373", "374",
    "375", "376", "377", "378", "379", "380", "381", "382", "383", "385",
    "386", "387", "389", "39", "40", "41", "420", "421", "423", "43", "44",
    "45", "46", "47", "48", "49", "500", "501", "502", "503", "504", "505",
    "506", "507", "508", "509", "51", "52", "53", "54", "55", "56", "57",
    "58", "590", "591", "592", "593", "594", "595", "596", "597", "598",
    "599", "60", "61", "62", "63", "64", "65", "66", "670", "672", "673",
    "674", "675", "676", "677", "678", "679", "680", "681", "682", "683",
    "685", "686", "687", "688", "689", "690", "691", "692", "7", "81", "82",
    "84", "850", "852", "853", "855", "856", "86", "880", "886", "90", "91",
    "92", "93", "94", "95", "960", "961", "962", "963", "964", "965", "966",
    "967", "968", "970", "971", "972", "973", "974", "975", "976", "977",
    "98", "992", "993", "994", "995", "996", "998",
}

// rememberChannelName legt den Namen eines Kanals in derselben Karte ab, aus
// der die Chatliste ihre Bezeichnungen zieht.
func rememberChannelName(jid, name string) {
    if jid == "" || name == "" {
        return
    }
    contactsMutex.Lock()
    changed := contacts[jid] != name
    contacts[jid] = name
    contactsMutex.Unlock()
    if changed {
        saveContacts()
    }
}

// refreshChannelNames holt die Namen der abonnierten Kanaele einmal beim
// Start. Ohne das stehen sie erst da, wenn jemand die Kanalseite oeffnet -
// die Chatliste zeigte bis dahin Ziffern.
func refreshChannelNames() {
    if client == nil || !client.IsConnected() {
        return
    }
    metas, err := client.GetSubscribedNewsletters(context.Background())
    if err != nil {
        fmt.Printf("⚠ channel names: %v\n", err)
        return
    }
    n := 0
    for _, m := range metas {
        if m.ThreadMeta.Name.Text != "" {
            rememberChannelName(m.ID.User, m.ThreadMeta.Name.Text)
            n++
        }
    }
    fmt.Printf("📛 %d channel names refreshed\n", n)
}
