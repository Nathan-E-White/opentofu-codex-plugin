package safety

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// PathPolicy confines stack paths when roots are configured. An empty root set
// permits explicit absolute paths, which keeps local development usable while
// allowing production installs to opt into confinement with OPENTOFU_MCP_ROOTS.
type PathPolicy struct {
	roots []string
}

func NewPathPolicy(roots []string) (*PathPolicy, error) {
	p := &PathPolicy{}
	for _, root := range roots {
		if strings.TrimSpace(root) == "" {
			continue
		}
		resolved, err := canonicalDir(root)
		if err != nil {
			return nil, fmt.Errorf("manifest root %q: %w", root, err)
		}
		p.roots = append(p.roots, resolved)
	}
	return p, nil
}

func (p *PathPolicy) Restricted() bool { return len(p.roots) > 0 }

func (p *PathPolicy) ResolveDir(candidate string) (string, error) {
	if !filepath.IsAbs(candidate) {
		return "", errors.New("stack_path must be absolute")
	}
	resolved, err := canonicalDir(candidate)
	if err != nil {
		return "", err
	}
	if len(p.roots) == 0 {
		return resolved, nil
	}
	for _, root := range p.roots {
		if within(root, resolved) {
			return resolved, nil
		}
	}
	return "", fmt.Errorf("stack_path %q is outside OPENTOFU_MCP_ROOTS", resolved)
}

func canonicalDir(path string) (string, error) {
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	resolved, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return "", err
	}
	info, err := os.Stat(resolved)
	if err != nil {
		return "", err
	}
	if !info.IsDir() {
		return "", fmt.Errorf("%q is not a directory", resolved)
	}
	return filepath.Clean(resolved), nil
}

func within(root, candidate string) bool {
	rel, err := filepath.Rel(root, candidate)
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}
