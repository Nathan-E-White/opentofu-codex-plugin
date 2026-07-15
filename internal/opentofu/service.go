package opentofu

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/Nathan-E-White/opentofu-codex-plugin/internal/safety"
)

const outputLimit = 96 * 1024

type Service struct {
	pluginRoot string
	paths      *safety.PathPolicy
	now        func() time.Time
}

func NewService(pluginRoot string, roots []string) (*Service, error) {
	root, err := filepath.Abs(pluginRoot)
	if err != nil {
		return nil, err
	}
	paths, err := safety.NewPathPolicy(roots)
	if err != nil {
		return nil, err
	}
	return &Service{pluginRoot: root, paths: paths, now: time.Now}, nil
}

type PreflightInput struct {
	StackPath   string `json:"stack_path" jsonschema:"absolute path to the OpenTofu stack"`
	Profile     string `json:"profile" jsonschema:"environment profile: dev, stg, or prod"`
	Workspace   string `json:"workspace,omitempty" jsonschema:"expected workspace when known"`
	BackendHint string `json:"backend_hint,omitempty" jsonschema:"backend configuration hint used for context checking"`
}

type CommandOutput struct {
	Status      string `json:"status"`
	RunID       string `json:"run_id"`
	StackPath   string `json:"stack_path"`
	Profile     string `json:"profile"`
	Workspace   string `json:"workspace,omitempty"`
	ArtifactDir string `json:"artifact_dir"`
	ExitCode    int    `json:"exit_code"`
	Output      string `json:"output"`
	RootPolicy  string `json:"root_policy"`
}

func (s *Service) Preflight(ctx context.Context, in PreflightInput) (CommandOutput, error) {
	stack, err := s.stackAndProfile(in.StackPath, in.Profile)
	if err != nil {
		return CommandOutput{}, err
	}
	runID := newRunID("preflight")
	artifactDir := filepath.Join(stack, ".tofu-artifacts", "mcp", "runs", runID)
	args := []string{"--path", stack, "--profile", in.Profile, "--check-only", "--run-id", runID, "--artifact-dir", artifactDir}
	if in.Workspace != "" {
		args = append(args, "--workspace", in.Workspace, "--expected-workspace", in.Workspace)
	}
	if in.BackendHint != "" {
		args = append(args, "--backend-config", in.BackendHint, "--expected-backend", in.BackendHint)
	}
	code, output, runErr := s.run(ctx, 2*time.Minute, filepath.Join(s.pluginRoot, "scripts", "preflight.sh"), args, nil)
	result := s.commandOutput(code, output, runID, stack, in.Profile, in.Workspace, artifactDir)
	if runErr != nil {
		return result, fmt.Errorf("preflight failed: %w", runErr)
	}
	return result, nil
}

type PolicyInput struct {
	StackPath       string `json:"stack_path" jsonschema:"absolute path to the OpenTofu stack"`
	Profile         string `json:"profile" jsonschema:"environment profile: dev, stg, or prod"`
	Workspace       string `json:"workspace,omitempty" jsonschema:"workspace to select for policy checks"`
	RequireExternal bool   `json:"require_external,omitempty" jsonschema:"require tflint and tfsec"`
	SkipTFLint      bool   `json:"skip_tflint,omitempty" jsonschema:"skip tflint in dev only"`
	SkipTFSec       bool   `json:"skip_tfsec,omitempty" jsonschema:"skip tfsec in dev only"`
}

func (s *Service) PolicyCheck(ctx context.Context, in PolicyInput) (CommandOutput, error) {
	stack, err := s.stackAndProfile(in.StackPath, in.Profile)
	if err != nil {
		return CommandOutput{}, err
	}
	if in.Profile != "dev" && (in.SkipTFLint || in.SkipTFSec) {
		return CommandOutput{}, errors.New("external checks may only be skipped in dev")
	}
	runID := newRunID("policy")
	artifactDir := filepath.Join(stack, ".tofu-artifacts", "mcp", "runs", runID, "policy")
	args := []string{"--path", stack, "--profile", in.Profile, "--run-id", runID, "--artifact-dir", artifactDir}
	if in.Workspace != "" {
		args = append(args, "--workspace", in.Workspace)
	}
	if in.RequireExternal {
		args = append(args, "--require-external")
	}
	if in.SkipTFLint {
		args = append(args, "--skip-tflint")
	}
	if in.SkipTFSec {
		args = append(args, "--skip-tfsec")
	}
	code, output, runErr := s.run(ctx, 10*time.Minute, filepath.Join(s.pluginRoot, "scripts", "policy-gates.sh"), args, nil)
	result := s.commandOutput(code, output, runID, stack, in.Profile, in.Workspace, artifactDir)
	if runErr != nil {
		return result, fmt.Errorf("policy check failed: %w", runErr)
	}
	return result, nil
}

type PlanInput struct {
	StackPath   string `json:"stack_path" jsonschema:"absolute path to the OpenTofu stack"`
	Profile     string `json:"profile" jsonschema:"environment profile: dev, stg, or prod"`
	Workspace   string `json:"workspace" jsonschema:"explicit workspace to plan"`
	BackendHint string `json:"backend_hint,omitempty" jsonschema:"backend configuration hint bound into plan evidence"`
}

type PlanOutput struct {
	Status            string    `json:"status"`
	PlanID            string    `json:"plan_id"`
	RunID             string    `json:"run_id"`
	StackPath         string    `json:"stack_path"`
	Workspace         string    `json:"workspace"`
	Profile           string    `json:"profile"`
	PlanPath          string    `json:"plan_path"`
	PlanJSONPath      string    `json:"plan_json_path"`
	SummaryPath       string    `json:"summary_path"`
	EvidenceDir       string    `json:"evidence_dir"`
	ExpiresAt         time.Time `json:"expires_at"`
	ConfirmationToken string    `json:"confirmation_token"`
	ExitCode          int       `json:"exit_code"`
	Output            string    `json:"output"`
}

func (s *Service) Plan(ctx context.Context, in PlanInput) (PlanOutput, error) {
	stack, err := s.stackAndProfile(in.StackPath, in.Profile)
	if err != nil {
		return PlanOutput{}, err
	}
	if strings.TrimSpace(in.Workspace) == "" {
		return PlanOutput{}, errors.New("workspace is required")
	}
	runID := newRunID("plan")
	artifactDir := filepath.Join(stack, ".tofu-artifacts", "mcp", "runs", runID)
	args := []string{"--path", stack, "--workspace", in.Workspace, "--run-id", runID, "--artifact-dir", artifactDir}
	if in.BackendHint != "" {
		args = append(args, "--backend-config", in.BackendHint)
	}
	args = append(args, "plan")
	code, output, runErr := s.run(ctx, 15*time.Minute, filepath.Join(s.pluginRoot, "scripts", "run-plan.sh"), args, nil)
	planPath := filepath.Join(artifactDir, "open-tofu-"+runID+".tfplan")
	planJSON := filepath.Join(artifactDir, "plan-"+runID+".json")
	summary := filepath.Join(artifactDir, "plan-"+runID+".summary.txt")
	if _, err := os.Stat(planPath); err != nil {
		if runErr == nil {
			runErr = err
		}
		return PlanOutput{Status: "failed", RunID: runID, ExitCode: code, Output: output}, fmt.Errorf("plan artifact missing: %w", runErr)
	}
	store, err := safety.NewStore(stack, 15*time.Minute, s.now)
	if err != nil {
		return PlanOutput{}, err
	}
	record, err := store.Create(safety.Plan{
		StackPath: stack, Workspace: in.Workspace, Profile: in.Profile, BackendHint: in.BackendHint,
		RunID: runID, PlanPath: planPath, EvidenceDir: artifactDir, SummaryPath: summary, PlanJSONPath: planJSON,
	})
	if err != nil {
		return PlanOutput{}, err
	}
	status := "planned"
	if code == 2 {
		status = "changes_detected"
	} else if runErr != nil {
		status = "failed"
	}
	result := PlanOutput{
		Status: status, PlanID: record.ID, RunID: runID, StackPath: stack, Workspace: in.Workspace,
		Profile: in.Profile, PlanPath: planPath, PlanJSONPath: planJSON, SummaryPath: summary,
		EvidenceDir: artifactDir, ExpiresAt: record.ExpiresAt, ConfirmationToken: record.ConfirmationToken(),
		ExitCode: code, Output: output,
	}
	if runErr != nil && code != 2 {
		return result, fmt.Errorf("plan failed: %w", runErr)
	}
	return result, nil
}

type ExecuteInput struct {
	StackPath    string `json:"stack_path" jsonschema:"same absolute stack path used to create the plan"`
	PlanID       string `json:"plan_id" jsonschema:"fresh immutable plan identifier returned by opentofu_plan"`
	Confirmation string `json:"confirmation" jsonschema:"exact confirmation token returned by opentofu_plan"`
}

type ExecuteOutput struct {
	Status      string `json:"status"`
	PlanID      string `json:"plan_id"`
	RunID       string `json:"run_id"`
	StackPath   string `json:"stack_path"`
	Workspace   string `json:"workspace"`
	Profile     string `json:"profile"`
	EvidenceDir string `json:"evidence_dir"`
	ExitCode    int    `json:"exit_code"`
	Output      string `json:"output"`
}

func (s *Service) ExecutePlan(ctx context.Context, in ExecuteInput) (ExecuteOutput, error) {
	stack, err := s.paths.ResolveDir(in.StackPath)
	if err != nil {
		return ExecuteOutput{}, err
	}
	store, err := safety.NewStore(stack, 15*time.Minute, s.now)
	if err != nil {
		return ExecuteOutput{}, err
	}
	record, err := store.Consume(in.PlanID, in.Confirmation)
	if err != nil {
		return ExecuteOutput{}, err
	}
	if record.StackPath != stack {
		return ExecuteOutput{}, errors.New("plan stack_path does not match request")
	}
	args := []string{"--path", stack, "--workspace", record.Workspace, "--run-id", record.RunID, "--artifact-dir", record.EvidenceDir, "--approval-token", in.Confirmation}
	if record.BackendHint != "" {
		args = append(args, "--backend-config", record.BackendHint)
	}
	args = append(args, "apply", record.PlanPath)
	env := []string{"OPENTOFU_MODE=enterprise", "OPENTOFU_PROFILE=" + record.Profile, "OPENTOFU_RUN_ID=" + record.RunID}
	code, output, runErr := s.run(ctx, 30*time.Minute, filepath.Join(s.pluginRoot, "scripts", "run-plan.sh"), args, env)
	result := ExecuteOutput{Status: "applied", PlanID: record.ID, RunID: record.RunID, StackPath: stack, Workspace: record.Workspace, Profile: record.Profile, EvidenceDir: record.EvidenceDir, ExitCode: code, Output: output}
	if runErr != nil {
		result.Status = "failed"
		return result, fmt.Errorf("apply failed; plan remains consumed: %w", runErr)
	}
	return result, nil
}

type EvidenceInput struct {
	StackPath    string `json:"stack_path" jsonschema:"absolute path to the OpenTofu stack"`
	EvidencePath string `json:"evidence_path" jsonschema:"absolute evidence file path beneath the stack .tofu-artifacts directory"`
	MaxBytes     int    `json:"max_bytes,omitempty" jsonschema:"maximum bytes to return, capped at 262144"`
}

type EvidenceOutput struct {
	Path      string `json:"path"`
	BytesRead int    `json:"bytes_read"`
	Truncated bool   `json:"truncated"`
	Content   string `json:"content"`
}

func (s *Service) ReadEvidence(_ context.Context, in EvidenceInput) (EvidenceOutput, error) {
	stack, err := s.paths.ResolveDir(in.StackPath)
	if err != nil {
		return EvidenceOutput{}, err
	}
	if !filepath.IsAbs(in.EvidencePath) {
		return EvidenceOutput{}, errors.New("evidence_path must be absolute")
	}
	path, err := filepath.EvalSymlinks(in.EvidencePath)
	if err != nil {
		return EvidenceOutput{}, err
	}
	artifactRoot := filepath.Join(stack, ".tofu-artifacts")
	rel, err := filepath.Rel(artifactRoot, path)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return EvidenceOutput{}, errors.New("evidence_path is outside the stack .tofu-artifacts directory")
	}
	max := in.MaxBytes
	if max <= 0 || max > 256*1024 {
		max = 256 * 1024
	}
	f, err := os.Open(path)
	if err != nil {
		return EvidenceOutput{}, err
	}
	defer f.Close()
	b := make([]byte, max+1)
	n, readErr := f.Read(b)
	if readErr != nil && !errors.Is(readErr, io.EOF) {
		return EvidenceOutput{}, readErr
	}
	truncated := n > max
	if truncated {
		n = max
	}
	return EvidenceOutput{Path: path, BytesRead: n, Truncated: truncated, Content: string(b[:n])}, nil
}

func (s *Service) stackAndProfile(path, profile string) (string, error) {
	if profile != "dev" && profile != "stg" && profile != "prod" {
		return "", errors.New("profile must be dev, stg, or prod")
	}
	return s.paths.ResolveDir(path)
}

func (s *Service) commandOutput(code int, output, runID, stack, profile, workspace, artifactDir string) CommandOutput {
	status := "success"
	if code != 0 {
		status = "failed"
	}
	policy := "explicit-path"
	if s.paths.Restricted() {
		policy = "OPENTOFU_MCP_ROOTS"
	}
	return CommandOutput{Status: status, RunID: runID, StackPath: stack, Profile: profile, Workspace: workspace, ArtifactDir: artifactDir, ExitCode: code, Output: output, RootPolicy: policy}
}

func (s *Service) run(ctx context.Context, timeout time.Duration, command string, args, extraEnv []string) (int, string, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	cmdArgs := append([]string{command}, args...)
	cmd := exec.CommandContext(ctx, "bash", cmdArgs...)
	cmd.Env = append(os.Environ(), extraEnv...)
	var buf limitedBuffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	err := cmd.Run()
	if ctx.Err() != nil {
		return -1, safety.Redact(buf.String()), fmt.Errorf("command timed out after %s", timeout)
	}
	if err == nil {
		return 0, safety.Redact(buf.String()), nil
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		return exitErr.ExitCode(), safety.Redact(buf.String()), err
	}
	return -1, safety.Redact(buf.String()), err
}

type limitedBuffer struct{ bytes.Buffer }

func (b *limitedBuffer) Write(p []byte) (int, error) {
	original := len(p)
	remaining := outputLimit - b.Len()
	if remaining > 0 {
		if len(p) > remaining {
			p = p[:remaining]
		}
		_, _ = b.Buffer.Write(p)
	}
	return original, nil
}

func (b *limitedBuffer) String() string {
	s := b.Buffer.String()
	if b.Len() >= outputLimit {
		s += "\n[output truncated]\n"
	}
	return s
}

func newRunID(prefix string) string {
	var b [6]byte
	_, _ = rand.Read(b[:])
	return fmt.Sprintf("%s-%s-%s", prefix, time.Now().UTC().Format("20060102T150405Z"), hex.EncodeToString(b[:]))
}
