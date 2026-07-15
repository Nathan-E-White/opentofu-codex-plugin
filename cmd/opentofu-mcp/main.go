package main

import (
	"context"
	"log"
	"os"
	"path/filepath"
	"strings"

	tofu "github.com/Nathan-E-White/opentofu-codex-plugin/internal/opentofu"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func main() {
	root := os.Getenv("OPENTOFU_PLUGIN_ROOT")
	if root == "" {
		cwd, err := os.Getwd()
		if err != nil {
			log.Fatal(err)
		}
		root = cwd
	}
	root, _ = filepath.Abs(root)
	var roots []string
	if configured := os.Getenv("OPENTOFU_MCP_ROOTS"); configured != "" {
		roots = filepath.SplitList(configured)
	}
	service, err := tofu.NewService(root, roots)
	if err != nil {
		log.Fatal(err)
	}

	server := mcp.NewServer(&mcp.Implementation{Name: "opentofu", Version: "0.2.0"}, &mcp.ServerOptions{
		Instructions: "Use opentofu_preflight before policy or planning. Apply only a fresh opentofu_plan using its exact confirmation token. Never use MCP apply for destroy, import, state mutation, backend migration, or workspace mutation; route those through the bundled skills and guarded scripts. Evidence reads must remain under the stack's .tofu-artifacts directory.",
	})
	closed := boolPtr(false)
	open := boolPtr(true)
	destructive := boolPtr(true)
	nondestructive := boolPtr(false)

	mcp.AddTool(server, &mcp.Tool{
		Name: "opentofu_preflight", Description: "Inspect an explicit OpenTofu stack context and run the plugin's non-mutating preflight checks.",
		Annotations: &mcp.ToolAnnotations{Title: "OpenTofu preflight", ReadOnlyHint: false, DestructiveHint: nondestructive, OpenWorldHint: closed, IdempotentHint: true},
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in tofu.PreflightInput) (*mcp.CallToolResult, tofu.CommandOutput, error) {
		out, err := service.Preflight(ctx, in)
		return nil, out, err
	})

	mcp.AddTool(server, &mcp.Tool{
		Name: "opentofu_policy_check", Description: "Run formatting, validation, lint, and security policy gates and write bounded evidence for an explicit stack and profile.",
		Annotations: &mcp.ToolAnnotations{Title: "OpenTofu policy check", ReadOnlyHint: false, DestructiveHint: nondestructive, OpenWorldHint: open, IdempotentHint: false},
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in tofu.PolicyInput) (*mcp.CallToolResult, tofu.CommandOutput, error) {
		out, err := service.PolicyCheck(ctx, in)
		return nil, out, err
	})

	mcp.AddTool(server, &mcp.Tool{
		Name: "opentofu_plan", Description: "Create reviewable plan artifacts and a fresh immutable apply authorization bound to stack configuration, workspace, profile, and plan hash.",
		Annotations: &mcp.ToolAnnotations{Title: "OpenTofu plan", ReadOnlyHint: false, DestructiveHint: nondestructive, OpenWorldHint: open, IdempotentHint: false},
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in tofu.PlanInput) (*mcp.CallToolResult, tofu.PlanOutput, error) {
		out, err := service.Plan(ctx, in)
		return nil, out, err
	})

	mcp.AddTool(server, &mcp.Tool{
		Name: "opentofu_execute_plan", Description: "Apply one fresh immutable OpenTofu plan after exact confirmation; the plan is single-use and rejected after expiry or configuration drift.",
		Annotations: &mcp.ToolAnnotations{Title: "Apply OpenTofu plan", ReadOnlyHint: false, DestructiveHint: destructive, OpenWorldHint: open, IdempotentHint: false},
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in tofu.ExecuteInput) (*mcp.CallToolResult, tofu.ExecuteOutput, error) {
		out, err := service.ExecutePlan(ctx, in)
		return nil, out, err
	})

	mcp.AddTool(server, &mcp.Tool{
		Name: "opentofu_get_evidence", Description: "Read a bounded evidence file beneath an explicit stack's .tofu-artifacts directory.",
		Annotations: &mcp.ToolAnnotations{Title: "Read OpenTofu evidence", ReadOnlyHint: true, OpenWorldHint: closed, IdempotentHint: true},
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in tofu.EvidenceInput) (*mcp.CallToolResult, tofu.EvidenceOutput, error) {
		out, err := service.ReadEvidence(ctx, in)
		return nil, out, err
	})

	if err := server.Run(context.Background(), &mcp.StdioTransport{}); err != nil && !strings.Contains(err.Error(), "EOF") {
		log.Printf("OpenTofu MCP server stopped: %v", err)
	}
}

func boolPtr(v bool) *bool { return &v }
