package mcpapp

import (
	"context"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func TestDashboardResourceContract(t *testing.T) {
	result, err := readDashboard(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Contents) != 1 {
		t.Fatalf("dashboard returned %d contents, want 1", len(result.Contents))
	}
	content := result.Contents[0]
	if content.URI != DashboardURI || content.MIMEType != "text/html;profile=mcp-app" {
		t.Fatalf("dashboard contract = %#v", content)
	}
	for _, expected := range []string{"OpenTofu Operations", "openai:set_globals", "opentofu_preflight"} {
		if !strings.Contains(content.Text, expected) {
			t.Fatalf("dashboard HTML missing %q", expected)
		}
	}
	if got := content.Meta["openai/widgetPrefersBorder"]; got != true {
		t.Fatalf("widget border metadata = %#v", got)
	}
}

func TestToolMetaTargetsDashboard(t *testing.T) {
	meta := ToolMeta("Planning OpenTofu", "OpenTofu plan ready")
	if got := meta["openai/outputTemplate"]; got != DashboardURI {
		t.Fatalf("output template = %#v", got)
	}
	if got := meta["openai/widgetAccessible"]; got != true {
		t.Fatalf("widget access = %#v", got)
	}
	if _, ok := any(meta).(mcp.Meta); !ok {
		t.Fatal("ToolMeta did not return mcp.Meta")
	}
}
