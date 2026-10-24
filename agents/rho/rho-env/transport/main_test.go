package main

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/pion/webrtc/v4"
)

func TestDirectBytesAndReceiveOverflow(t *testing.T) {
	a, b := &peer{}, &peer{}
	defer a.close()
	defer b.close()
	offer, err := a.call(command{Op: "offer"})
	if err != nil {
		t.Fatal(err)
	}
	answer, err := b.call(command{Op: "answer", SDP: offer["sdp"].(string)})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = a.call(command{Op: "remote", SDP: answer["sdp"].(string)}); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(10 * time.Second)
	for {
		state, err := a.call(command{Op: "poll"})
		if err != nil {
			t.Fatal(err)
		}
		if state["ready"] == true {
			pair := state["pair"].([]string)
			if pair[0] != "host" || pair[1] != "host" {
				t.Fatalf("unexpected pair: %v", pair)
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("connection timeout")
		}
		time.Sleep(time.Millisecond)
	}
	replies := make(chan string, 1)
	b.permission.OnMessage(func(m webrtc.DataChannelMessage) { replies <- string(m.Data) })
	for b.permission.ReadyState() != webrtc.DataChannelStateOpen {
		if time.Now().After(deadline) {
			t.Fatal("permission channel timeout")
		}
		time.Sleep(time.Millisecond)
	}
	if err = b.permission.SendText("7"); err != nil {
		t.Fatal(err)
	}
	for {
		result, err := a.call(command{Op: "poll"})
		if err != nil {
			t.Fatal(err)
		}
		if result["permission"] == uint64(7) {
			if len(result["data"].([]receivedBlock)) != 0 {
				t.Fatal("permission probe became tool input")
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("permission probe missing")
		}
		time.Sleep(time.Millisecond)
	}
	result, err := a.call(command{Op: "poll"})
	if err != nil || result["permission"] != uint64(0) {
		t.Fatal("permission probe replayed")
	}
	if _, err = a.call(command{Op: "permission", Nonce: 7, MaxAge: 320}); err != nil {
		t.Fatal(err)
	}
	select {
	case raw := <-replies:
		var reply struct {
			Nonce  uint64 `json:"nonce"`
			MaxAge int    `json:"max_age_ms"`
		}
		if json.Unmarshal([]byte(raw), &reply) != nil || reply.Nonce != 7 || reply.MaxAge != 320 {
			t.Fatalf("incorrect remaining window: %s", raw)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("permission response missing")
	}
	if _, err = a.call(command{Op: "permission", Nonce: 7, MaxAge: 1001}); err == nil {
		t.Fatal("unbounded permission accepted")
	}
	encoded := base64.StdEncoding.EncodeToString([]byte("terminal\x00bytes"))
	if _, err = a.call(command{Op: "send", Data: encoded}); err != nil {
		t.Fatal(err)
	}
	for {
		result, err := b.call(command{Op: "poll"})
		if err != nil {
			t.Fatal(err)
		}
		data := result["data"].([]receivedBlock)
		if len(data) > 0 {
			if len(data) != 1 || data[0].Bytes != encoded {
				t.Fatalf("wrong bytes: %v", data)
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("delivery timeout")
		}
		time.Sleep(time.Millisecond)
	}
	oversized := base64.StdEncoding.EncodeToString([]byte(strings.Repeat("x", maxBytes+1)))
	if _, err := a.call(command{Op: "send", Data: oversized}); err == nil {
		t.Fatal("oversized block accepted")
	}
	for range 5 {
		if _, err := a.call(command{Op: "send", Data: encoded}); err != nil {
			t.Fatal(err)
		}
	}
	for {
		b.mu.Lock()
		overflow := b.overflow
		size := len(b.incoming)
		b.mu.Unlock()
		if overflow {
			if size > 4 {
				t.Fatal("receive queue exceeded bound")
			}
			if _, err := b.call(command{Op: "poll"}); err == nil {
				t.Fatal("overflow concealed")
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("overflow not observed")
		}
		time.Sleep(time.Millisecond)
	}
}
