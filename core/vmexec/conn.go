package vmexec

import (
	"encoding/json"
	"io"
	"net"
	"sync"
)

type FrameConn struct {
	conn net.Conn
	wmu  sync.Mutex
	rmu  sync.Mutex
	wbuf [HeaderSize]byte
	rbuf [HeaderSize]byte
}

func NewFrameConn(conn net.Conn) *FrameConn {
	return &FrameConn{conn: conn}
}

func (fc *FrameConn) Close() error {
	return fc.conn.Close()
}

func (fc *FrameConn) WriteFrame(ft FrameType, flags uint16, payload []byte) error {
	fc.wmu.Lock()
	defer fc.wmu.Unlock()

	header := FrameHeader{
		Version: ProtocolVersion,
		Type:    ft,
		Flags:   flags,
		Length:  uint32(len(payload)),
	}
	header.Encode(fc.wbuf[:])

	if _, err := fc.conn.Write(fc.wbuf[:]); err != nil {
		return err
	}
	if len(payload) > 0 {
		_, err := fc.conn.Write(payload)
		return err
	}
	return nil
}

func (fc *FrameConn) ReadFrame() (FrameHeader, []byte, error) {
	fc.rmu.Lock()
	defer fc.rmu.Unlock()

	if _, err := io.ReadFull(fc.conn, fc.rbuf[:]); err != nil {
		return FrameHeader{}, nil, err
	}
	header, err := DecodeHeader(fc.rbuf[:])
	if err != nil {
		return FrameHeader{}, nil, err
	}

	payload := make([]byte, header.Length)
	if header.Length > 0 {
		if _, err := io.ReadFull(fc.conn, payload); err != nil {
			return FrameHeader{}, nil, err
		}
	}
	return header, payload, nil
}

func (fc *FrameConn) SendExecInit(init ExecInit) error {
	data, err := json.Marshal(init)
	if err != nil {
		return err
	}
	var flags uint16
	if init.Rosetta {
		flags |= FlagRosetta
	}
	if init.Cgroup != nil {
		flags |= FlagCgroup
	}
	if init.ReadOnlyWorkspace {
		flags |= FlagReadOnly
	}
	if init.LoopbackOnlyNetwork {
		flags |= FlagLoopbackOnly
	}
	return fc.WriteFrame(FrameExecInit, flags, data)
}
