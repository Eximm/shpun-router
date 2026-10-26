package dokodemo

import (
	stderrors "errors"
	"github.com/xtls/xray-core/common/buf"
	"github.com/xtls/xray-core/common/net"
	"sync"
	"testing"
	"time"
)

type retentionMockSocket struct {
	closed   int
	writes   int
	writeErr error
}

func (s *retentionMockSocket) ReadFrom([]byte) (int, net.Addr, error) {
	panic("test must not read network")
}
func (s *retentionMockSocket) WriteTo(b []byte, _ net.Addr) (int, error) {
	s.writes++
	return len(b), s.writeErr
}

func TestReplySocketErrorAndClosedWriter(t *testing.T) {
	original := packetWriterSocketFactory
	defer func() { packetWriterSocketFactory = original }()
	initial := &retentionMockSocket{}
	dest := net.UDPDestination(net.ParseAddress("192.0.2.1"), 53)
	w := NewPacketWriter(initial, &dest, 0, &net.UDPAddr{}).(*PacketWriter)
	target := net.UDPDestination(net.ParseAddress("198.51.100.1"), 19302)
	send := func() error {
		b := buf.New()
		b.Write([]byte{1})
		b.UDP = &target
		return w.WriteMultiBuffer(buf.MultiBuffer{b})
	}
	failed := &retentionMockSocket{writeErr: stderrors.New("synthetic write failure")}
	packetWriterSocketFactory = func(*net.UDPAddr, int) (net.PacketConn, error) { return failed, nil }
	if err := send(); err != nil {
		t.Fatal(err)
	}
	if failed.closed != 1 {
		t.Fatal("write failure leaked socket")
	}
	packetWriterSocketFactory = func(*net.UDPAddr, int) (net.PacketConn, error) {
		return nil, stderrors.New("synthetic factory failure")
	}
	if err := send(); err != nil {
		t.Fatal(err)
	}
	if len(w.conns) != 1 {
		t.Fatal("factory failure retained a destination")
	}
	w.Close()
	w.Close()
	if initial.closed != 1 {
		t.Fatal("initial socket double close")
	}
	if send() == nil {
		t.Fatal("write after close accepted")
	}
}

func TestConcurrentReplyAndClose(t *testing.T) {
	original := packetWriterSocketFactory
	defer func() { packetWriterSocketFactory = original }()
	sockets := []*retentionMockSocket{}
	packetWriterSocketFactory = func(*net.UDPAddr, int) (net.PacketConn, error) {
		s := &retentionMockSocket{}
		sockets = append(sockets, s)
		return s, nil
	}
	initial := &retentionMockSocket{}
	dest := net.UDPDestination(net.ParseAddress("192.0.2.1"), 53)
	w := NewPacketWriter(initial, &dest, 0, &net.UDPAddr{}).(*PacketWriter)
	var group sync.WaitGroup
	for n := 0; n < 8; n++ {
		group.Add(1)
		go func() {
			defer group.Done()
			for i := 0; i < 100; i++ {
				target := net.UDPDestination(net.ParseAddress("198.51.100.1"), 19302)
				b := buf.New()
				b.Write([]byte{1})
				b.UDP = &target
				w.WriteMultiBuffer(buf.MultiBuffer{b})
			}
		}()
	}
	group.Add(1)
	go func() { defer group.Done(); w.Close() }()
	group.Wait()
	w.Close()
	if initial.closed != 1 {
		t.Fatal("initial close count")
	}
	for _, s := range sockets {
		if s.closed != 1 {
			t.Fatal("temporary close count")
		}
	}
}
func (s *retentionMockSocket) Close() error                     { s.closed++; return nil }
func (s *retentionMockSocket) LocalAddr() net.Addr              { return &net.UDPAddr{} }
func (s *retentionMockSocket) SetDeadline(time.Time) error      { return nil }
func (s *retentionMockSocket) SetReadDeadline(time.Time) error  { return nil }
func (s *retentionMockSocket) SetWriteDeadline(time.Time) error { return nil }

// Characterizes the exact-source cache behavior. No network traffic or FD opens.
func TestReplySocketsReleasedBeforeFlowClose(t *testing.T) {
	original := packetWriterSocketFactory
	defer func() { packetWriterSocketFactory = original }()
	initial := &retentionMockSocket{}
	sockets := []*retentionMockSocket{initial}
	packetWriterSocketFactory = func(*net.UDPAddr, int) (net.PacketConn, error) {
		s := &retentionMockSocket{}
		sockets = append(sockets, s)
		return s, nil
	}
	dest := net.UDPDestination(net.ParseAddress("192.0.2.1"), 53)
	writer := NewPacketWriter(initial, &dest, 0, &net.UDPAddr{}).(*PacketWriter)
	const count = 4096
	for i := 0; i < count; i++ {
		target := net.UDPDestination(net.ParseAddress("192.0.2.1"), net.Port(10000+i))
		b := buf.New()
		b.Write([]byte{1})
		b.UDP = &target
		if err := writer.WriteMultiBuffer(buf.MultiBuffer{b}); err != nil {
			t.Fatal(err)
		}
	}
	if len(writer.conns) != 1 {
		t.Fatalf("retained=%d, expected only initial socket", len(writer.conns))
	}
	if initial.closed != 0 {
		t.Fatal("initial socket closed before flow teardown")
	}
	for _, s := range sockets[1:] {
		if s.closed != 1 {
			t.Fatal("temporary reply socket not closed immediately")
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	for _, s := range sockets {
		if s.closed != 1 {
			t.Fatalf("teardown close count=%d", s.closed)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	for _, s := range sockets {
		if s.closed != 1 {
			t.Fatal("double close")
		}
	}
	t.Logf("%d different reply destinations: only initial socket retained; temporary sockets closed immediately", count)
}

// Separately parsed equal addresses must not create one socket per packet.
func TestRepeatedDestinationReopensReplySocket(t *testing.T) {
	original := packetWriterSocketFactory
	defer func() { packetWriterSocketFactory = original }()
	created := 0
	second := &retentionMockSocket{}
	packetWriterSocketFactory = func(*net.UDPAddr, int) (net.PacketConn, error) { created++; return second, nil }
	initial := &retentionMockSocket{}
	initialTarget := net.UDPDestination(net.ParseAddress("192.0.2.1"), 53)
	writer := NewPacketWriter(initial, &initialTarget, 0, &net.UDPAddr{}).(*PacketWriter)
	for i := 0; i < 4096; i++ {
		target := net.UDPDestination(net.ParseAddress("198.51.100.1"), 19302)
		b := buf.New()
		b.Write([]byte{1})
		b.UDP = &target
		if err := writer.WriteMultiBuffer(buf.MultiBuffer{b}); err != nil {
			t.Fatal(err)
		}
	}
	if created != 4096 || len(writer.conns) != 1 || second.writes != 4096 || second.closed != 4096 {
		t.Fatalf("created=%d retained=%d writes=%d closed=%d", created, len(writer.conns), second.writes, second.closed)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if initial.closed != 1 || second.closed != 4096 {
		t.Fatal("close mismatch")
	}
	t.Log("4096 repeated responses release every temporary socket; initial retained until teardown")
}
