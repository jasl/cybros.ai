// Test TURN server: ephemeral listener (loopback by default), stopped by stdin EOF.
package main

import (
	"crypto/tls"
	"flag"
	"fmt"
	"github.com/pion/turn/v5"
	"io"
	"net"
	"os"
)

func main() {
	address := flag.String("address", "127.0.0.1", "listener and relay address")
	transport := flag.String("transport", "udp", "client transport: udp, tcp or tls")
	certificate := flag.String("certificate", "", "TLS certificate PEM path")
	key := flag.String("key", "", "TLS private key PEM path")
	flag.Parse()
	config := turn.ServerConfig{
		Realm: "handler-fixture",
		AuthHandler: func(r *turn.RequestAttributes) (string, []byte, bool) {
			return r.Username, turn.GenerateAuthKey("fixture", r.Realm, "isolated-fixture"), r.Username == "fixture"
		},
	}
	relay := &turn.RelayAddressGeneratorStatic{RelayAddress: net.ParseIP(*address), Address: *address}
	var listenerAddress net.Addr
	scheme, protocol := "turn", *transport
	switch *transport {
	case "udp":
		conn, err := net.ListenPacket("udp4", net.JoinHostPort(*address, "0"))
		if err != nil {
			panic(err)
		}
		defer conn.Close()
		listenerAddress = conn.LocalAddr()
		config.PacketConnConfigs = []turn.PacketConnConfig{{PacketConn: conn, RelayAddressGenerator: relay}}
	case "tcp", "tls":
		listener, err := net.Listen("tcp4", net.JoinHostPort(*address, "0"))
		if err != nil {
			panic(err)
		}
		defer listener.Close()
		if *transport == "tls" {
			pair, err := tls.LoadX509KeyPair(*certificate, *key)
			if err != nil {
				panic(err)
			}
			listener = tls.NewListener(listener, &tls.Config{Certificates: []tls.Certificate{pair}, MinVersion: tls.VersionTLS12})
			scheme, protocol = "turns", "tcp"
		}
		listenerAddress = listener.Addr()
		config.ListenerConfigs = []turn.ListenerConfig{{Listener: listener, RelayAddressGenerator: relay}}
	default:
		panic("transport must be udp, tcp or tls")
	}
	server, err := turn.NewServer(config)
	if err != nil {
		panic(err)
	}
	defer server.Close()
	fmt.Printf("%s:%s?transport=%s\n", scheme, listenerAddress, protocol)
	_, _ = io.Copy(io.Discard, os.Stdin)
}
