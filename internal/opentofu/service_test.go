package opentofu

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestReadEvidenceIsBoundedAndArtifactConfined(t *testing.T) {
	stack := t.TempDir()
	artifactDir := filepath.Join(stack, ".tofu-artifacts")
	if err := os.MkdirAll(artifactDir, 0o700); err != nil {
		t.Fatal(err)
	}
	evidence := filepath.Join(artifactDir, "run.jsonl")
	if err := os.WriteFile(evidence, []byte(strings.Repeat("x", 32)), 0o600); err != nil {
		t.Fatal(err)
	}
	service, err := NewService(t.TempDir(), []string{stack})
	if err != nil {
		t.Fatal(err)
	}
	out, err := service.ReadEvidence(context.Background(), EvidenceInput{StackPath: stack, EvidencePath: evidence, MaxBytes: 8})
	if err != nil {
		t.Fatal(err)
	}
	if out.Content != "xxxxxxxx" || !out.Truncated {
		t.Fatalf("ReadEvidence = %#v", out)
	}
	outside := filepath.Join(t.TempDir(), "secret")
	if err := os.WriteFile(outside, []byte("nope"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := service.ReadEvidence(context.Background(), EvidenceInput{StackPath: stack, EvidencePath: outside}); err == nil {
		t.Fatal("ReadEvidence accepted path outside artifact root")
	}
}

func TestProfileIsExplicit(t *testing.T) {
	stack := t.TempDir()
	service, err := NewService(t.TempDir(), []string{stack})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := service.stackAndProfile(stack, "production-ish"); err == nil {
		t.Fatal("stackAndProfile accepted unknown profile")
	}
}
