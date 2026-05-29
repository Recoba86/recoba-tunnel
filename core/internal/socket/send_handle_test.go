package socket

import (
	"errors"
	"testing"
	"time"

	"paqet/internal/conf"
)

func TestIsENOBUFS(t *testing.T) {
	tests := []struct {
		name string
		err  error
		want bool
	}{
		{name: "nil", err: nil, want: false},
		{name: "libpcap text", err: errors.New("send: No buffer space available"), want: true},
		{name: "errno token", err: errors.New("write failed: ENOBUFS"), want: true},
		{name: "other error", err: errors.New("send: network is unreachable"), want: false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := isENOBUFS(tt.err); got != tt.want {
				t.Fatalf("isENOBUFS() = %v, want %v", got, tt.want)
			}
		})
	}
}

type mockSocketHandle struct {
	writeDelay time.Duration
	err        error
}

func (m *mockSocketHandle) WritePacketData(data []byte) error {
	time.Sleep(m.writeDelay)
	return m.err
}

func (m *mockSocketHandle) Close() {}

func TestWritePacketData_ENOBUFSCap(t *testing.T) {
	mockErr := errors.New("enobufs") // isENOBUFS checks string content for "enobufs"
	mockHandle := &mockSocketHandle{err: mockErr}

	h := &SendHandle{
		handle: mockHandle,
		tx: conf.TX{
			RawPacketRetries: 100, // Very high
			RawPacketRetryUS: 50000, // Very high
		},
	}

	start := time.Now()
	_ = h.writePacketData([]byte("test packet"))
	duration := time.Since(start)

	// Since we capped retries to 2 and max delay to 1000us (1ms),
	// the total delay should be very small (e.g. < 50ms)
	// If the cap didn't work, it would sleep for hundreds of seconds.
	if duration > 50*time.Millisecond {
		t.Fatalf("writePacketData took too long (%v), ENOBUFS retry cap failed", duration)
	}
}
