package main

import (
	"net"
	"sync/atomic"

	"github.com/pion/turn/v5"
)

type byteCounts struct{ rx, tx atomic.Uint64 }
type countedConn struct {
	net.PacketConn
	counts *byteCounts
}

func (c *countedConn) ReadFrom(b []byte) (int, net.Addr, error) {
	n, a, e := c.PacketConn.ReadFrom(b)
	c.counts.rx.Add(uint64(n))
	return n, a, e
}
func (c *countedConn) WriteTo(b []byte, a net.Addr) (int, error) {
	n, e := c.PacketConn.WriteTo(b, a)
	c.counts.tx.Add(uint64(n))
	return n, e
}

type countedGenerator struct {
	turn.RelayAddressGenerator
	counts *byteCounts
}

func (g *countedGenerator) AllocatePacketConn(config turn.AllocateListenerConfig) (net.PacketConn, net.Addr, error) {
	c, a, e := g.RelayAddressGenerator.AllocatePacketConn(config)
	if e != nil {
		return nil, nil, e
	}
	return &countedConn{c, g.counts}, a, nil
}
func startTURN(ip string) (*turn.Server, *byteCounts, error) {
	counts := &byteCounts{}
	relayIP := net.ParseIP(ip)
	if relayIP == nil {
		addresses, err := net.LookupIP(ip)
		if err != nil {
			return nil, nil, err
		}
		for _, address := range addresses {
			if address.To4() != nil {
				relayIP = address
				break
			}
		}
	}
	conn, err := net.ListenPacket("udp4", ":3478")
	if err != nil {
		return nil, nil, err
	}
	server, err := turn.NewServer(turn.ServerConfig{
		Realm: "transport-fixture",
		AuthHandler: func(ra *turn.RequestAttributes) (string, []byte, bool) {
			return ra.Username, turn.GenerateAuthKey("fixture", ra.Realm, "isolated-fixture"), ra.Username == "fixture"
		},
		PacketConnConfigs: []turn.PacketConnConfig{{
			PacketConn:            &countedConn{conn, counts},
			RelayAddressGenerator: &countedGenerator{&turn.RelayAddressGeneratorStatic{RelayAddress: relayIP, Address: "0.0.0.0"}, counts},
		}},
	})
	if err != nil {
		_ = conn.Close()
	}
	return server, counts, err
}
