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
    SECRET_KEY_NAME = "encryptionkey" // rein alphanumerisch (SQLCipher-Plugin-Regel)
    DEFAULT_PLUGIN  = "org.sailfishos.secrets.plugin.encryptedstorage.sqlcipher"

    USER_INTERACTION_SYSTEM   = 2
    DEVICE_LOCK_KEEP_UNLOCKED = 0
    ACCESS_CONTROL_OWNER_ONLY = 0
    // NoAccessControlMode: Collection ist NICHT an die Sailjail-Identitaet
    // des Erstellers gebunden. Der Zugriff bleibt durch die Secrets-
    // Permission der Sandbox und den Device-Lock geschuetzt. Bewusst gewaehlt
    // ("use with care"), damit Terminal- vs. Icon-Starts und kuenftige
    // Identitaetsaenderungen die App nie wieder vom eigenen Key aussperren.
    ACCESS_CONTROL_NONE = 2
)

// Sailfish Secrets bindet Collections an die Sailjail-Identitaet des
// Erstellers. Laeuft die App unter anderer Identitaet (z.B. per Terminal
// statt vom Icon gestartet), antwortet der Daemon mit OwnershipError
// (errorCode=10). Das ist KEIN Datenverlust: vom Icon gestartet passt die
// Identitaet wieder und der Key ist unveraendert da - wir erkennen den
// Fall und erklaeren genau das, statt destruktiv auszuweichen.
const errOwnership = 10 // Result errorCode: owned by a different application

// isNotFoundError: Secret/Collection existiert nicht (Result-ErrorCodes 40,
// 41, 43). NUR solche Namen duerfen Speicherziel fuer einen neuen Key sein -
// jeder andere Lesefehler (Interaktion verpasst, Collection gesperrt,
// Daemon-Problem) koennte einen real existierenden Key verdecken, und ein
// Store dorthin wuerde ihn UEBERSCHREIBEN.
func isNotFoundError(err error) bool {
    var de *daemonError
    if errors.As(err, &de) {
        return de.ErrorCode == 40 || de.ErrorCode == 41 || de.ErrorCode == 43
    }
    return false
}

// IsOwnershipError meldet, ob ein Fehler der Identitaets-Besitzkonflikt ist.
func IsOwnershipError(err error) bool {
    var de *daemonError
    return errors.As(err, &de) && de.ErrorCode == errOwnership
}

type SailfishSecrets struct {
    collectionName string
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
    secrets = &SailfishSecrets{pluginName: DEFAULT_PLUGIN, collectionName: "harbourwhatsapp"}

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

    // Diagnose nach Storeman-Vorbild (CollectionNamesRequest): welche
    // Collections existieren im Plugin? Zeigt Besitz-/Altlasten-Situationen
    // im Log, BEVOR ein Zugriff scheitert. Antwort: (Result, a{sb}).
    if ret, terr := secrets.callWithTimeout("collectionNames", 3*time.Second, secrets.pluginName); terr != nil {
        fmt.Printf("🔐 collectionNames failed: %v\n", terr)
    } else if len(ret) >= 2 {
        if names, ok := ret[1].(map[string]bool); ok {
            keys := make([]string, 0, len(names))
            for k := range names {
                keys = append(keys, k)
            }
            fmt.Printf("🔐 collections in plugin: %v\n", keys)
        } else {
            fmt.Printf("🔐 collections reply type: %T\n", ret[1])
        }
    }
    return nil
}

func (s *SailfishSecrets) ensureCollection() error {
    if !s.available || s.collectionVerified {
        return nil
    }
    body, err := s.callWithTimeout("createCollection", 10*time.Second,
        s.collectionName, s.pluginName, s.pluginName,
        dbEnum{int32(DEVICE_LOCK_KEEP_UNLOCKED)},
        dbEnum{int32(ACCESS_CONTROL_NONE)})
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

    secretId := secretIdentifier{name, s.collectionName, s.pluginName}
    s.callWithTimeout("deleteSecret", 5*time.Second, secretId, dbEnum{int32(USER_INTERACTION_SYSTEM)}, "")

    secret := secretPayload{secretId, data, map[string]dbus.Variant{}}

    body, err := s.callWithTimeout("setSecret", 10*time.Second, secret, emptyUIParams(), dbEnum{int32(USER_INTERACTION_SYSTEM)}, "")
    if err != nil {
        return fmt.Errorf("couldn't store key: %w", err)
    }
    if rerr := checkResult(body, "setSecret"); rerr != nil {
        return fmt.Errorf("couldn't store key: %w", rerr)
    }
    return nil
}

func (s *SailfishSecrets) RetrieveSecret(name string) ([]byte, error) {
    if !s.available {
        return nil, fmt.Errorf("not available")
    }

    body, err := s.callWithTimeout("getSecret", 10*time.Second,
        secretIdentifier{name, s.collectionName, s.pluginName},
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
        secretId := secretIdentifier{SECRET_KEY_NAME, secrets.collectionName, secrets.pluginName}
        secrets.callWithTimeout("deleteSecret", 5*time.Second, secretId, dbEnum{int32(USER_INTERACTION_SYSTEM)}, "")
        secrets.callWithTimeout("deleteCollection", 5*time.Second, secrets.collectionName, secrets.pluginName, dbEnum{int32(USER_INTERACTION_SYSTEM)}, "")
    }
    encryptionKey = nil
}

var collectionCandidates = []string{"harbourwhatsapp", "harbourwhatsapp2", "harbourwhatsapp3"}

// Key-Uebergabe zwischen Sailjail-Identitaeten: gehoert die Collection einer
// anderen Identitaet (z.B. Terminal-Start), schreibt die ausgesperrte
// Identitaet einen Marker. Die besitzende Identitaet exportiert den Key beim
// naechsten Start in eine temporaere 0600-Datei; die normale Identitaet
// uebernimmt ihn in eine eigene Collection und loescht die Datei. Ergebnis:
// gleiche wa.db, gleicher Key, KEIN neues Pairing.
const keyHandoverMarker = ".want-key-handover"
const keyHandoverFile = ".key-handover"

// Sentinel-Fehler fuer main(): steuern die Halt-Texte
var ErrKeyHandoverRequested = fmt.Errorf("key handover requested")
var ErrKeyExported = fmt.Errorf("key exported for handover")

const collectionNameFile = ".collection-name"

// listCollections liefert die im Plugin existierenden Collection-Namen.
func (s *SailfishSecrets) listCollections() []string {
    ret, err := s.callWithTimeout("collectionNames", 3*time.Second, s.pluginName)
    if err != nil || len(ret) < 2 {
        return nil
    }
    names, ok := ret[1].(map[string]bool)
    if !ok {
        return nil
    }
    out := make([]string, 0, len(names))
    for k := range names {
        out = append(out, k)
    }
    return out
}

// candidateNames baut die Suchreihenfolge: zuletzt benutzter Name (persistiert),
// dann die festen Kandidaten, dann alle existierenden Collections, die nach
// unseren dynamischen Namen aussehen (hwapp<zeit>). So geht ein einmal
// gewaehlter dynamischer Name nie mehr verloren.
func candidateNames() []string {
    seen := map[string]bool{}
    var out []string
    add := func(n string) {
        if n != "" && !seen[n] {
            seen[n] = true
            out = append(out, n)
        }
    }
    if data, err := os.ReadFile(collectionNameFile); err == nil {
        add(strings.TrimSpace(string(data)))
    }
    for _, n := range collectionCandidates {
        add(n)
    }
    for _, n := range secrets.listCollections() {
        if strings.HasPrefix(n, "hwapp") || strings.HasPrefix(n, "harbourwhatsapp") {
            add(n)
        }
    }
    return out
}

func rememberCollectionName(name string) {
    os.WriteFile(collectionNameFile, []byte(name), 0600)
}

func GetOrCreateKey() ([]byte, error) {
    if secrets == nil || !secrets.available {
        return nil, fmt.Errorf("Sailfish Secrets not available")
    }

    sawOwnership := false
    var hardErr error
    storeTarget := "" // erster sicher-leerer Name (fuer Neuanlage)
    names := candidateNames()
    for i, name := range names {
        secrets.collectionName = name
        secrets.collectionVerified = false
        key, err := secrets.RetrieveSecret(SECRET_KEY_NAME)
        if err == nil && len(key) == 32 {
            if _, merr := os.Stat(keyHandoverMarker); merr == nil {
                // Eine andere Identitaet hat um den Key gebeten. Der Key
                // verlaesst Secrets dabei NIE: wir speichern ihn in eine
                // NoAccessControl-Collection (identitaetsoffen, aber durch
                // Sandbox-Permission und Device-Lock geschuetzt), aus der
                // die App-Identitaet ihn regulaer laedt.
                ownCollection := name
                exported := false
                for _, target := range append([]string{"harbourwhatsapp2", "harbourwhatsapp3"}, fmt.Sprintf("hwapp%d", time.Now().Unix())) {
                    if target == ownCollection {
                        continue
                    }
                    secrets.collectionName = target
                    secrets.collectionVerified = false
                    if serr := secrets.StoreSecret(SECRET_KEY_NAME, key); serr == nil {
                        fmt.Printf("🔐 Encryption key handed over via Secrets into collection %s\n", target)
                        exported = true
                        break
                    } else {
                        fmt.Printf("🔐 handover store into %s failed: %v\n", target, serr)
                    }
                }
                secrets.collectionName = ownCollection
                secrets.collectionVerified = false
                if !exported {
                    return nil, fmt.Errorf("key handover failed: no writable target collection")
                }
                os.Remove(keyHandoverMarker)
                return nil, ErrKeyExported
            }
            fmt.Printf("🔐 Encryption key loaded from Sailfish Secrets (collection %s)\n", name)
            rememberCollectionName(name)
            // Uebergabe-Reste entfernen: .key-handover enthaelt den Key im
            // KLARTEXT und darf einen regulaeren Start nicht ueberleben;
            // ein alter Marker wuerde beim naechsten Start faelschlich
            // einen Export ausloesen
            if err := os.Remove(keyHandoverFile); err == nil {
                fmt.Println("🔐 removed leftover key handover file")
            }
            os.Remove(keyHandoverMarker)
            encryptionKey = key
            return key, nil
        }
        if IsOwnershipError(err) {
            fmt.Printf("🔐 Collection %s owned by another identity (%d/%d)\n", name, i+1, len(names))
            sawOwnership = true
            continue
        }
        if isNotFoundError(err) {
            // wirklich leer: als Speicherziel vormerken, aber weitersuchen
            if storeTarget == "" {
                storeTarget = name
            }
            continue
        }
        // Anderer Lesefehler (verpasste Bestaetigung, gesperrte Collection,
        // Daemon-Problem): hier koennte ein echter Key liegen - NIE als
        // Speicherziel verwenden, Fehler fuer den Halt merken
        fmt.Printf("🔐 read error on collection %s (not eligible as target): %v\n", name, err)
        if hardErr == nil {
            hardErr = err
        }
    }
    if hardErr != nil && storeTarget == "" {
        // Kein sicher-leeres Ziel und mindestens eine unlesbare Collection:
        // anhalten statt riskieren - Restart backend wiederholt den Prompt
        return nil, fmt.Errorf("secret unreadable, refusing to overwrite: %w", hardErr)
    }
    if storeTarget != "" {
        secrets.collectionName = storeTarget
        secrets.collectionVerified = false
    }

    // Legacy: Uebergabedatei aelterer Versionen noch adoptieren (und loeschen)
    if data, ferr := os.ReadFile(keyHandoverFile); ferr == nil && len(data) == 32 {
        fmt.Printf("🔐 Adopting handed-over encryption key into collection %s...\n", secrets.collectionName)
        if err := secrets.StoreSecret(SECRET_KEY_NAME, data); err != nil {
            return nil, fmt.Errorf("couldn't store handed-over key: %w", err)
        }
        os.Remove(keyHandoverFile)
        rememberCollectionName(secrets.collectionName)
        encryptionKey = data
        fmt.Println("🔐 Key handover complete - same database, no re-pairing needed")
        return data, nil
    }

    // Besitzkonflikt ohne Uebergabedatei: bei bestehender DB NICHT neu
    // erzeugen (das wuerde die DB verwaisen) - Uebergabe anfordern
    if sawOwnership {
        if _, derr := os.Stat("wa.db"); derr == nil {
            os.WriteFile(keyHandoverMarker, []byte("1"), 0600)
            return nil, ErrKeyHandoverRequested
        }
        // Keine DB (z.B. nach Reset), aber alle festen Namen fremd-besessen:
        // dynamischen, garantiert eigenen Namen verwenden (alphanumerisch,
        // <32 Zeichen - SQLCipher-Plugin-Regel)
        secrets.collectionName = fmt.Sprintf("hwapp%d", time.Now().Unix())
        secrets.collectionVerified = false
        fmt.Printf("🔐 All fixed collection names foreign-owned - using dynamic name %s\n", secrets.collectionName)
    }

    fmt.Printf("🔐 Generating new encryption key (collection %s)...\n", secrets.collectionName)
    key := make([]byte, 32)
    if _, err := rand.Read(key); err != nil {
        return nil, err
    }

    if err := secrets.StoreSecret(SECRET_KEY_NAME, key); err != nil {
        if IsOwnershipError(err) && secrets.collectionName != collectionCandidates[len(collectionCandidates)-1] {
            // Store deckte den Besitzkonflikt erst auf: einmal weiterruecken
            for i, name := range collectionCandidates {
                if name == secrets.collectionName && i+1 < len(collectionCandidates) {
                    secrets.collectionName = collectionCandidates[i+1]
                    secrets.collectionVerified = false
                    break
                }
            }
            fmt.Printf("🔐 Retrying key store in collection %s...\n", secrets.collectionName)
            if err2 := secrets.StoreSecret(SECRET_KEY_NAME, key); err2 != nil {
                return nil, fmt.Errorf("couldn't store key: %w", err2)
            }
        } else {
            return nil, fmt.Errorf("couldn't store key: %w", err)
        }
    }

    rememberCollectionName(secrets.collectionName)
    fmt.Printf("🔐 Encryption key stored in Sailfish Secrets (collection %s)\n", secrets.collectionName)
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
