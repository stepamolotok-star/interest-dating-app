package auth

import (
	"strings"
	"testing"
)

func TestSMSTextHasCodeAsWord(t *testing.T) {
	txt := SMSText("4821")
	if !strings.Contains(txt, " 4821.") {
		t.Fatalf("код должен стоять отдельным словом: %q", txt)
	}
}
