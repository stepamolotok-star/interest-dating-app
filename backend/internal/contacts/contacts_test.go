package contacts

import (
	"bytes"
	"encoding/hex"
	"testing"
)

// Тот же вектор проверяется в приложении (mobile/test/contacts_test.dart):
// хэш на телефоне и на сервере обязан совпадать.
const vectorPhone, vectorHash = "+79141234567", "e19773badb6a9e9c6d6f3973c30779dbc14120576cb7e60d4634baf6b2ddb0fc"

func TestPhoneHashMatchesApp(t *testing.T) {
	if got := hex.EncodeToString(PhoneHash(vectorPhone)); got != vectorHash {
		t.Fatalf("PhoneHash = %s", got)
	}
}

func TestKeyDependsOnSecret(t *testing.T) {
	h := PhoneHash(vectorPhone)
	if bytes.Equal(Key([]byte("a"), h), Key([]byte("b"), h)) {
		t.Fatal("ключ должен зависеть от секрета")
	}
	if !bytes.Equal(PhoneKey([]byte("a"), vectorPhone), Key([]byte("a"), h)) {
		t.Fatal("PhoneKey = Key(секрет, PhoneHash)")
	}
}
