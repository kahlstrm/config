package lab

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
)

func QueryJSON(ctx context.Context, input, expression string, args ...string) (string, error) {
	args = append(args, expression)
	cmd := exec.CommandContext(ctx, "jq", args...)
	cmd.Stdin = strings.NewReader(input)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("jq: %w: %s", err, output)
	}
	return strings.TrimSpace(string(output)), nil
}

func VerifyAdoptionPlan(ctx context.Context, plan string, recovery bool) error {
	expression := `.resource_changes[] | select(.change.actions != ["no-op"]) | select((((.type == "local_file" or .type == "routeros_file") and .name == "script" and .change.actions == ["create"]) or (.type == "routeros_move_items" and (.name == "ipv4_filter" or .name == "ipv6_filter") and (.change.actions == ["create"] or ($recovery and .change.actions == ["update"])))) | not) | .address`
	unexpected, err := QueryJSON(ctx, plan, expression, "-r", "--argjson", "recovery", fmt.Sprint(recovery))
	if err != nil {
		return err
	}
	if unexpected != "" {
		return fmt.Errorf("bootstrap differs from Terraform before apply: %s", unexpected)
	}
	return nil
}
