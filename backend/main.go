package main

import (
    "context"
    "encoding/hex"
    "encoding/json"
    "fmt"
    "io"
    "net/http"
    "os"
    "path/filepath"
    "sort"
    "strings"
    "sync"
    "syscall"
    "time"
    "os/signal"

    _ "github.com/mutecomm/go-sqlcipher/v4"
    "go.mau.fi/whatsmeow"
    "go.mau.fi/whatsmeow/proto/waE2E"
    "go.mau.fi/whatsmeow/store/sqlstore"
    "go.mau.fi/whatsmeow/types"
    "go.mau.fi/whatsmeow/types/events"
    waLog "go.mau.fi/whatsmeow/util/log"
    "google.golang.org/protobuf/proto"
)

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
}

type Chat struct {
    JID         string `json:"jid"`
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
        
        if msg.ImageMessage != nil {
            mediaType = "image"
            mimeType = msg.ImageMessage.GetMimetype()
            fileSize = msg.ImageMessage.GetFileLength()
            if c := msg.ImageMessage.GetCaption(); c != "" {
                text = c
            }
            if path, err := downloadMedia(v.Info.ID, msg.ImageMessage, mimeType, ""); err == nil {
                localPath = path
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
            }
        }
        
        if msg.AudioMessage != nil {
            mediaType = "audio"
            mimeType = msg.AudioMessage.GetMimetype()
            fileSize = msg.AudioMessage.GetFileLength()
            if path, err := downloadMedia(v.Info.ID, msg.AudioMessage, mimeType, ""); err == nil {
                localPath = path
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
            }
        }
        
        if msg.StickerMessage != nil {
            mediaType = "sticker"
            mimeType = msg.StickerMessage.GetMimetype()
            if path, err := downloadMedia(v.Info.ID, msg.StickerMessage, mimeType, ""); err == nil {
                localPath = path
            }
        }
        
        chatJid := v.Info.Chat.User
        sender := v.Info.Sender.User
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
            })
            if mediaType != "" {
                fmt.Printf("📩 %s: [%s] %s\n", chatJid, mediaType, text)
            } else {
                fmt.Printf("📩 %s: %s\n", chatJid, text)
            }
        }
        
    case *events.Connected:
        isConnected = true
        fmt.Println("✅ Connected")
        go func() {
            time.Sleep(2 * time.Second)
            loadContacts()
        }()
        
    case *events.PairSuccess:
        isConnected = true
        pairCode = ""
        fmt.Println("✅ Paired!")
        
    case *events.LoggedOut:
        isConnected = false
        pairCode = ""
        fmt.Println("❌ Logged out by server")
        
    case *events.HistorySync:
        fmt.Printf("📜 History sync: %d conversations\n", len(v.Data.Conversations))
        for _, conv := range v.Data.Conversations {
            jidStr := conv.GetID()
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
                if text != "" {
                    fromMe := hm.Message.GetKey().GetFromMe()
                    ts := int64(hm.Message.GetMessageTimestamp())
                    msgID := hm.Message.GetKey().GetID()
                    addMessage(Message{
                        ID: msgID, Sender: chatJid, Text: text, Timestamp: ts,
                        FromMe: fromMe, ChatJID: chatJid,
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
    for _, c := range chatMap {
        chats = append(chats, *c)
    }
    sort.Slice(chats, func(i, j int) bool { return chats[i].LastTime > chats[j].LastTime })
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
    loadContactsFromDisk()
    loadAvatarsFromDisk()

    if client.Store.ID == nil {
        fmt.Println("📱 No device ID - need to pair")
    } else {
        fmt.Println("📱 Device ID found, connecting...")
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
        msg := &waE2E.Message{Conversation: proto.String(text)}
        resp, err := client.SendMessage(ctx, jid, msg)
        if err != nil {
            http.Error(w, err.Error(), 500)
            return
        }
        addMessage(Message{
            ID: resp.ID, Sender: client.Store.ID.User, Text: text,
            Timestamp: time.Now().Unix(), FromMe: true, ChatJID: to,
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

    http.HandleFunc("/reload", func(w http.ResponseWriter, r *http.Request) {
        loadContacts()
        w.Write([]byte("ok"))
    })

    fmt.Println("🚀 Backend running on http://localhost:8085")
    go http.ListenAndServe(":8085", nil)

    c := make(chan os.Signal, 1)
    signal.Notify(c, os.Interrupt, syscall.SIGTERM)
    <-c
    saveMessages()
    saveContacts()
    saveAvatars()
    client.Disconnect()
}
