package kerneltelemetry

import (
	"bytes"
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"testing"
	"time"
)

var updateFixture = flag.Bool("update", false, "rewrite the app contract fixture")

func contractSample() Report {
	targets := []string{"/srv/app/data.db", "socket:[41001]", "pipe:[41002]", "/dev/null", "anon_inode:[eventpoll]", "memfd:cache (deleted)"}
	entries := make([]FDEntry, 0, len(targets))
	for i, target := range targets {
		entries = append(entries, FDEntry{FD: i, Target: target, Kind: ClassifyFDKind(target)})
	}
	codes := []string{"01", "02", "03", "04", "05", "06", "07", "08", "09", "0A", "0B", "FF"}
	sockets := make([]TCPSocket, 0, len(codes))
	for i, code := range codes {
		sockets = append(sockets, TCPSocket{
			LocalAddress:  "127.0.0.1",
			LocalPort:     8080,
			RemoteAddress: "10.0.2.2",
			RemotePort:    50000 + i,
			State:         MapTCPState(code),
			Inode:         41001 + uint64(i),
			RxQueue:       uint64(i),
			TxQueue:       uint64(2 * i),
		})
	}
	full := PSIValues{Avg10: 0.25, Avg60: 0.1, Avg300: 0.05, TotalMicros: 9876}
	return Report{
		PID:        4242,
		TargetName: "server",
		OpenFDs:    OpenFDs{Count: len(entries), Limit: 1048576, Entries: entries},
		TCPSockets: sockets,
		PSI: &PSI{
			Memory: PSIResource{SomePressure: PSIValues{Avg10: 1.5, Avg60: 0.75, Avg300: 0.2, TotalMicros: 123456}, FullPressure: &full},
			CPU:    PSIResource{SomePressure: PSIValues{Avg10: 12.5, Avg60: 6, Avg300: 2, TotalMicros: 654321}},
			IO:     PSIResource{SomePressure: PSIValues{}, FullPressure: &PSIValues{}},
		},
		Timestamp: FormatTimestamp(time.Date(2026, 11, 17, 22, 30, 45, 123456789, time.FixedZone("ICT", 7*3600))),
	}
}

func contractSampleWithoutPressure() Report {
	return Report{
		PID:        7,
		TargetName: "idle",
		OpenFDs:    OpenFDs{Count: 0, Limit: 1024, Entries: []FDEntry{}},
		TCPSockets: []TCPSocket{},
		Timestamp:  FormatTimestamp(time.Date(2026, 11, 17, 8, 0, 0, 0, time.UTC)),
	}
}

func TestReportMatchesAppContractFixtures(t *testing.T) {
	fixtures := map[string]Report{
		"testdata/kernel-telemetry-contract.json":             contractSample(),
		"testdata/kernel-telemetry-contract-no-pressure.json": contractSampleWithoutPressure(),
	}
	for fixture, sample := range fixtures {
		got, err := json.MarshalIndent(sample, "", "  ")
		if err != nil {
			t.Fatal(err)
		}
		got = append(got, '\n')
		if *updateFixture {
			if err := os.WriteFile(fixture, got, 0o644); err != nil {
				t.Fatal(err)
			}
		}
		want, err := os.ReadFile(fixture)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(got, want) {
			t.Errorf("kernel telemetry JSON no longer matches %s, which the app's KernelTelemetry decoder test reads.\ngot:\n%s", filepath.ToSlash(fixture), got)
		}
	}
}

func TestCollectedReportNeverEncodesNullLists(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "7", "fd"), 0o755); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(root, "7", "stat"), "7 (idle) S 1 7 7 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 100 0 0")
	data, err := CollectJSON(root, 7, time.Unix(0, 0))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(data, []byte("null")) {
		t.Fatalf("report encodes null where the app expects a list: %s", data)
	}
}
