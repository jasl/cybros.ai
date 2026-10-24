// A local-only transport experiment. Its HTTP commands are harness controls,
// not public Nexus APIs and never grant production execution authority.
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"
)

func main() {
	role := flag.String("role", "peer", "peer, turn, or fixture")
	listen := flag.String("listen", ":8080", "isolated harness HTTP address")
	runner := flag.Bool("runner", false, "own the real PTY")
	relayIP := flag.String("relay-ip", "", "TURN relay address")
	flag.Parse()
	if *role == "fixture" {
		scanner := bufio.NewScanner(os.Stdin)
		for scanner.Scan() {
			fmt.Printf("done:%s\n", scanner.Text())
		}
		return
	}
	mux := http.NewServeMux()
	if *role == "turn" {
		closer, counters, err := startTURN(*relayIP)
		if err != nil {
			log.Fatal(err)
		}
		defer closer.Close()
		mux.HandleFunc("GET /stats", func(w http.ResponseWriter, r *http.Request) {
			respond(w, map[string]any{"rx": counters.rx.Load(), "tx": counters.tx.Load(), "process": processStats()}, nil)
		})
	} else {
		p, err := newPeer(*runner)
		if err != nil {
			log.Fatal(err)
		}
		defer p.close()
		p.routes(mux)
	}
	server := &http.Server{Addr: *listen, Handler: mux, ReadHeaderTimeout: 2 * time.Second}
	log.Fatal(server.ListenAndServe())
}

func decode(r *http.Request, value any) error {
	return json.NewDecoder(http.MaxBytesReader(nil, r.Body, 128*1024)).Decode(value)
}
func respond(w http.ResponseWriter, value any, err error) {
	w.Header().Set("Content-Type", "application/json")
	if err != nil {
		w.WriteHeader(http.StatusConflict)
		value = map[string]string{"error": err.Error()}
	}
	_ = json.NewEncoder(w).Encode(value)
}
func processStats() map[string]any {
	var u syscall.Rusage
	_ = syscall.Getrusage(syscall.RUSAGE_SELF, &u)
	var m runtime.MemStats
	runtime.ReadMemStats(&m)
	rss := int64(0)
	if data, err := os.ReadFile("/proc/self/status"); err == nil {
		for _, line := range strings.Split(string(data), "\n") {
			if strings.HasPrefix(line, "VmRSS:") {
				fields := strings.Fields(line)
				rss, _ = strconv.ParseInt(fields[1], 10, 64)
				rss *= 1024
			}
		}
	}
	return map[string]any{"cpu_s": float64(u.Utime.Sec+u.Stime.Sec) + float64(u.Utime.Usec+u.Stime.Usec)/1e6, "rss_bytes": rss, "heap_bytes": m.HeapAlloc}
}
