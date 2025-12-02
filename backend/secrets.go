package main

import (
    "crypto/aes"
    "crypto/cipher"
    "crypto/rand"
    "encoding/json"
    "fmt"
    "io"
    "os"
    "time"

    "github.com/godbus/dbus/v5"
)

const (
    COLLECTION_NAME = "whatsapp-systemd"
    SECRET_KEY_NAME = "encryption-key"
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

func (s *SailfishSecrets) getConnection() (*dbus.Conn, error) {
    conn, err := dbus.Dial(s.p2pAddress)
    if err != nil {
        return nil, err
    }
    err = conn.Auth(nil)
    if err != nil {
        conn.Close()
        return nil, err
    }
    return conn, nil
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

        obj := conn.Object("", "/Sailfish/Secrets")
        call := obj.Call("org.sailfishos.secrets."+method, 0, args...)
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
        sessionBus, err := dbus.SessionBus()
        if err != nil {
            done <- err
            return
        }
        defer sessionBus.Close()

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

    fmt.Printf("\U0001F510 P2P socket: %s\n", secrets.p2pAddress)

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
    fmt.Println("\U0001F510 Sailfish Secrets ready")
    return nil
}

func (s *SailfishSecrets) ensureCollection() error {
    if !s.available || s.collectionVerified {
        return nil
    }
    s.callWithTimeout("createCollection", 2*time.Second,
        COLLECTION_NAME, s.pluginName, s.pluginName,
        []interface{}{int32(DEVICE_LOCK_KEEP_UNLOCKED)},
        []interface{}{int32(ACCESS_CONTROL_OWNER_ONLY)})
    s.collectionVerified = true
    return nil
}

func (s *SailfishSecrets) StoreSecret(name string, data []byte) error {
    if !s.available {
        return fmt.Errorf("not available")
    }
    s.ensureCollection()

    secretId := []interface{}{name, COLLECTION_NAME, s.pluginName}
    s.callWithTimeout("deleteSecret", 2*time.Second, secretId, []interface{}{int32(USER_INTERACTION_SYSTEM)}, "")

    secret := []interface{}{secretId, data, map[string]interface{}{}}
    uiParams := []interface{}{"", "", "", "", []interface{}{int32(0)}, "", map[int32]string{}, []interface{}{int32(0)}, []interface{}{int32(0)}}

    _, err := s.callWithTimeout("setSecret", 3*time.Second, secret, uiParams, []interface{}{int32(USER_INTERACTION_SYSTEM)}, "")
    if err != nil {
        return fmt.Errorf("couldn't store key: %v", err)
    }
    return nil
}

func (s *SailfishSecrets) RetrieveSecret(name string) ([]byte, error) {
    if !s.available {
        return nil, fmt.Errorf("not available")
    }

    body, err := s.callWithTimeout("getSecret", 3*time.Second,
        []interface{}{name, COLLECTION_NAME, s.pluginName},
        []interface{}{int32(USER_INTERACTION_SYSTEM)}, "")
    if err != nil {
        return nil, err
    }

    if len(body) >= 2 {
        resultCode := body[0].([]interface{})
        if resultCode[0].(int32) == 0 {
            secret := body[1].([]interface{})
            return secret[1].([]byte), nil
        }
    }
    return nil, fmt.Errorf("failed")
}

func ClearAllSecrets() {
    if secrets != nil && secrets.available {
        secretId := []interface{}{SECRET_KEY_NAME, COLLECTION_NAME, secrets.pluginName}
        secrets.callWithTimeout("deleteSecret", 2*time.Second, secretId, []interface{}{int32(USER_INTERACTION_SYSTEM)}, "")
        secrets.callWithTimeout("deleteCollection", 2*time.Second, COLLECTION_NAME, secrets.pluginName, []interface{}{int32(USER_INTERACTION_SYSTEM)}, "")
    }
    encryptionKey = nil
}

func GetOrCreateKey() ([]byte, error) {
    if secrets != nil && secrets.available {
        if key, err := secrets.RetrieveSecret(SECRET_KEY_NAME); err == nil && len(key) == 32 {
            fmt.Println("\U0001F510 Encryption key loaded from Sailfish Secrets")
            encryptionKey = key
            return key, nil
        }

        fmt.Println("\U0001F510 Generating new encryption key...")
        key := make([]byte, 32)
        if _, err := rand.Read(key); err != nil {
            return nil, err
        }

        if err := secrets.StoreSecret(SECRET_KEY_NAME, key); err != nil {
            return nil, fmt.Errorf("couldn't store key: %v", err)
        }

        fmt.Println("\U0001F510 Encryption key stored in Sailfish Secrets")
        encryptionKey = key
        return key, nil
    }
    return nil, fmt.Errorf("Sailfish Secrets not available")
}

func Encrypt(data []byte) ([]byte, error) {
    if encryptionKey == nil {
        return nil, fmt.Errorf("no encryption key")
    }
    block, err := aes.NewCipher(encryptionKey)
    if err != nil {
        return nil, err
    }
    gcm, err := cipher.NewGCM(block)
    if err != nil {
        return nil, err
    }
    nonce := make([]byte, gcm.NonceSize())
    if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
        return nil, err
    }
    return gcm.Seal(nonce, nonce, data, nil), nil
}

func Decrypt(data []byte) ([]byte, error) {
    if encryptionKey == nil {
        return nil, fmt.Errorf("no encryption key")
    }
    block, err := aes.NewCipher(encryptionKey)
    if err != nil {
        return nil, err
    }
    gcm, err := cipher.NewGCM(block)
    if err != nil {
        return nil, err
    }
    if len(data) < gcm.NonceSize() {
        return nil, fmt.Errorf("ciphertext too short")
    }
    nonce, ciphertext := data[:gcm.NonceSize()], data[gcm.NonceSize():]
    return gcm.Open(nil, nonce, ciphertext, nil)
}

func EncryptJSON(v interface{}) ([]byte, error) {
    data, err := json.Marshal(v)
    if err != nil {
        return nil, err
    }
    return Encrypt(data)
}

func DecryptJSON(data []byte, v interface{}) error {
    decrypted, err := Decrypt(data)
    if err != nil {
        return err
    }
    return json.Unmarshal(decrypted, v)
}

func LoadEncrypted(filename string, v interface{}) error {
    data, err := os.ReadFile(filename)
    if err != nil {
        return err
    }
    return DecryptJSON(data, v)
}

func SaveEncrypted(filename string, v interface{}) error {
    data, err := EncryptJSON(v)
    if err != nil {
        return err
    }
    return os.WriteFile(filename, data, 0600)
}

func RegenerateKey() ([]byte, error) {
    ClearAllSecrets()
    key, err := GetOrCreateKey()
    return key, err
}
