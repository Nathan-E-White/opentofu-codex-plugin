package safety

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

var (
	ErrConfirmation = errors.New("confirmation token does not match")
	ErrConsumed     = errors.New("plan has already been consumed")
	ErrExpired      = errors.New("plan has expired")
	ErrDrift        = errors.New("stack configuration or plan artifact changed")
)

type Plan struct {
	ID           string    `json:"id"`
	StackPath    string    `json:"stack_path"`
	Workspace    string    `json:"workspace"`
	Profile      string    `json:"profile"`
	BackendHint  string    `json:"backend_hint,omitempty"`
	RunID        string    `json:"run_id"`
	PlanPath     string    `json:"plan_path"`
	PlanSHA256   string    `json:"plan_sha256"`
	ConfigSHA256 string    `json:"config_sha256"`
	CreatedAt    time.Time `json:"created_at"`
	ExpiresAt    time.Time `json:"expires_at"`
	EvidenceDir  string    `json:"evidence_dir"`
	SummaryPath  string    `json:"summary_path"`
	PlanJSONPath string    `json:"plan_json_path"`
}

func (p Plan) ConfirmationToken() string {
	return fmt.Sprintf("CONFIRM apply %s %s", p.Workspace, p.ID)
}

type Store struct {
	root string
	ttl  time.Duration
	now  func() time.Time
}

func NewStore(stackPath string, ttl time.Duration, now func() time.Time) (*Store, error) {
	if now == nil {
		now = time.Now
	}
	root := filepath.Join(stackPath, ".tofu-artifacts", "mcp", "plans")
	if err := os.MkdirAll(root, 0o700); err != nil {
		return nil, err
	}
	return &Store{root: root, ttl: ttl, now: now}, nil
}

func (s *Store) Create(p Plan) (Plan, error) {
	planHash, err := HashFile(p.PlanPath)
	if err != nil {
		return Plan{}, fmt.Errorf("hash plan: %w", err)
	}
	configHash, err := HashConfig(p.StackPath)
	if err != nil {
		return Plan{}, fmt.Errorf("hash stack configuration: %w", err)
	}
	p.PlanSHA256 = planHash
	p.ConfigSHA256 = configHash
	p.CreatedAt = s.now().UTC()
	p.ExpiresAt = p.CreatedAt.Add(s.ttl)
	p.ID = ""
	b, err := json.Marshal(p)
	if err != nil {
		return Plan{}, err
	}
	sum := sha256.Sum256(b)
	p.ID = hex.EncodeToString(sum[:])
	record, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return Plan{}, err
	}
	path := filepath.Join(s.root, p.ID+".json")
	if err := writeExclusive(path, append(record, '\n')); err != nil {
		return Plan{}, err
	}
	return p, nil
}

func (s *Store) Load(id string) (Plan, error) {
	if len(id) != 64 || strings.Trim(id, "0123456789abcdef") != "" {
		return Plan{}, errors.New("invalid plan_id")
	}
	b, err := os.ReadFile(filepath.Join(s.root, id+".json"))
	if err != nil {
		return Plan{}, err
	}
	var p Plan
	if err := json.Unmarshal(b, &p); err != nil {
		return Plan{}, err
	}
	if p.ID != id {
		return Plan{}, errors.New("plan record identity mismatch")
	}
	return p, nil
}

// Consume atomically claims the plan, then validates confirmation, expiry, and
// drift. A claimed plan cannot be retried after an uncertain apply result.
func (s *Store) Consume(id, confirmation string) (Plan, error) {
	p, err := s.Load(id)
	if err != nil {
		return Plan{}, err
	}
	if confirmation != p.ConfirmationToken() {
		return Plan{}, ErrConfirmation
	}
	if !s.now().Before(p.ExpiresAt) {
		return Plan{}, ErrExpired
	}
	planHash, err := HashFile(p.PlanPath)
	if err != nil || planHash != p.PlanSHA256 {
		return Plan{}, ErrDrift
	}
	configHash, err := HashConfig(p.StackPath)
	if err != nil || configHash != p.ConfigSHA256 {
		return Plan{}, ErrDrift
	}
	marker := filepath.Join(s.root, id+".consumed")
	if err := writeExclusive(marker, []byte(s.now().UTC().Format(time.RFC3339Nano)+"\n")); err != nil {
		if errors.Is(err, os.ErrExist) {
			return Plan{}, ErrConsumed
		}
		return Plan{}, err
	}
	// Recheck after claiming the plan so a concurrent file change cannot slip
	// between validation and the single-use marker.
	planHash, err = HashFile(p.PlanPath)
	if err != nil || planHash != p.PlanSHA256 {
		return Plan{}, ErrDrift
	}
	configHash, err = HashConfig(p.StackPath)
	if err != nil || configHash != p.ConfigSHA256 {
		return Plan{}, ErrDrift
	}
	return p, nil
}

func writeExclusive(path string, data []byte) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.Write(data)
	return err
}

func HashFile(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// HashConfig binds a plan to the files that define an OpenTofu stack without
// reading state, credentials, .terraform contents, or generated evidence.
func HashConfig(root string) (string, error) {
	var files []string
	err := filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if path != root && (d.Name() == ".terraform" || d.Name() == ".tofu-artifacts" || d.Name() == ".git") {
				return filepath.SkipDir
			}
			return nil
		}
		name := d.Name()
		if strings.HasSuffix(name, ".tf") || strings.HasSuffix(name, ".tf.json") || strings.HasSuffix(name, ".tfvars") || strings.HasSuffix(name, ".tfvars.json") || name == ".terraform.lock.hcl" || name == "terraform.lock.hcl" {
			files = append(files, path)
		}
		return nil
	})
	if err != nil {
		return "", err
	}
	sort.Strings(files)
	h := sha256.New()
	for _, path := range files {
		rel, _ := filepath.Rel(root, path)
		_, _ = io.WriteString(h, rel+"\x00")
		f, err := os.Open(path)
		if err != nil {
			return "", err
		}
		if _, err := io.Copy(h, f); err != nil {
			f.Close()
			return "", err
		}
		f.Close()
		_, _ = io.WriteString(h, "\x00")
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
