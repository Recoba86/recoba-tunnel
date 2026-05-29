package client

import (
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"paqet/internal/conf"
	"paqet/internal/tnet"
)

type mockStrm struct {
	tnet.Strm
	id int
}

func (m *mockStrm) SID() int { return m.id }
func (m *mockStrm) Close() error { return nil }
func (m *mockStrm) Write(b []byte) (int, error) { return len(b), nil }

func TestUDPConcurrencyRace(t *testing.T) {
	c, _ := New(&conf.Conf{})
	var streamCounter int32 = 0
	
	// Mock newStrm
	c.newStrmOverride = func() (tnet.Strm, error) {
		time.Sleep(10 * time.Millisecond) // Simulate RTT
		newID := atomic.AddInt32(&streamCounter, 1)
		return &mockStrm{id: int(newID)}, nil
	}

	var wg sync.WaitGroup
	numRequests := 50
	
	for i := 0; i < numRequests; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, _, _, _ = c.UDP("127.0.0.1:1000", "127.0.0.1:2000")
		}()
	}
	wg.Wait()

	if streamCounter > 1 {
		t.Fatalf("Expected only 1 stream to be created for the same key, got %d", streamCounter)
	}

	c.udpPool.mu.Lock()
	mapLen := len(c.udpPool.strms)
	c.udpPool.mu.Unlock()

	if mapLen != 1 {
		t.Fatalf("Expected exactly 1 stream in map, got %d", mapLen)
	}
}
