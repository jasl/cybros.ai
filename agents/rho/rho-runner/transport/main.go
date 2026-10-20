// A handler-owned WebRTC byte transport. Execution and permission stay in Ruby.
package main

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"sync"
	"time"

	"github.com/pion/webrtc/v4"
)

const maxBytes = 16 * 1024
const maxBuffered = 64 * 1024

type command struct {
	Nonce   uint64             `json:"nonce"`
	MaxAge  int                `json:"max_age_ms"`
	Op      string             `json:"op"`
	SDP     string             `json:"sdp"`
	Data    string             `json:"data"`
	Relay   bool               `json:"relay"`
	Servers []webrtc.ICEServer `json:"servers"`
}
type received struct {
	data []byte
	at   time.Time
}
type receivedBlock struct {
	Bytes      string  `json:"bytes"`
	AgeSeconds float64 `json:"age_seconds"`
}
type peer struct {
	permission *webrtc.DataChannel
	nonce      uint64
	pc         *webrtc.PeerConnection
	dc         *webrtc.DataChannel
	mu         sync.Mutex
	incoming   []received
	overflow   bool
	pair       []string
}

func main() {
	p := &peer{}
	defer p.close()
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 4096), 128*1024)
	out := json.NewEncoder(os.Stdout)
	for scanner.Scan() {
		var c command
		value := map[string]any{}
		err := json.Unmarshal(scanner.Bytes(), &c)
		if err == nil {
			value, err = p.call(c)
		}
		if err != nil {
			value = map[string]any{"error": "transport request failed"}
		}
		if out.Encode(value) != nil {
			return
		}
	}
}
func (p *peer) close() {
	if p.pc != nil {
		_ = p.pc.Close()
		p.pc = nil
	}
}
func (p *peer) call(c command) (map[string]any, error) {
	switch c.Op {
	case "offer", "answer":
		if p.pc != nil {
			return nil, errors.New("already started")
		}
		config := webrtc.Configuration{ICEServers: c.Servers}
		if c.Relay {
			config.ICETransportPolicy = webrtc.ICETransportPolicyRelay
		}
		settings := webrtc.SettingEngine{}
		settings.SetIncludeLoopbackCandidate(true)
		pc, err := webrtc.NewAPI(webrtc.WithSettingEngine(settings)).NewPeerConnection(config)
		if err != nil {
			return nil, err
		}
		p.pc = pc
		ordered, negotiated, permissionID := true, true, uint16(1)
		p.permission, err = pc.CreateDataChannel("permission", &webrtc.DataChannelInit{Ordered: &ordered, Negotiated: &negotiated, ID: &permissionID})
		if err != nil {
			return nil, err
		}
		p.permission.OnMessage(func(m webrtc.DataChannelMessage) {
			// One replaceable probe, never a queued input or an authority grant.
			var nonce uint64
			if len(m.Data) > 16 || json.Unmarshal(m.Data, &nonce) != nil || nonce == 0 || nonce > 9007199254740991 {
				return
			}
			p.mu.Lock()
			p.nonce = nonce
			p.mu.Unlock()
		})
		pc.SCTP().Transport().ICETransport().OnSelectedCandidatePairChange(func(pair *webrtc.ICECandidatePair) {
			p.mu.Lock()
			p.pair = []string{pair.Local.Typ.String(), pair.Remote.Typ.String()}
			p.mu.Unlock()
		})
		ordered, negotiated, id := true, true, uint16(0)
		p.dc, err = pc.CreateDataChannel("terminal", &webrtc.DataChannelInit{Ordered: &ordered, Negotiated: &negotiated, ID: &id})
		if err != nil {
			return nil, err
		}
		p.dc.OnMessage(func(m webrtc.DataChannelMessage) {
			p.mu.Lock()
			defer p.mu.Unlock()
			if len(m.Data) > maxBytes || len(p.incoming) >= 4 {
				p.overflow = true
				return
			}
			p.incoming = append(p.incoming, received{data: append([]byte(nil), m.Data...), at: time.Now()})
		})
		var desc webrtc.SessionDescription
		if c.Op == "answer" {
			err = pc.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeOffer, SDP: c.SDP})
			if err == nil {
				desc, err = pc.CreateAnswer(nil)
			}
		} else {
			desc, err = pc.CreateOffer(nil)
		}
		if err != nil {
			return nil, err
		}
		gathered := webrtc.GatheringCompletePromise(pc)
		if err = pc.SetLocalDescription(desc); err != nil {
			return nil, err
		}
		select {
		case <-gathered:
		case <-time.After(10 * time.Second):
			return nil, errors.New("gather timeout")
		}
		return map[string]any{"sdp": pc.LocalDescription().SDP}, nil
	case "remote":
		if p.pc == nil {
			return nil, errors.New("not started")
		}
		return map[string]any{}, p.pc.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeAnswer, SDP: c.SDP})
	case "send":
		data, err := base64.StdEncoding.DecodeString(c.Data)
		if err != nil || len(data) > maxBytes {
			return nil, errors.New("invalid bytes")
		}
		if p.dc == nil || p.dc.ReadyState() != webrtc.DataChannelStateOpen || p.dc.BufferedAmount()+uint64(len(data)) > maxBuffered {
			return nil, errors.New("not writable")
		}
		return map[string]any{}, p.dc.Send(data)
	case "permission":
		if c.Nonce == 0 || c.Nonce > 9007199254740991 || c.MaxAge < 0 || c.MaxAge > 1000 ||
			p.permission == nil || p.permission.ReadyState() != webrtc.DataChannelStateOpen ||
			p.permission.BufferedAmount() > 1024 {
			return nil, errors.New("permission channel unavailable")
		}
		data, err := json.Marshal(map[string]any{"nonce": c.Nonce, "max_age_ms": c.MaxAge})
		if err != nil {
			return nil, err
		}
		return map[string]any{}, p.permission.SendText(string(data))
	case "poll":
		if p.pc == nil {
			return nil, errors.New("not started")
		}
		p.mu.Lock()
		data, overflow, pair, nonce := p.incoming, p.overflow, p.pair, p.nonce
		p.incoming = nil
		p.nonce = 0
		p.mu.Unlock()
		if overflow {
			return nil, errors.New("receive overflow")
		}
		encoded := make([]receivedBlock, 0, len(data))
		for _, b := range data {
			encoded = append(encoded, receivedBlock{Bytes: base64.StdEncoding.EncodeToString(b.data), AgeSeconds: time.Since(b.at).Seconds()})
		}
		result := map[string]any{"data": encoded, "state": p.pc.ConnectionState().String(), "ready": p.dc.ReadyState() == webrtc.DataChannelStateOpen}
		result["permission"] = nonce
		if pair != nil {
			result["pair"] = pair
		}
		return result, nil
	default:
		return nil, errors.New("unknown operation")
	}
}
