package mcpapp

import (
	"context"
	_ "embed"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

const DashboardURI = "ui://opentofu/operations-dashboard"

//go:embed dashboard.html
var dashboardHTML string

// Register adds the self-contained MCP Apps UI resource to the server.
func Register(server *mcp.Server) {
	server.AddResource(&mcp.Resource{
		URI:         DashboardURI,
		Name:        "opentofu-operations-dashboard",
		Title:       "OpenTofu Operations Dashboard",
		Description: "Interactive projection for OpenTofu context, policy, plans, applies, and evidence.",
		MIMEType:    "text/html;profile=mcp-app",
	}, readDashboard)
}

// ToolMeta connects an MCP tool to the dashboard and supplies concise host status text.
func ToolMeta(invoking, invoked string) mcp.Meta {
	return mcp.Meta{
		"openai/outputTemplate":          DashboardURI,
		"openai/toolInvocation/invoking": invoking,
		"openai/toolInvocation/invoked":  invoked,
		"openai/widgetAccessible":        true,
	}
}

// ResultMeta identifies the result currently projected by the dashboard.
func ResultMeta(tool string) mcp.Meta {
	return mcp.Meta{"opentofu/tool": tool}
}

func readDashboard(_ context.Context, _ *mcp.ReadResourceRequest) (*mcp.ReadResourceResult, error) {
	return &mcp.ReadResourceResult{Contents: []*mcp.ResourceContents{{
		URI:      DashboardURI,
		MIMEType: "text/html;profile=mcp-app",
		Text:     dashboardHTML,
		Meta: mcp.Meta{
			"openai/widgetDescription":   "OpenTofu stack context, policy, immutable plan, apply, and evidence dashboard.",
			"openai/widgetPrefersBorder": true,
			"openai/widgetCSP": mcp.Meta{
				"connect_domains":  []string{},
				"resource_domains": []string{},
			},
		},
	}}}, nil
}
