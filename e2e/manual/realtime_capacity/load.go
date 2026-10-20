// Build from ../realtime_transport to reuse its pinned Pion dependencies.
package main

import (
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"sort"
	"sync"
	"time"

	"github.com/pion/turn/v5"
)

type endpoint struct {
	URL   string
	Token string
	Claim string
}

type stats struct {
	mu        sync.Mutex
	Latencies []float64
	Errors    map[string]int
	Count     int
	Gaps      int
	Sent      int
	Received  int
}

func (s *stats) error(key string) {
	s.mu.Lock()
	s.Errors[key]++
	s.mu.Unlock()
}

func percentile(values []float64, p float64) float64 {
	if len(values) == 0 {
		return 0
	}
	return values[int(float64(len(values)-1)*p)]
}

func main() {
	mode := flag.String("mode", "http", "http or turn")
	input := flag.String("input", "", "JSON endpoint file")
	address := flag.String("address", "", "TURN host:port")
	count := flag.Int("count", 1, "sessions")
	readers := flag.Int("readers", 2, "HTTP readers per session: 1 Runner or 2 both sides")
	duration := flag.Duration("duration", 20*time.Second, "measurement")
	warmup := flag.Duration("warmup", 5*time.Second, "warmup")
	flag.Parse()
	s := &stats{Errors: map[string]int{}}
	start := time.Now().Add(*warmup)
	end := start.Add(*duration)
	switch *mode {
	case "http":
		data, err := os.ReadFile(*input)
		must(err)
		var endpoints []endpoint
		must(json.Unmarshal(data, &endpoints))
		if (*readers != 1 && *readers != 2) || len(endpoints) != *count * *readers {
			panic("unexpected HTTP endpoint count")
		}
		httpLoad(endpoints, start, end, s)
	case "turn":
		turnLoad(*address, *count, *warmup, *duration, s)
	default:
		panic("unknown mode")
	}
	sort.Float64s(s.Latencies)
	report := map[string]any{
		"mode": *mode, "sessions": *count, "duration_seconds": duration.Seconds(),
		"http_readers_per_session": *readers,
		"requests": s.Count, "rps": float64(s.Count) / duration.Seconds(),
		"errors": s.Errors, "permission_gaps": s.Gaps,
		"p50_ms": percentile(s.Latencies, .50), "p95_ms": percentile(s.Latencies, .95),
		"p99_ms": percentile(s.Latencies, .99), "latency_samples": len(s.Latencies),
		"sent_packets": s.Sent, "received_packets": s.Received,
		"received_mbps": float64(s.Received*1200*8) / duration.Seconds() / 1e6,
	}
	must(json.NewEncoder(os.Stdout).Encode(report))
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}

func httpLoad(endpoints []endpoint, start, end time.Time, s *stats) {
	var wg sync.WaitGroup
	for i, ep := range endpoints {
		wg.Add(1)
		go func(i int, ep endpoint) {
			defer wg.Done()
			transport := &http.Transport{MaxIdleConnsPerHost: 1}
			defer transport.CloseIdleConnections()
			client := &http.Client{Transport: transport, Timeout: 5 * time.Second}
			time.Sleep(time.Duration(i) * 500 * time.Millisecond / time.Duration(len(endpoints)))
			var validUntil time.Time
			for time.Now().Before(end) {
				began := time.Now()
				req, err := http.NewRequest("GET", ep.URL, nil)
				must(err)
				req.Header.Set("Authorization", "Bearer "+ep.Token)
				if ep.Claim != "" {
					req.Header.Set("Claim-Token", ep.Claim)
				}
				response, err := client.Do(req)
				status := ""
				maxAge := 0
				if err != nil {
					status = "transport"
				} else {
					body, readErr := io.ReadAll(io.LimitReader(response.Body, 256*1024))
					response.Body.Close()
					var value struct {
						Realtime struct {
							Status string
							MaxAge int `json:"max_age_ms"`
						}
					}
					if response.StatusCode != 200 {
						status = fmt.Sprint(response.StatusCode)
					} else if readErr != nil || json.Unmarshal(body, &value) != nil {
						status = "body"
					} else if value.Realtime.Status != "active" {
						status = value.Realtime.Status
					} else {
						maxAge = value.Realtime.MaxAge
					}
				}
				finished := time.Now()
				if !began.Before(start) {
					s.mu.Lock()
					s.Count++
					s.Latencies = append(s.Latencies, finished.Sub(began).Seconds()*1000)
					if status != "" {
						s.Errors[status]++
					}
					if validUntil.IsZero() || finished.After(validUntil) {
						s.Gaps++
					}
					s.mu.Unlock()
				}
				// Current clients discount full request latency from max_age_ms.
				if status == "" {
					validUntil = began.Add(time.Duration(maxAge) * time.Millisecond)
				}
				time.Sleep(500 * time.Millisecond)
			}
		}(i, ep)
	}
	wg.Wait()
}

type relaySession struct {
	client *turn.Client
	socket net.PacketConn
	relay  net.PacketConn
	peer   net.PacketConn
}

func turnLoad(address string, count int, warmup, duration time.Duration, s *stats) {
	sessions := make([]relaySession, 0, count)
	defer func() {
		for _, v := range sessions {
			v.relay.Close()
			v.client.Close()
			v.socket.Close()
			v.peer.Close()
		}
	}()
	for range count {
		socket, err := net.ListenPacket("udp4", "127.0.0.1:0")
		must(err)
		client, err := turn.NewClient(&turn.ClientConfig{TURNServerAddr: address, STUNServerAddr: address,
			Conn: socket, Username: "fixture", Password: "isolated-fixture", Realm: "handler-fixture"})
		must(err)
		must(client.Listen())
		relay, err := client.Allocate()
		must(err)
		peer, err := net.ListenPacket("udp4", "127.0.0.1:0")
		must(err)
		sessions = append(sessions, relaySession{client, socket, relay, peer})
		// Establish permission and channel binding before measurement.
		_, err = relay.WriteTo([]byte("warmup"), peer.LocalAddr())
		must(err)
	}
	start := time.Now().Add(warmup)
	end := start.Add(duration)
	var wg sync.WaitGroup
	for i, v := range sessions {
		wg.Add(3)
		go func(v relaySession) {
			defer wg.Done()
			buf := make([]byte, 1600)
			v.peer.SetReadDeadline(end.Add(time.Second))
			for {
				n, from, err := v.peer.ReadFrom(buf)
				if err != nil {
					return
				}
				if n != 1200 {
					continue
				}
				measured := buf[0] == 1
				if measured {
					s.mu.Lock()
					s.Received++
					s.mu.Unlock()
				}
				if buf[1] == 1 {
					if _, err := v.peer.WriteTo(buf[:n], from); err != nil {
						s.error("echo_write")
					}
				}
			}
		}(v)
		go func(v relaySession) {
			defer wg.Done()
			buf := make([]byte, 1600)
			v.relay.SetReadDeadline(end.Add(time.Second))
			for {
				n, _, err := v.relay.ReadFrom(buf)
				if err != nil {
					return
				}
				if n == 1200 && buf[0] == 1 && buf[1] == 1 {
					latency := float64(time.Now().UnixNano()-int64(binary.BigEndian.Uint64(buf[8:16]))) / 1e6
					s.mu.Lock()
					s.Latencies = append(s.Latencies, latency)
					s.mu.Unlock()
				}
			}
		}(v)
		go func(i int, v relaySession) {
			defer wg.Done()
			interval := 9600 * time.Microsecond // 1200 bytes at 1 Mbit/s.
			next := time.Now().Add(time.Duration(i) * interval / time.Duration(count))
			packet := make([]byte, 1200)
			for seq := 0; next.Before(end); seq++ {
				time.Sleep(time.Until(next))
				now := time.Now()
				packet[0], packet[1] = 0, 0
				if !now.Before(start) && now.Before(end) {
					packet[0] = 1
				}
				if seq%10 == 0 {
					packet[1] = 1
				}
				binary.BigEndian.PutUint64(packet[8:16], uint64(now.UnixNano()))
				_, err := v.relay.WriteTo(packet, v.peer.LocalAddr())
				if packet[0] == 1 {
					s.mu.Lock()
					s.Sent++
					if err != nil {
						s.Errors["send"]++
					}
					s.mu.Unlock()
				}
				// Avoid catch-up bursts when the generator falls behind.
				next = next.Add(interval)
				if next.Before(now) {
					next = now.Add(interval)
				}
			}
		}(i, v)
	}
	wg.Wait()
}
