package main

import (
    "context"
    "encoding/hex"
    "encoding/base64"
    "encoding/json"
    "fmt"
    "io"
    "net"
    "net/http"
    "os"
    "path/filepath"
    "sort"
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
    Pinned   bool `json:"pinned,omitempty"`
    Muted    bool `json:"muted,omitempty"`
    Archived bool `json:"archived,omitempty"`
    IsChannel bool `json:"isChannel,omitempty"`
}

var chatSettings = make(map[string]*ChatSettings) // chatJid -> settings
var chatSettingsMutex sync.RWMutex
var chatSettingsFile = "chatsettings.enc"
var knownChannels = make(map[string]bool) // chatJid(user) -> true
var knownChannelsMutex sync.RWMutex
var knownChannelsFile = "channels.enc"

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
}

type Chat struct {
    JID         string `json:"jid"`
    Pinned   bool `json:"pinned,omitempty"`
    Muted    bool `json:"muted,omitempty"`
    Archived bool `json:"archived,omitempty"`
    IsChannel bool `json:"isChannel,omitempty"`
    Name        string `json:"name"`
    LastMessage string `json:"lastMessage"`
    LastTime    int64  `json:"lastTime"`
    FromMe      bool   `json:"fromMe"`
    IsGroup     bool   `json:"isGroup"`
    Avatar      string `json:"avatar,omitempty"`
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
    
    picturesDir = filepath.Join(homeDir, "Pictures", "WhatsApp")
    videosDir = filepath.Join(homeDir, "Videos", "WhatsApp")
    audioDir = filepath.Join(homeDir, "Music", "WhatsApp")
    documentsDir = filepath.Join(homeDir, "Documents", "WhatsApp")
    avatarsDir = filepath.Join(homeDir, "Pictures", "WhatsApp", "avatars")
    
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

func saveMessages() {
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
    if path, ok := avatars[jid]; ok {
        avatarsMutex.RUnlock()
        if _, err := os.Stat(path); err == nil {
            return path
        }
    }
    avatarsMutex.RUnlock()

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

    path := filepath.Join(avatarsDir, jid+".jpg")
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
    data, err := client.Download(ctx, msg)
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
                    if newText != "" {
                        updateMessage("", pm.GetKey().GetID(), func(m *Message) {
                            m.Text = newText
                            m.Edited = true
                        })
                    }
                }
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

        // Umfragen
        if poll := msg.GetPollCreationMessageV3(); poll != nil {
            text = pollText(poll)
        } else if poll := msg.GetPollCreationMessageV2(); poll != nil {
            text = pollText(poll)
        } else if poll := msg.GetPollCreationMessage(); poll != nil {
            text = pollText(poll)
        }

        // Gruppen-Einladung
        if gi := msg.GetGroupInviteMessage(); gi != nil {
            text = "👥 Group invite: " + gi.GetGroupName()
        }

        // Zitat/Antwort auslesen
        var quotedID, quotedText, quotedSender string
        if ci := getContextInfo(msg); ci != nil && ci.GetStanzaID() != "" {
            quotedID = ci.GetStanzaID()
            quotedText = quotedSnippet(ci.GetQuotedMessage())
            if p := ci.GetParticipant(); p != "" {
                if pj, err := types.ParseJID(p); err == nil {
                    quotedSender = resolvePN(pj, types.EmptyJID).User
                }
            }
        }
        
        if msg.ImageMessage != nil {
            mediaType = "image"
            mimeType = msg.ImageMessage.GetMimetype()
            fileSize = msg.ImageMessage.GetFileLength()
            if c := msg.ImageMessage.GetCaption(); c != "" {
                text = c
            }
            if path, err := downloadMedia(v.Info.ID, msg.ImageMessage, mimeType, ""); err == nil {
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
            if path, err := downloadMedia(v.Info.ID, msg.VideoMessage, mimeType, ""); err == nil {
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
            if path, err := downloadMedia(v.Info.ID, msg.AudioMessage, mimeType, ""); err == nil {
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
            if path, err := downloadMedia(v.Info.ID, msg.DocumentMessage, mimeType, fileName); err == nil {
                localPath = path
            } else {
                fmt.Printf("⚠️ Media download failed (%s), keeping key for retry: %v\n", v.Info.ID, err)
                stashRawMedia(v.Info.ID, msg)
            }
        }
        
        if msg.StickerMessage != nil {
            mediaType = "sticker"
            mimeType = msg.StickerMessage.GetMimetype()
            if path, err := downloadMedia(v.Info.ID, msg.StickerMessage, mimeType, ""); err == nil {
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
        }
        sender := senderJID.User
        if v.Info.IsFromMe {
            sender = client.Store.ID.User
        }
        if v.Info.PushName != "" && !v.Info.IsFromMe {
            contactsMutex.Lock()
            contacts[sender] = v.Info.PushName
            contactsMutex.Unlock()
            go saveContacts()
        }
        
        if text != "" || mediaType != "" {
            addMessage(Message{
                ID: v.Info.ID, Sender: sender, Text: text, Timestamp: v.Info.Timestamp.Unix(),
                FromMe: v.Info.IsFromMe, ChatJID: chatJid, MediaType: mediaType,
                MimeType: mimeType, FileName: fileName, FileSize: fileSize, LocalPath: localPath,
                Latitude: latitude, Longitude: longitude,
                QuotedID: quotedID, QuotedText: quotedText, QuotedSender: quotedSender,
            })
            if mediaType != "" {
                fmt.Printf("📩 %s: [%s] %s\n", chatJid, mediaType, text)
            } else {
                fmt.Printf("📩 %s: %s\n", chatJid, text)
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
            rawMediaMutex.Lock()
            delete(rawMedia, msgID)
            rawMediaMutex.Unlock()
            go saveRawMedia()
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

    case *events.Connected:
        isConnected = true
        connState = "connected"
        lastError = ""
        fmt.Println("✅ Connected")
        go func() {
            time.Sleep(2 * time.Second)
            loadContacts()
        }()
        
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
        connState = "reconnecting"
        fmt.Println("🔌 Disconnected, reconnecting...")

    case *events.ConnectFailure:
        isConnected = false
        connState = "error"
        lastError = fmt.Sprintf("Connect failure: %s", v.Reason.String())
        fmt.Printf("❌ %s\n", lastError)

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
                if text != "" || mediaType != "" {
                    fromMe := hm.Message.GetKey().GetFromMe()
                    ts := int64(hm.Message.GetMessageTimestamp())
                    msgID := hm.Message.GetKey().GetID()
                    if mediaType != "" {
                        stashRawMedia(msgID, msg)
                    }
                    sender := chatJid
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
    chatMap := make(map[string]*Chat)
    for _, msg := range messages {
        jid := msg.ChatJID
        if jid == "" {
            jid = msg.Sender
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
        if cs, ok := chatSettings[c.JID]; ok {
            c.Pinned, c.Muted, c.Archived = cs.Pinned, cs.Muted, cs.Archived
        }
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
        if msg.ChatJID == jid || msg.Sender == jid {
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
    if len(to) > 15 {
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

func main() {
    // Initialize paths first
    initPaths()
    
    // Initialize Sailfish Secrets
    if err := InitSecrets(); err != nil {
        fmt.Printf("⚠️ Sailfish Secrets not available: %v\n", err)
        fmt.Println("⚠️ Running without encryption (development mode)")
    }
    
    // Get or create encryption key
    var err error
    encryptionKey, err = GetOrCreateKey()
    if err != nil {
        fmt.Printf("⚠️ Could not get encryption key: %v\n", err)
    }
    
    // Initialize encrypted database
    if err := initDatabase(); err != nil {
        fmt.Printf("❌ Database error: %v\n", err)
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
    loadContactsFromDisk()
    loadAvatarsFromDisk()

    if client.Store.ID == nil {
        fmt.Println("📱 No device ID - need to pair")
        connState = "waiting_for_pair"
    } else {
        fmt.Println("📱 Device ID found, connecting...")
        connState = "connecting"
    }
    go client.Connect()

    http.HandleFunc("/status", func(w http.ResponseWriter, r *http.Request) {
        w.Header().Set("Content-Type", "application/json")
        phone := ""
        if client.Store.ID != nil {
            phone = client.Store.ID.User
        }
        json.NewEncoder(w).Encode(map[string]interface{}{
            "connected": isConnected,
            "pairCode":  pairCode,
            "phone":     phone,
            "state":     connState,
            "lastError": lastError,
            "version":   version,
            "paired":    client != nil && client.Store.ID != nil,
        })
    })

    http.HandleFunc("/pair", func(w http.ResponseWriter, r *http.Request) {
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
            
            client.Connect()
            fmt.Println("📱 Ready for new pairing")
        }()
    })

    http.HandleFunc("/chats", func(w http.ResponseWriter, r *http.Request) {
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

    http.HandleFunc("/messages", func(w http.ResponseWriter, r *http.Request) {
        jid := r.URL.Query().Get("jid")
        w.Header().Set("Content-Type", "application/json")
        if jid != "" {
            json.NewEncoder(w).Encode(getMessagesForChat(jid))
        } else {
            msgMutex.RLock()
            json.NewEncoder(w).Encode(messages)
            msgMutex.RUnlock()
        }
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
        var msg *waE2E.Message
        if quoteID != "" {
            participant := quoteSender
            if participant == "" && client.Store.ID != nil {
                participant = client.Store.ID.User
            }
            msg = &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{
                Text: proto.String(text),
                ContextInfo: &waE2E.ContextInfo{
                    StanzaID:      proto.String(quoteID),
                    Participant:   proto.String(participant + "@" + types.DefaultUserServer),
                    QuotedMessage: &waE2E.Message{Conversation: proto.String(quoteText)},
                },
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
        })
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
            json.NewEncoder(w).Encode(map[string]string{"path": target.LocalPath})
            return
        }
        rawMediaMutex.RLock()
        b64, ok := rawMedia[msgID]
        rawMediaMutex.RUnlock()
        if !ok {
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
            // Abgelaufen? Telefon um Neu-Upload bitten und spaeter erneut versuchen
            if strings.Contains(err.Error(), "404") || strings.Contains(err.Error(), "410") {
                if rerr := requestMediaRetry(target, dl); rerr == nil {
                    w.WriteHeader(202)
                    w.Write([]byte("media expired - requested re-upload from your phone, try again in a moment (phone must be online)"))
                    return
                }
            }
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
        rawMediaMutex.Lock()
        delete(rawMedia, msgID)
        rawMediaMutex.Unlock()
        go saveRawMedia()
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
        if client != nil && client.Store.ID != nil {
            own := types.NewJID(client.Store.ID.User, types.DefaultUserServer)
            if info, err := client.GetUserInfo(ctx, []types.JID{own}); err == nil {
                if ui, ok := info[own]; ok {
                    about = ui.Status
                }
            }
        }
        json.NewEncoder(w).Encode(map[string]string{"name": name, "about": about})
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
            if err := client.SetStatusMessage(ctx, about); err != nil {
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
        if err := client.SendAppState(ctx, patch); err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
        go saveChatSettings()
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
        json.NewEncoder(w).Encode(map[string]string{"jid": gi.JID.User})
    })

    http.HandleFunc("/group/leave", func(w http.ResponseWriter, r *http.Request) {
        chat := r.URL.Query().Get("chat")
        if err := client.LeaveGroup(ctx, types.NewJID(chat, types.GroupServer)); err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
        w.Write([]byte("ok"))
    })

    http.HandleFunc("/group/rename", func(w http.ResponseWriter, r *http.Request) {
        chat := r.URL.Query().Get("chat")
        name := r.URL.Query().Get("name")
        if err := client.SetGroupName(ctx, types.NewJID(chat, types.GroupServer), name); err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
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
            http.Error(w, "unsupported image: "+err.Error(), 400)
            return
        }
        var buf bytes.Buffer
        jpeg.Encode(&buf, img, &jpeg.Options{Quality: 85})
        if _, err := client.SetGroupPhoto(ctx, types.NewJID(chat, types.GroupServer), buf.Bytes()); err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
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

    http.HandleFunc("/group/info", func(w http.ResponseWriter, r *http.Request) {
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
        default:
            http.Error(w, "action=add|remove required", 400)
            return
        }
        if _, err := client.UpdateGroupParticipants(ctx, types.NewJID(chat, types.GroupServer), jids, change); err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
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
    http.HandleFunc("/channel/follow", func(w http.ResponseWriter, r *http.Request) {
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

    http.HandleFunc("/quit", func(w http.ResponseWriter, r *http.Request) {
        fmt.Println("👋 Quit requested (update?), saving and exiting...")
        saveMessages()
        saveContacts()
        saveRawMedia()
        json.NewEncoder(w).Encode(map[string]bool{"ok": true})
        go func() {
            time.Sleep(300 * time.Millisecond)
            if client != nil {
                client.Disconnect()
            }
            os.Exit(0)
        }()
    })

    http.HandleFunc("/reload", func(w http.ResponseWriter, r *http.Request) {
        loadContacts()
        w.Write([]byte("ok"))
    })

    // Bind to loopback only (the API exposes all messages - it must never be
    // reachable from the network). Try a small port range so a busy port no
    // longer makes the backend fail silently; write the chosen port to a file
    // for the launcher/UI to pick up.
    var listener net.Listener
    var port int
    for p := 8085; p <= 8089; p++ {
        l, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", p))
        if err == nil {
            listener = l
            port = p
            break
        }
        fmt.Printf("⚠️ Port %d unavailable: %v\n", p, err)
    }
    if listener == nil {
        fmt.Println("❌ No free port in 8085-8089, exiting")
        os.Exit(1)
    }
    os.WriteFile("backend.port", []byte(fmt.Sprintf("%d", port)), 0600)
    fmt.Printf("🚀 Backend running on http://127.0.0.1:%d\n", port)
    go http.Serve(listener, nil)

    c := make(chan os.Signal, 1)
    signal.Notify(c, os.Interrupt, syscall.SIGTERM)
    <-c
    saveMessages()
    saveContacts()
    saveAvatars()
    client.Disconnect()
}
