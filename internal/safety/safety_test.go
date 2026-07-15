package safety

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestRedactRemovesCredentialsAndPrivateKeys(t *testing.T) {
	in := "Authorization: Bearer abc.def\npassword=hunter2\ntoken: ghp_1234567890abcdef\n-----BEGIN PRIVATE KEY-----\nraw\n-----END PRIVATE KEY-----"
	got := Redact(in)
	for _, secret := range []string{"abc.def", "hunter2", "ghp_1234567890abcdef", "raw"} {
		if strings.Contains(got, secret) {
			t.Fatalf("Redact retained %q in %q", secret, got)
		}
	}
}

func TestPathPolicyRejectsSymlinkEscape(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()
	link := filepath.Join(root, "escape")
	if err := os.Symlink(outside, link); err != nil {
		t.Fatal(err)
	}
	policy, err := NewPathPolicy([]string{root})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := policy.ResolveDir(link); err == nil {
		t.Fatal("ResolveDir accepted a symlink escape")
	}
}

func TestPlanIsExactConfirmedExpiringSingleUseAndDriftBound(t *testing.T) {
	stack := t.TempDir()
	if err := os.WriteFile(filepath.Join(stack, "main.tf"), []byte("terraform {}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	planPath := filepath.Join(stack, "plan.tfplan")
	if err := os.WriteFile(planPath, []byte("opaque plan"), 0o600); err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 7, 15, 1, 0, 0, 0, time.UTC)
	store, err := NewStore(stack, 15*time.Minute, func() time.Time { return now })
	if err != nil {
		t.Fatal(err)
	}
	plan, err := store.Create(Plan{StackPath: stack, Workspace: "dev", Profile: "dev", PlanPath: planPath})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.Consume(plan.ID, "CONFIRM apply dev wrong"); !errors.Is(err, ErrConfirmation) {
		t.Fatalf("Consume wrong confirmation = %v", err)
	}
	if _, err := store.Consume(plan.ID, plan.ConfirmationToken()); err != nil {
		t.Fatalf("Consume after corrected confirmation = %v", err)
	}
	if _, err := store.Consume(plan.ID, plan.ConfirmationToken()); !errors.Is(err, ErrConsumed) {
		t.Fatalf("Consume second use = %v", err)
	}

	plan2, err := store.Create(Plan{StackPath: stack, Workspace: "dev", Profile: "dev", PlanPath: planPath, RunID: "second"})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stack, "main.tf"), []byte("terraform { required_version = \">= 1.9\" }\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Consume(plan2.ID, plan2.ConfirmationToken()); !errors.Is(err, ErrDrift) {
		t.Fatalf("Consume after config drift = %v", err)
	}

	if err := os.WriteFile(filepath.Join(stack, "main.tf"), []byte("terraform {}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	plan3, err := store.Create(Plan{StackPath: stack, Workspace: "dev", Profile: "dev", PlanPath: planPath, RunID: "third"})
	if err != nil {
		t.Fatal(err)
	}
	now = now.Add(16 * time.Minute)
	if _, err := store.Consume(plan3.ID, plan3.ConfirmationToken()); !errors.Is(err, ErrExpired) {
		t.Fatalf("Consume expired = %v", err)
	}
}
