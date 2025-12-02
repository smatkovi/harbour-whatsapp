package main

import (
    "crypto/aes"
    "crypto/cipher"
    "crypto/rand"
    "encoding/json"
    "fmt"
    "io"

    "github.com/godbus/dbus/v5"
)

const (
    COLLECTION_NAME = "whatsapp-systemd"
    SECRET_KEY_NAME = "encryption-key"
    DEFAULT_PLUGIN  = "org.sailfishos.secrets.plugin.encryptedstorage.sqlcipher"
    
    USER_INTERACTION_SYSTEM     = 2
    DEVICE_LOCK_KEEP_UNLOCKED   = 0
    ACCESS_CONTROL_OWNER_ONLY   = 0
    ERROR_COLLECTION_EXISTS     = 3
    ERROR_COLLECTION_EXISTS_2   = 46
    ERROR_COLLECTION_OWNED      = 10
)

type SailfishSecrets struct {
    p2pAddress         string
    pluginName         string
    available          bool
    collectionVerified bool
}

var secrets *SailfishSecrets
var encryptionKey []byte

// getConnection creates a fresh P2P connection for each call
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

// InitSecrets initializes the Sailfish Secrets connection
func InitSecrets() error {
    secrets = &SailfishSecrets{
        pluginName: DEFAULT_PLUGIN,
    }
    
    // Connect to Session Bus to get P2P address
    sessionBus, err := dbus.SessionBus()
    if err != nil {
        return fmt.Errorf("D-Bus session bus error: %v", err)
    }
    defer sessionBus.Close()
    
    // Get P2P socket address from Discovery Service
    obj := sessionBus.Object(
        "org.sailfishos.secrets.daemon.discovery",
        "/Sailfish/Secrets/Discovery",
    )
    
    err = obj.Call("org.sailfishos.secrets.daemon.discovery.peerToPeerAddress", 0).Store(&secrets.p2pAddress)
    if err != nil {
        return fmt.Errorf("discovery error: %v", err)
    }
    
    fmt.Printf("🔐 P2P socket: %s\n", secrets.p2pAddress)
    
    // Test connection
    conn, err := secrets.getConnection()
    if err != nil {
        return fmt.Errorf("P2P connect error: %v", err)
    }
    conn.Close()
    
    secrets.available = true
    fmt.Println("🔐 Sailfish Secrets ready")
    
    return nil
}

// call makes a D-Bus call with a fresh connection
func (s *SailfishSecrets) call(method string, args ...interface{}) ([]interface{}, error) {
    conn, err := s.getConnection()
    if err != nil {
        return nil, err
    }
    defer conn.Close()
    
    obj := conn.Object("", "/Sailfish/Secrets")
    call := obj.Call("org.sailfishos.secrets."+method, 0, args...)
    
    if call.Err != nil {
        return nil, call.Err
    }
    
    return call.Body, nil
}

// ensureCollection creates the collection if it doesn't exist
func (s *SailfishSecrets) ensureCollection() error {
    if !s.available {
        return fmt.Errorf("secrets not available")
    }
    
    if s.collectionVerified {
        return nil
    }
    
    body, err := s.call("createCollection",
        COLLECTION_NAME,
        s.pluginName,
        s.pluginName,
        []interface{}{int32(DEVICE_LOCK_KEEP_UNLOCKED)},
        []interface{}{int32(ACCESS_CONTROL_OWNER_ONLY)},
    )
    
    if err != nil {
        fmt.Printf("🔐 createCollection error: %v\n", err)
        // May already exist, continue
    }
    
    if body != nil && len(body) >= 3 {
        code := body[0].(int32)
        errorCode := body[1].(int32)
        
        if code == 0 {
            fmt.Println("🔐 Collection created")
        } else if errorCode == ERROR_COLLECTION_EXISTS || errorCode == ERROR_COLLECTION_EXISTS_2 {
            fmt.Println("🔐 Collection already exists")
        } else if errorCode == ERROR_COLLECTION_OWNED {
            return fmt.Errorf("collection owned by different app")
        }
    }
    
    s.collectionVerified = true
    return nil
}

// deleteSecretSilent deletes a secret without returning errors
func (s *SailfishSecrets) deleteSecretSilent(name string) {
    if !s.available {
        return
    }
    
    secretId := []interface{}{name, COLLECTION_NAME, s.pluginName}
    
    s.call("deleteSecret",
        secretId,
        []interface{}{int32(USER_INTERACTION_SYSTEM)},
        "",
    )
}

// StoreSecret stores a secret - ALWAYS deletes existing secret first
func (s *SailfishSecrets) StoreSecret(name string, data []byte) error {
    if !s.available {
        return fmt.Errorf("secrets not available")
    }
    
    if err := s.ensureCollection(); err != nil {
        return err
    }
    
    // Always delete existing secret first
    s.deleteSecretSilent(name)
    
    secretId := []interface{}{name, COLLECTION_NAME, s.pluginName}
    
    secret := []interface{}{
        secretId,
        data,
        map[string]interface{}{},
    }
    
    uiParams := []interface{}{
        "", "", "", "",
        []interface{}{int32(0)},
        "",
        map[int32]string{},
        []interface{}{int32(0)},
        []interface{}{int32(0)},
    }
    
    body, err := s.call("setSecret",
        secret,
        uiParams,
        []interface{}{int32(USER_INTERACTION_SYSTEM)},
        "",
    )
    
    if err != nil {
        s.collectionVerified = false
        return err
    }
    
    if body != nil && len(body) >= 1 {
        code := body[0].(int32)
        if code != 0 {
            s.collectionVerified = false
            return fmt.Errorf("setSecret failed: code=%d", code)
        }
    }
    
    fmt.Printf("🔐 Stored secret '%s'\n", name)
    return nil
}

// RetrieveSecret retrieves a secret
func (s *SailfishSecrets) RetrieveSecret(name string) ([]byte, error) {
    if !s.available {
        return nil, fmt.Errorf("secrets not available")
    }
    
    secretId := []interface{}{name, COLLECTION_NAME, s.pluginName}
    
    body, err := s.call("getSecret",
        secretId,
        []interface{}{int32(USER_INTERACTION_SYSTEM)},
        "",
    )
    
    if err != nil {
        return nil, err
    }
    
    if body != nil && len(body) >= 2 {
        resultCode := body[0].([]interface{})
        code := resultCode[0].(int32)
        
        if code != 0 {
            return nil, fmt.Errorf("getSecret failed: code=%d", code)
        }
        
        secret := body[1].([]interface{})
        data := secret[1].([]byte)
        return data, nil
    }
    
    return nil, fmt.Errorf("unexpected response")
}

// DeleteSecret deletes a secret
func (s *SailfishSecrets) DeleteSecret(name string) error {
    if !s.available {
        return fmt.Errorf("secrets not available")
    }
    
    secretId := []interface{}{name, COLLECTION_NAME, s.pluginName}
    
    _, err := s.call("deleteSecret",
        secretId,
        []interface{}{int32(USER_INTERACTION_SYSTEM)},
        "",
    )
    
    return err
}

// DeleteCollection deletes the entire collection
func (s *SailfishSecrets) DeleteCollection() error {
    if !s.available {
        return fmt.Errorf("secrets not available")
    }
    
    _, err := s.call("deleteCollection",
        COLLECTION_NAME,
        s.pluginName,
        []interface{}{int32(USER_INTERACTION_SYSTEM)},
        "",
    )
    
    s.collectionVerified = false
    fmt.Println("🔐 Collection deleted")
    return err
}

// ClearAllSecrets deletes all secrets and the collection
func ClearAllSecrets() {
    if secrets == nil || !secrets.available {
        return
    }
    
    secrets.deleteSecretSilent(SECRET_KEY_NAME)
    secrets.DeleteCollection()
    encryptionKey = nil
    
    fmt.Println("🔐 All secrets cleared")
}

// GetOrCreateKey gets the encryption key from secrets or creates a new one
func GetOrCreateKey() ([]byte, error) {
    if secrets == nil || !secrets.available {
        return nil, fmt.Errorf("Sailfish Secrets not available")
    }
    
    // Try to retrieve existing key
    keyData, err := secrets.RetrieveSecret(SECRET_KEY_NAME)
    if err == nil && len(keyData) == 32 {
        fmt.Println("🔐 Loaded encryption key from Sailfish Secrets")
        return keyData, nil
    }
    
    fmt.Println("🔐 Generating new encryption key...")
    
    // Generate new key
    key := make([]byte, 32)
    if _, err := rand.Read(key); err != nil {
        return nil, err
    }
    
    // Store it
    if err := secrets.StoreSecret(SECRET_KEY_NAME, key); err != nil {
        return nil, fmt.Errorf("couldn't store key: %v", err)
    }
    
    fmt.Println("🔐 Encryption key stored in Sailfish Secrets")
    return key, nil
}

// RegenerateKey forces creation of a new encryption key
func RegenerateKey() ([]byte, error) {
    if secrets == nil || !secrets.available {
        return nil, fmt.Errorf("Sailfish Secrets not available")
    }
    
    secrets.deleteSecretSilent(SECRET_KEY_NAME)
    
    key := make([]byte, 32)
    if _, err := rand.Read(key); err != nil {
        return nil, err
    }
    
    if err := secrets.StoreSecret(SECRET_KEY_NAME, key); err != nil {
        return nil, err
    }
    
    encryptionKey = key
    fmt.Println("🔐 New encryption key generated and stored")
    return key, nil
}

// Encrypt encrypts data using AES-256-GCM
func Encrypt(plaintext []byte) ([]byte, error) {
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
    
    ciphertext := gcm.Seal(nonce, nonce, plaintext, nil)
    return ciphertext, nil
}

// Decrypt decrypts data using AES-256-GCM
func Decrypt(ciphertext []byte) ([]byte, error) {
    if encryptionKey == nil {
        return nil, fmt.Errorf("no encryption key")
    }
    
    if len(ciphertext) == 0 {
        return nil, fmt.Errorf("empty ciphertext")
    }
    
    block, err := aes.NewCipher(encryptionKey)
    if err != nil {
        return nil, err
    }
    
    gcm, err := cipher.NewGCM(block)
    if err != nil {
        return nil, err
    }
    
    nonceSize := gcm.NonceSize()
    if len(ciphertext) < nonceSize {
        return nil, fmt.Errorf("ciphertext too short")
    }
    
    nonce, ciphertext := ciphertext[:nonceSize], ciphertext[nonceSize:]
    plaintext, err := gcm.Open(nil, nonce, ciphertext, nil)
    if err != nil {
        return nil, err
    }
    
    return plaintext, nil
}

// EncryptJSON encrypts a struct as JSON
func EncryptJSON(v interface{}) ([]byte, error) {
    data, err := json.Marshal(v)
    if err != nil {
        return nil, err
    }
    return Encrypt(data)
}

// DecryptJSON decrypts and unmarshals JSON
func DecryptJSON(ciphertext []byte, v interface{}) error {
    plaintext, err := Decrypt(ciphertext)
    if err != nil {
        return err
    }
    return json.Unmarshal(plaintext, v)
}

// SaveEncrypted saves encrypted data to a file
func SaveEncrypted(filename string, v interface{}) error {
    data, err := EncryptJSON(v)
    if err != nil {
        return err
    }
    return writeFileAtomic(filename, data)
}

// LoadEncrypted loads and decrypts data from a file
func LoadEncrypted(filename string, v interface{}) error {
    data, err := readFileBytes(filename)
    if err != nil {
        return err
    }
    return DecryptJSON(data, v)
}
