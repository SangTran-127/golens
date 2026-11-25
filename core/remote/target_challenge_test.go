package remote_test

import (
	"testing"

	"golens/core/remote"
)

func TestAdversarialRosettaTargetPermutations(t *testing.T) {
	cases := []struct {
		name          string
		target        remote.Target
		wantRosetta   bool
		wantResolved  string
		wantLabel     string
	}{
		{
			name:         "DefaultEmptyTarget",
			target:       remote.Target{},
			wantRosetta:  false,
			wantResolved: remote.KindVMArm64,
			wantLabel:    "My Mac",
		},
		{
			name:         "ExplicitKindLocal",
			target:       remote.Target{Kind: remote.KindLocal},
			wantRosetta:  false,
			wantResolved: remote.KindVMArm64,
			wantLabel:    "My Mac",
		},
		{
			name:         "KindVMArm64",
			target:       remote.Target{Kind: remote.KindVMArm64},
			wantRosetta:  false,
			wantResolved: remote.KindVMArm64,
			wantLabel:    "Linux ARM64 (Native)",
		},
		{
			name:         "KindVMAmd64_Rosetta",
			target:       remote.Target{Kind: remote.KindVMAmd64},
			wantRosetta:  true,
			wantResolved: remote.KindVMAmd64,
			wantLabel:    "Linux AMD64 (Rosetta 2)",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.target.IsRosetta(); got != tc.wantRosetta {
				t.Errorf("IsRosetta() = %v, want %v", got, tc.wantRosetta)
			}
			resolved, issue := tc.target.Resolve(t.TempDir())
			if issue != nil {
				t.Fatalf("unexpected issue on Resolve: %v", issue.Message)
			}
			if resolved.Kind != tc.wantResolved {
				t.Errorf("Resolve() kind = %q, want %q", resolved.Kind, tc.wantResolved)
			}
			if got := tc.target.Label(); got != tc.wantLabel {
				t.Errorf("Label() = %q, want %q", got, tc.wantLabel)
			}
		})
	}
}
