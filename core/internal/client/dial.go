package client

import (
	"fmt"
	"paqet/internal/flog"
	"paqet/internal/tnet"
	"time"
)

func (c *Client) newConn() (tnet.Conn, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	autoExpire := 300
	tc := c.iter.Next()
	err := tc.conn.Ping(false)
	if err != nil {
		flog.Infof("connection lost, retrying....")
		if tc.conn != nil {
			tc.conn.Close()
		}
		if newC, err := tc.createConn(); err == nil {
			tc.conn = newC
		} else {
			return nil, fmt.Errorf("failed to recreate connection: %v", err)
		}
		tc.expire = time.Now().Add(time.Duration(autoExpire) * time.Second)
	}
	return tc.conn, nil
}

func (c *Client) newStrm() (tnet.Strm, error) {
	if c.newStrmOverride != nil {
		return c.newStrmOverride()
	}

	var conn tnet.Conn
	var strm tnet.Strm
	var err error

	for attempt := 0; attempt < 3; attempt++ {
		if attempt > 0 {
			delay := time.Duration(100<<uint(attempt-1)) * time.Millisecond
			time.Sleep(delay)
		}

		conn, err = c.newConn()
		if err != nil {
			flog.Debugf("session creation failed on attempt %d: %v", attempt+1, err)
			continue
		}

		strm, err = conn.OpenStrm()
		if err != nil {
			flog.Debugf("failed to open stream on attempt %d: %v", attempt+1, err)
			continue
		}

		return strm, nil
	}

	return nil, fmt.Errorf("failed to open stream after 3 attempts: %w", err)
}
