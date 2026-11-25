package vmexec

import (
	"encoding/binary"
	"fmt"
	"io"
)

const (
	ProtocolVersion    uint8  = 0x01
	DefaultPort        uint32 = 2002
	MaxPayloadSize     uint32 = 4 * 1024 * 1024
	MaxSignPayloadSize int    = 1 << 20
	HeaderSize         int    = 8
)

type FrameType uint8

const (
	FrameExecInit        FrameType = 0x01
	FrameStdin           FrameType = 0x02
	FrameStdinClose      FrameType = 0x03
	FrameStdout          FrameType = 0x04
	FrameStderr          FrameType = 0x05
	FrameExit            FrameType = 0x06
	FrameSignal          FrameType = 0x07
	FrameResize          FrameType = 0x08
	FrameError           FrameType = 0x09
	FramePing            FrameType = 0x0A
	FramePong            FrameType = 0x0B
	FrameKernelTelemetry FrameType = 0x0C
	FrameSignRequest     FrameType = 0x0D
	FrameSignResponse    FrameType = 0x0E
)

const (
	FlagEOF              uint16 = 0x0001
	FlagRosetta          uint16 = 0x0002
	FlagCgroup           uint16 = 0x0004
	FlagOOMKilled        uint16 = 0x0008
	FlagReadOnly         uint16 = 0x0010
	FlagLoopbackOnly     uint16 = 0x0020
	FlagSignRelayCapable uint16 = 0x0040
	FlagSignError        uint16 = 0x0080
)

type FrameHeader struct {
	Version uint8
	Type    FrameType
	Flags   uint16
	Length  uint32
}

func (h FrameHeader) Encode(buf []byte) {
	_ = buf[7]
	buf[0] = h.Version
	buf[1] = byte(h.Type)
	binary.BigEndian.PutUint16(buf[2:4], h.Flags)
	binary.BigEndian.PutUint32(buf[4:8], h.Length)
}

func DecodeHeader(buf []byte) (FrameHeader, error) {
	if len(buf) < HeaderSize {
		return FrameHeader{}, io.ErrUnexpectedEOF
	}
	h := FrameHeader{
		Version: buf[0],
		Type:    FrameType(buf[1]),
		Flags:   binary.BigEndian.Uint16(buf[2:4]),
		Length:  binary.BigEndian.Uint32(buf[4:8]),
	}
	if h.Version != ProtocolVersion {
		return FrameHeader{}, fmt.Errorf("unsupported protocol version: 0x%02x", h.Version)
	}
	if h.Length > MaxPayloadSize {
		return FrameHeader{}, fmt.Errorf("payload size %d exceeds limit %d", h.Length, MaxPayloadSize)
	}
	return h, nil
}

type ExecInit struct {
	Argv                []string      `json:"argv"`
	Env                 []string      `json:"env"`
	Cwd                 string        `json:"cwd"`
	TTY                 bool          `json:"tty,omitempty"`
	Rosetta             bool          `json:"rosetta,omitempty"`
	Cgroup              *CgroupLimits `json:"cgroup,omitempty"`
	EnableTelemetry     bool          `json:"enable_telemetry,omitempty"`
	TelemetryIntervalMs uint32        `json:"telemetry_interval_ms,omitempty"`
	ReadOnlyWorkspace   bool          `json:"read_only_workspace,omitempty"`
	LoopbackOnlyNetwork bool          `json:"loopback_only_network,omitempty"`
	EnableCommitSigning bool          `json:"enable_commit_signing,omitempty"`
}

type CgroupLimits struct {
	MemoryMax   uint64 `json:"memory_max,omitempty"`
	CPUQuotaUS  uint32 `json:"cpu_quota_us,omitempty"`
	CPUPeriodUS uint32 `json:"cpu_period_us,omitempty"`
}
