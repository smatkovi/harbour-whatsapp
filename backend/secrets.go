package main

import (
    "context"
    "crypto/rand"
    "errors"
    "encoding/json"
    "fmt"
    "net"
    "os"
    "strconv"
    "strings"
    "time"

    "github.com/godbus/dbus/v5"
)

const (
    COLLECTION_NAME = "harbourwhatsapp" // SQLCipher-Plugin: nur alphanumerisch, <32 Zeichen
    SECRET_KEY_NAME = "encryptionkey" // ebenfalls rein alphanumerisch
    DEFAULT_PLUGIN  = "org.sailfishos.secrets.plugin.encryptedstorage.sqlcipher"

    USER_INTERACTION_SYSTEM   = 2
    DEVICE_LOCK_KEEP_UNLOCKED = 0
    ACCESS_CONTROL_OWNER_ONLY = 0
)

type SailfishSecrets struct {
    p2pAddress         string
    pluginName         string
    available          bool
    collectionVerified bool
}

var secrets *SailfishSecrets
var encryptionKey []byte

// parseUnixSocketPath extrahiert den Pfad aus einer D-Bus-Adresse der Form
// "unix:path=/run/user/100000/sailfishsecretsd/p2pSocket".
func parseUnixSocketPath(addr string) string {
    // unix:path=... oder unix:abstract=...
    for _, part := range strings.Split(strings.TrimPrefix(addr, "unix:"), ",") {
        if strings.HasPrefix(part, "path=") {
            return strings.TrimPrefix(part, "path=")
        }
        if strings.HasPrefix(part, "abstract=") {
            return "@" + strings.TrimPrefix(part, "abstract=")
        }
    }
    return ""
}

// getConnection baut die P2P-Verbindung zu sailfishsecretsd auf.
//
// Wir sprechen den SASL-EXTERNAL-Handshake SELBST auf dem rohen Unix-Socket
// und uebergeben den fertig authentifizierten Socket dann via dbus.NewConn.
// Grund: godbus' eingebautes conn.Auth() verhandelt auf Unix-Sockets zwingend
// NEGOTIATE_UNIX_FD. Qt's QDBusServer in sailfishsecretsd beantwortet das so,
// dass godbus die Verbindung direkt nach dem Auth-Erfolg (vor BEGIN) fallen
// laesst - sichtbar als "ready", aber EOF beim ersten echten Aufruf.
// dbus.NewConn nutzt intern den genericTransport, dessen SupportsUnixFDs()
// false ist, sodass keine FD-Verhandlung mehr stattfindet.
func (s *SailfishSecrets) getConnection() (*dbus.Conn, error) {
    path := parseUnixSocketPath(s.p2pAddress)
    if path == "" {
        return nil, fmt.Errorf("cannot parse socket path from %q", s.p2pAddress)
    }

    sock, err := net.Dial("unix", path)
    if err != nil {
        return nil, fmt.Errorf("dial %s: %w", path, err)
    }

    // dbus.NewConn nutzt den genericTransport, dessen SupportsUnixFDs() false
    // ist. conn.Auth() macht damit den vollstaendigen SASL-Handshake OHNE die
    // NEGOTIATE_UNIX_FD-Verhandlung (die Qt's QDBusServer in sailfishsecretsd
    // die Verbindung abreissen laesst) und startet zugleich die interne
    // Leseschleife (inWorker), ohne die Antworten nie ankaemen (Timeout).
    conn, err := dbus.NewConn(sock)
    if err != nil {
        sock.Close()
        return nil, fmt.Errorf("dbus.NewConn: %w", err)
    }
    methods := []dbus.Auth{dbus.AuthExternal(strconv.Itoa(os.Getuid()))}
    if err = conn.Auth(methods); err != nil {
        conn.Close()
        return nil, fmt.Errorf("p2p auth (EXTERNAL) failed: %w", err)
    }
    // KEIN conn.Hello() - das ist eine Peer-Verbindung, kein Bus.
    return conn, nil
}
// D-Bus-Typen exakt nach der Introspection von sailfishsecretsd.
// godbus marshalt Go-Structs als D-Bus-Structs "()"; []interface{} wuerde
// dagegen als Variant-Array "av" gesendet und vom Daemon abgelehnt.

// dbEnum entspricht den Qt-Enum-Wrappern mit Signatur "(i)".
type dbEnum struct {
    Value int32
}

// secretIdentifier: Sailfish::Secrets::Secret::Identifier, Signatur "(sss)".
type secretIdentifier struct {
    Name              string
    CollectionName    string
    StoragePluginName string
}

// secretPayload: Sailfish::Secrets::Secret, Signatur "((sss)aya{sv})".
type secretPayload struct {
    Identifier secretIdentifier
    Data       []byte
    FilterData map[string]dbus.Variant
}

// uiParameters: Sailfish::Secrets::InteractionParameters,
// Signatur "(ssss(i)sa{is}(i)(i))".
type uiParameters struct {
    SecretName               string
    CollectionName           string
    PluginName               string
    ApplicationId            string
    Operation                dbEnum
    AuthenticationPluginName string
    PromptText               map[int32]string
    InputType                dbEnum
    EchoMode                 dbEnum
}

// daemonError transportiert den ErrorCode des Daemons typisiert.
type daemonError struct {
    Op        string
    Code      int32
    ErrorCode int32
    Message   string
}

func (e *daemonError) Error() string {
    return fmt.Sprintf("%s: daemon result code=%d errorCode=%d: %s", e.Op, e.Code, e.ErrorCode, e.Message)
}

// Relevante ErrorCodes aus lib/Secrets/result.h
const errCollectionAlreadyExists = 46

// checkResult prueft das Result "(iis)" (Succeeded=0, Pending=1, Failed=2)
// und liefert die Fehlermeldung des Daemons als Go-Fehler.
func checkResult(body []interface{}, op string) error {
    if len(body) == 0 {
        return fmt.Errorf("%s: empty reply", op)
    }
    r, ok := body[0].([]interface{})
    if !ok || len(r) < 3 {
        return fmt.Errorf("%s: unexpected reply shape %T", op, body[0])
    }
    code, _ := r[0].(int32)
    errCode, _ := r[1].(int32)
    msg, _ := r[2].(string)
    if code != 0 {
        return &daemonError{op, code, errCode, msg}
    }
    return nil
}

func emptyUIParams() uiParameters {
    return uiParameters{PromptText: map[int32]string{}}
}

func (s *SailfishSecrets) callWithTimeout(method string, timeout time.Duration, args ...interface{}) ([]interface{}, error) {
    type result struct {
        body []interface{}
        err  error
    }
    done := make(chan result, 1)

    go func() {
        conn, err := s.getConnection()
        if err != nil {
            done <- result{nil, err}
            return
        }
        defer conn.Close()

        // Nachricht manuell bauen - OHNE Destination-Headerfeld. godbus'
        // Object().Call() setzt Destination auch bei leerem Namen, was auf
        // einer Peer-Verbindung ein Spec-Verstoss ist: libdbus-basierte
        // Server (Qt/sailfishsecretsd) trennen dann kommentarlos (EOF).
        msg := new(dbus.Message)
        msg.Type = dbus.TypeMethodCall
        msg.Headers = map[dbus.HeaderField]dbus.Variant{
            dbus.FieldPath:      dbus.MakeVariant(dbus.ObjectPath("/Sailfish/Secrets")),
            dbus.FieldInterface: dbus.MakeVariant("org.sailfishos.secrets"),
            dbus.FieldMember:    dbus.MakeVariant(method),
        }
        msg.Body = args
        if len(args) > 0 {
            msg.Headers[dbus.FieldSignature] = dbus.MakeVariant(dbus.SignatureOf(args...))
        }
        pending := conn.SendWithContext(context.Background(), msg, make(chan *dbus.Call, 1))
        call := <-pending.Done
        done <- result{call.Body, call.Err}
    }()

    select {
    case r := <-done:
        return r.body, r.err
    case <-time.After(timeout):
        return nil, fmt.Errorf("timeout")
    }
}

func InitSecrets() error {
    secrets = &SailfishSecrets{pluginName: DEFAULT_PLUGIN}

    done := make(chan error, 1)
    go func() {
        // WICHTIG: private Verbindung verwenden. dbus.SessionBus() liefert
        // eine prozessweit geteilte Singleton-Verbindung - die per defer zu
        // schliessen wuerde jeden spaeteren InitSecrets-Aufruf (Retry!)
        // dauerhaft mit "connection closed" scheitern lassen.
        sessionBus, err := dbus.SessionBusPrivate()
        if err != nil {
            done <- err
            return
        }
        defer sessionBus.Close()
        if err = sessionBus.Auth(nil); err != nil {
            done <- err
            return
        }
        if err = sessionBus.Hello(); err != nil {
            done <- err
            return
        }

        obj := sessionBus.Object("org.sailfishos.secrets.daemon.discovery", "/Sailfish/Secrets/Discovery")
        err = obj.Call("org.sailfishos.secrets.daemon.discovery.peerToPeerAddress", 0).Store(&secrets.p2pAddress)
        done <- err
    }()

    select {
    case err := <-done:
        if err != nil {
            return err
        }
    case <-time.After(3 * time.Second):
        return fmt.Errorf("timeout connecting to secrets daemon")
    }

    fmt.Printf("🔐 P2P socket: %s\n", secrets.p2pAddress)

    testDone := make(chan error, 1)
    go func() {
        conn, err := secrets.getConnection()
        if err != nil {
            testDone <- err
            return
        }
        conn.Close()
        testDone <- nil
    }()

    select {
    case err := <-testDone:
        if err != nil {
            return err
        }
    case <-time.After(2 * time.Second):
        return fmt.Errorf("timeout testing secrets connection")
    }

    secrets.available = true
    fmt.Println("🔐 Sailfish Secrets ready")

    // Handshake-Selbsttest: getPluginInfo hat keine komplexen Eingabetypen.
    // Klappt es, ist Auth/Transport ok und ein spaeterer Fehler liegt am
    // Marshalling der Secret-Structs; scheitert schon das, ist es Auth/Transport.
    if _, terr := secrets.callWithTimeout("getPluginInfo", 3*time.Second); terr != nil {
        fmt.Printf("🔐 self-test getPluginInfo failed: %v\n", terr)
    } else {
        fmt.Println("🔐 self-test getPluginInfo ok (auth/transport working)")
    }
    return nil
}

func (s *SailfishSecrets) ensureCollection() error {
    if !s.available || s.collectionVerified {
        return nil
    }
    body, err := s.callWithTimeout("createCollection", 10*time.Second,
        COLLECTION_NAME, s.pluginName, s.pluginName,
        dbEnum{int32(DEVICE_LOCK_KEEP_UNLOCKED)},
        dbEnum{int32(ACCESS_CONTROL_OWNER_ONLY)})
    if err != nil {
        return err
    }
    if cerr := checkResult(body, "createCollection"); cerr != nil {
        var de *daemonError
        if errors.As(cerr, &de) && de.ErrorCode == errCollectionAlreadyExists {
            // Collection existiert bereits - genau das wollen wir
        } else {
            fmt.Printf("🔐 createCollection: %v\n", cerr)
        }
    }
    s.collectionVerified = true
    return nil
}

func (s *SailfishSecrets) StoreSecret(name string, data []byte) error {
    if !s.available {
        return fmt.Errorf("not available")
    }
    s.ensureCollection()

    secretId := secretIdentifier{name, COLLECTION_NAME, s.pluginName}
    s.callWithTimeout("deleteSecret", 5*time.Second, secretId, dbEnum{int32(USER_INTERACTION_SYSTEM)}, "")

    secret := secretPayload{secretId, data, map[string]dbus.Variant{}}

    body, err := s.callWithTimeout("setSecret", 10*time.Second, secret, emptyUIParams(), dbEnum{int32(USER_INTERACTION_SYSTEM)}, "")
    if err != nil {
        return fmt.Errorf("couldn't store key: %v", err)
    }
    if rerr := checkResult(body, "setSecret"); rerr != nil {
        return fmt.Errorf("couldn't store key: %v", rerr)
    }
    return nil
}

func (s *SailfishSecrets) RetrieveSecret(name string) ([]byte, error) {
    if !s.available {
        return nil, fmt.Errorf("not available")
    }

    body, err := s.callWithTimeout("getSecret", 10*time.Second,
        secretIdentifier{name, COLLECTION_NAME, s.pluginName},
        dbEnum{int32(USER_INTERACTION_SYSTEM)}, "")
    if err != nil {
        return nil, err
    }
    if rerr := checkResult(body, "getSecret"); rerr != nil {
        return nil, rerr
    }
    if len(body) >= 2 {
        if secret, ok := body[1].([]interface{}); ok && len(secret) >= 2 {
            if data, ok := secret[1].([]byte); ok {
                return data, nil
            }
        }
    }
    return nil, fmt.Errorf("getSecret: unexpected reply shape")
}

func ClearAllSecrets() {
    if secrets != nil && secrets.available {
        secretId := secretIdentifier{SECRET_KEY_NAME, COLLECTION_NAME, secrets.pluginName}
        secrets.callWithTimeout("deleteSecret", 5*time.Second, secretId, dbEnum{int32(USER_INTERACTION_SYSTEM)}, "")
        secrets.callWithTimeout("deleteCollection", 5*time.Second, COLLECTION_NAME, secrets.pluginName, dbEnum{int32(USER_INTERACTION_SYSTEM)}, "")
    }
    encryptionKey = nil
}

func GetOrCreateKey() ([]byte, error) {
    if secrets == nil || !secrets.available {
        return nil, fmt.Errorf("Sailfish Secrets not available")
    }
    
    if key, err := secrets.RetrieveSecret(SECRET_KEY_NAME); err == nil && len(key) == 32 {
        fmt.Println("🔐 Encryption key loaded from Sailfish Secrets")
        encryptionKey = key
        return key, nil
    }

    fmt.Println("🔐 Generating new encryption key...")
    key := make([]byte, 32)
    if _, err := rand.Read(key); err != nil {
        return nil, err
    }

    if err := secrets.StoreSecret(SECRET_KEY_NAME, key); err != nil {
        return nil, fmt.Errorf("couldn't store key: %v", err)
    }

    fmt.Println("🔐 Encryption key stored in Sailfish Secrets")
    encryptionKey = key
    return key, nil
}

func RegenerateKey() ([]byte, error) {
    ClearAllSecrets()
    return GetOrCreateKey()
}

// LoadEncrypted - plain JSON (no encryption)
func LoadEncrypted(filename string, v interface{}) error {
    data, err := os.ReadFile(filename)
    if err != nil {
        return err
    }
    return json.Unmarshal(data, v)
}

// SaveEncrypted - plain JSON (no encryption)
func SaveEncrypted(filename string, v interface{}) error {
    data, err := json.Marshal(v)
    if err != nil {
        return err
    }
    return os.WriteFile(filename, data, 0600)
}
