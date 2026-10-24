package main

import (
	"bufio"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/creack/pty"
	"github.com/pion/webrtc/v4"
	"golang.org/x/term"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"
)

type inputMessage struct {
	Kind       string `json:"kind"`
	Connection string `json:"connection"`
	Seq        uint64 `json:"seq"`
}
type sampleResult struct {
	Seq          uint64  `json:"seq"`
	Milliseconds float64 `json:"ms"`
	Error        string  `json:"error,omitempty"`
}
type peer struct {
	mu                                                                                     sync.Mutex
	runner                                                                                 bool
	pc                                                                                     *webrtc.PeerConnection
	control, terminalData, media                                                           *webrtc.DataChannel
	connection                                                                             string
	allowedUntil                                                                           time.Time
	stopped, load                                                                          bool
	nextSeq, lastApplied, applied, rejected, outputBytes, mediaBytes, frames, peakBuffered uint64
	pending                                                                                map[uint64]chan inputMessage
	frameStarts                                                                            map[uint64]time.Time
	frameRTT                                                                               []float64
	frameParts                                                                             map[uint64]uint16
	samples                                                                                []sampleResult
	inputQueue                                                                             chan inputMessage
	terminal                                                                               *os.File
	child                                                                                  *exec.Cmd
	pid                                                                                    int
	childExited                                                                            bool
}

func newPeer(runner bool) (*peer, error) {
	p := &peer{runner: runner, pending: map[uint64]chan inputMessage{}, frameStarts: map[uint64]time.Time{}, frameParts: map[uint64]uint16{}, inputQueue: make(chan inputMessage, 32)}
	if runner {
		path, err := os.Executable()
		if err != nil {
			return nil, err
		}
		p.child = exec.Command(path, "-role", "fixture")
		p.terminal, err = pty.Start(p.child)
		if err != nil {
			return nil, err
		}
		if _, err = term.MakeRaw(int(p.terminal.Fd())); err != nil {
			p.close()
			return nil, err
		}
		p.pid = p.child.Process.Pid
		go p.readPTY()
		go p.runInputs()
		go p.produceLoad()
	}
	return p, nil
}
func (p *peer) close() {
	p.mu.Lock()
	p.stopped = true
	pc := p.pc
	terminal := p.terminal
	child := p.child
	p.child = nil
	p.mu.Unlock()
	if pc != nil {
		_ = pc.Close()
	}
	if child != nil {
		_ = child.Process.Kill()
		_ = child.Wait()
		p.mu.Lock()
		p.childExited = true
		p.mu.Unlock()
	}
	if terminal != nil {
		_ = terminal.Close()
	}
}
func (p *peer) routes(mux *http.ServeMux) {
	mux.HandleFunc("POST /connect", func(w http.ResponseWriter, r *http.Request) {
		var cfg struct{ Mode, TURN, Connection string }
		err := decode(r, &cfg)
		if err == nil {
			err = p.connect(cfg.Mode, cfg.TURN, cfg.Connection)
		}
		respond(w, map[string]bool{"ok": err == nil}, err)
	})
	mux.HandleFunc("POST /offer", func(w http.ResponseWriter, r *http.Request) { s, e := p.description(nil); respond(w, s, e) })
	mux.HandleFunc("POST /answer", func(w http.ResponseWriter, r *http.Request) {
		var s webrtc.SessionDescription
		e := decode(r, &s)
		var out *webrtc.SessionDescription
		if e == nil {
			out, e = p.description(&s)
		}
		respond(w, out, e)
	})
	mux.HandleFunc("POST /remote", func(w http.ResponseWriter, r *http.Request) {
		var s webrtc.SessionDescription
		e := decode(r, &s)
		p.mu.Lock()
		pc := p.pc
		p.mu.Unlock()
		if e == nil {
			e = pc.SetRemoteDescription(s)
		}
		respond(w, map[string]bool{"ok": e == nil}, e)
	})
	mux.HandleFunc("POST /gate", func(w http.ResponseWriter, r *http.Request) {
		var g struct {
			Allow, Terminal bool
			ValidForMS      int
		}
		e := decode(r, &g)
		if e == nil && (g.ValidForMS < 0 || g.ValidForMS > 1000) {
			e = errors.New("invalid authorization window")
		}
		if e == nil {
			p.mu.Lock()
			p.allowedUntil = time.Time{}
			if g.Allow && !p.stopped {
				p.allowedUntil = time.Now().Add(time.Duration(g.ValidForMS) * time.Millisecond)
			}
			p.mu.Unlock()
			if g.Terminal {
				p.close()
			}
		}
		respond(w, map[string]bool{"ok": e == nil}, e)
	})
	mux.HandleFunc("POST /load", func(w http.ResponseWriter, r *http.Request) {
		var v struct{ Enabled bool }
		e := decode(r, &v)
		if e == nil {
			p.mu.Lock()
			p.load = v.Enabled
			p.mu.Unlock()
		}
		respond(w, map[string]bool{"ok": e == nil}, e)
	})
	mux.HandleFunc("POST /sample", func(w http.ResponseWriter, r *http.Request) {
		var v struct{ Connection string }
		e := decode(r, &v)
		if e != nil {
			respond(w, nil, e)
			return
		}
		respond(w, p.sample(v.Connection), nil)
	})
	mux.HandleFunc("GET /stats", func(w http.ResponseWriter, r *http.Request) { respond(w, p.stats(), nil) })
}
func (p *peer) connect(mode, turnURL, id string) error {
	if mode != "direct" && mode != "relay" && mode != "auto" {
		return errors.New("invalid path mode")
	}
	if id == "" {
		return errors.New("connection id required")
	}
	p.mu.Lock()
	if p.stopped {
		p.mu.Unlock()
		return errors.New("task stopped")
	}
	old := p.pc
	p.connection = id
	p.pc = nil
	p.control = nil
	p.terminalData = nil
	p.media = nil
	p.frameParts = map[uint64]uint16{}
	p.frameStarts = map[uint64]time.Time{}
	p.mu.Unlock()
	if old != nil {
		_ = old.Close()
	}
	config := webrtc.Configuration{}
	if mode != "direct" {
		config.ICEServers = []webrtc.ICEServer{{URLs: []string{turnURL}, Username: "fixture", Credential: "isolated-fixture"}}
	}
	if mode == "relay" {
		config.ICETransportPolicy = webrtc.ICETransportPolicyRelay
	}
	settings := webrtc.SettingEngine{}
	settings.SetNetworkTypes([]webrtc.NetworkType{webrtc.NetworkTypeUDP4})
	settings.SetICETimeouts(time.Second, 4*time.Second, 200*time.Millisecond)
	pc, err := webrtc.NewAPI(webrtc.WithSettingEngine(settings)).NewPeerConnection(config)
	if err != nil {
		return err
	}
	negotiated := true
	ordered := true
	unordered := false
	zero := uint16(0)
	ids := []uint16{0, 1, 2}
	labels := []string{"control", "terminal", "media"}
	channels := make([]*webrtc.DataChannel, 3)
	for i := range ids {
		init := &webrtc.DataChannelInit{Negotiated: &negotiated, ID: &ids[i], Ordered: &ordered}
		if i == 2 {
			init.Ordered = &unordered
			init.MaxRetransmits = &zero
		}
		channels[i], err = pc.CreateDataChannel(labels[i], init)
		if err != nil {
			_ = pc.Close()
			return err
		}
	}
	channels[0].OnMessage(func(m webrtc.DataChannelMessage) { p.onControl(id, m) })
	channels[1].OnMessage(func(m webrtc.DataChannelMessage) {
		p.mu.Lock()
		if p.connection == id && !p.stopped && time.Now().Before(p.allowedUntil) {
			p.outputBytes += uint64(len(m.Data))
		}
		p.mu.Unlock()
	})
	channels[2].OnMessage(func(m webrtc.DataChannelMessage) { p.onMedia(id, m.Data) })
	p.mu.Lock()
	p.pc = pc
	p.control = channels[0]
	p.terminalData = channels[1]
	p.media = channels[2]
	p.mu.Unlock()
	return nil
}
func (p *peer) description(remote *webrtc.SessionDescription) (*webrtc.SessionDescription, error) {
	p.mu.Lock()
	pc := p.pc
	p.mu.Unlock()
	if pc == nil {
		return nil, errors.New("not connected")
	}
	var s webrtc.SessionDescription
	var err error
	if remote == nil {
		s, err = pc.CreateOffer(nil)
	} else {
		err = pc.SetRemoteDescription(*remote)
		if err == nil {
			s, err = pc.CreateAnswer(nil)
		}
	}
	if err != nil {
		return nil, err
	}
	gather := webrtc.GatheringCompletePromise(pc)
	if err = pc.SetLocalDescription(s); err != nil {
		return nil, err
	}
	select {
	case <-gather:
		return pc.LocalDescription(), nil
	case <-time.After(10 * time.Second):
		return nil, errors.New("ICE gathering timed out")
	}
}
func (p *peer) onControl(id string, m webrtc.DataChannelMessage) {
	var v inputMessage
	if json.Unmarshal(m.Data, &v) != nil {
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if id != p.connection || v.Connection != id || p.stopped || !time.Now().Before(p.allowedUntil) {
		p.rejected++
		return
	}
	switch v.Kind {
	case "input":
		if !p.runner {
			return
		}
		select {
		case p.inputQueue <- v:
		default:
			p.rejected++
		}
	case "applied":
		if ch, ok := p.pending[v.Seq]; ok {
			select {
			case ch <- v:
			default:
			}
		}
	case "frame":
		if t, ok := p.frameStarts[v.Seq]; ok {
			p.frameRTT = append(p.frameRTT, float64(time.Since(t).Microseconds())/1000)
			delete(p.frameStarts, v.Seq)
		}
	}
}
func (p *peer) runInputs() {
	for v := range p.inputQueue {
		p.mu.Lock()
		if p.stopped || v.Connection != p.connection || !time.Now().Before(p.allowedUntil) || v.Seq <= p.lastApplied {
			p.rejected++
			p.mu.Unlock()
			continue
		}
		p.lastApplied = v.Seq
		p.applied++
		terminal := p.terminal
		_, err := fmt.Fprintf(terminal, "%d:%s\n", v.Seq, v.Connection)
		p.mu.Unlock()
		if err != nil {
			return
		}
	}
}
func (p *peer) readPTY() {
	scanner := bufio.NewScanner(p.terminal)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if !strings.HasPrefix(line, "done:") {
			continue
		}
		parts := strings.SplitN(strings.TrimPrefix(line, "done:"), ":", 2)
		if len(parts) != 2 {
			continue
		}
		seq, err := strconv.ParseUint(parts[0], 10, 64)
		if err != nil {
			continue
		}
		p.mu.Lock()
		if parts[1] == p.connection && !p.stopped && time.Now().Before(p.allowedUntil) {
			data, _ := json.Marshal(inputMessage{Kind: "applied", Connection: parts[1], Seq: seq})
			if p.control != nil {
				_ = p.control.Send(data)
			}
		}
		p.mu.Unlock()
	}
}
func (p *peer) sample(override string) sampleResult {
	p.mu.Lock()
	p.nextSeq++
	seq := p.nextSeq
	id := p.connection
	dc := p.control
	allowed := !p.stopped && time.Now().Before(p.allowedUntil)
	ch := make(chan inputMessage, 1)
	p.pending[seq] = ch
	p.mu.Unlock()
	defer func() { p.mu.Lock(); delete(p.pending, seq); p.mu.Unlock() }()
	result := sampleResult{Seq: seq}
	started := time.Now()
	if !allowed || dc == nil || dc.ReadyState() != webrtc.DataChannelStateOpen {
		result.Error = "not_authorized_or_disconnected"
		return result
	}
	if override != "" {
		id = override
	}
	data, _ := json.Marshal(inputMessage{Kind: "input", Connection: id, Seq: seq})
	if err := dc.Send(data); err != nil {
		result.Error = err.Error()
		return result
	}
	select {
	case <-ch:
		result.Milliseconds = float64(time.Since(started).Microseconds()) / 1000
	case <-time.After(2 * time.Second):
		result.Error = "outcome_unknown"
		result.Milliseconds = 2000
	}
	p.mu.Lock()
	p.samples = append(p.samples, result)
	p.mu.Unlock()
	return result
}
func (p *peer) produceLoad() {
	terminalTick := time.NewTicker(time.Second / 16)
	mediaTick := time.NewTicker(time.Second / 10)
	defer terminalTick.Stop()
	defer mediaTick.Stop()
	terminalBytes := make([]byte, 16*1024)
	frame := uint64(0)
	for {
		select {
		case <-terminalTick.C:
			p.mu.Lock()
			if p.stopped {
				p.mu.Unlock()
				return
			}
			if p.load && time.Now().Before(p.allowedUntil) && p.terminalData != nil && p.terminalData.ReadyState() == webrtc.DataChannelStateOpen {
				p.sendBounded(p.terminalData, terminalBytes)
			}
			p.mu.Unlock()
		case <-mediaTick.C:
			p.mu.Lock()
			if p.stopped {
				p.mu.Unlock()
				return
			}
			if p.load && time.Now().Before(p.allowedUntil) && p.media != nil && p.media.ReadyState() == webrtc.DataChannelStateOpen {
				frame++
				for key := range p.frameStarts {
					if key+20 <= frame {
						delete(p.frameStarts, key)
					}
				}
				p.frameStarts[frame] = time.Now()
				for part := uint16(0); part < 4; part++ {
					data := make([]byte, 16*1024)
					binary.BigEndian.PutUint64(data[:8], frame)
					binary.BigEndian.PutUint16(data[8:10], part)
					p.sendBounded(p.media, data)
				}
			}
			p.mu.Unlock()
		}
	}
}
func (p *peer) sendBounded(dc *webrtc.DataChannel, data []byte) {
	buffered := dc.BufferedAmount()
	if buffered > p.peakBuffered {
		p.peakBuffered = buffered
	}
	if buffered+uint64(len(data)) <= 1024*1024 {
		_ = dc.Send(data)
	}
}
func (p *peer) onMedia(id string, data []byte) {
	if len(data) < 10 {
		return
	}
	frame := binary.BigEndian.Uint64(data[:8])
	part := binary.BigEndian.Uint16(data[8:10])
	if part >= 4 {
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.connection != id || p.stopped || !time.Now().Before(p.allowedUntil) {
		return
	}
	p.mediaBytes += uint64(len(data))
	p.frameParts[frame] |= 1 << part
	if p.frameParts[frame] == 15 {
		p.frames++
		delete(p.frameParts, frame)
		ack, _ := json.Marshal(inputMessage{Kind: "frame", Connection: id, Seq: frame})
		_ = p.control.Send(ack)
	}
	for key := range p.frameParts {
		if key+20 < frame {
			delete(p.frameParts, key)
		}
	}
}
func (p *peer) stats() map[string]any {
	p.mu.Lock()
	defer p.mu.Unlock()
	s := map[string]any{"runner": p.runner, "connection": p.connection, "authorized": !p.stopped && time.Now().Before(p.allowedUntil), "stopped": p.stopped, "pid": p.pid, "child_exited": p.childExited, "applied": p.applied, "rejected": p.rejected, "terminal_bytes": p.outputBytes, "media_bytes": p.mediaBytes, "frames": p.frames, "frame_rtt_ms": append([]float64{}, p.frameRTT...), "peak_buffered": p.peakBuffered, "samples": append([]sampleResult{}, p.samples...), "process": processStats()}
	if p.pc != nil {
		s["state"] = p.pc.ConnectionState().String()
		if p.pc.SCTP() != nil {
			t := p.pc.SCTP().Transport().ICETransport()
			if pair, e := t.GetSelectedCandidatePair(); e == nil && pair != nil {
				s["pair"] = map[string]any{"local": pair.Local.Typ.String(), "remote": pair.Remote.Typ.String(), "local_address": pair.Local.Address, "remote_address": pair.Remote.Address}
			}
		}
	}
	if p.control != nil {
		s["control_state"] = p.control.ReadyState().String()
	}
	return s
}
