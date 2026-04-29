package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/spf13/cobra"
)

func main() {
	rootCmd := &cobra.Command{
		Use:   "kubectl-tenant",
		Short: "kubectl plugin for managing tenants",
	}

	rootCmd.AddCommand(newApproveCmd())
	rootCmd.AddCommand(newCompletionCmd(rootCmd))

	if err := rootCmd.Execute(); err != nil {
		os.Exit(1)
	}
}

func newApproveCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "approve <tenant>",
		Short: "Approve a tenant",
		Args:  cobra.ExactArgs(1),
		Run: func(cmd *cobra.Command, args []string) {
			approve(args[0])
		},
	}

	// 🔥 Dynamic autocomplete for tenant names
	cmd.ValidArgsFunction = func(
		cmd *cobra.Command,
		args []string,
		toComplete string,
	) ([]string, cobra.ShellCompDirective) {

		out, err := exec.Command(
			"kubectl",
			"get",
			"tenants.idp.rezakara.demo",
			"-o",
			"jsonpath={.items[*].metadata.name}",
		).Output()

		if err != nil {
			return nil, cobra.ShellCompDirectiveNoFileComp
		}

		names := strings.Fields(string(out))
		if len(names) == 0 {
			return nil, cobra.ShellCompDirectiveNoFileComp
		}

		// 🔍 Filter based on current input (important for UX)
		var filtered []string
		for _, n := range names {
			if strings.HasPrefix(n, toComplete) {
				filtered = append(filtered, n)
			}
		}

		return filtered, cobra.ShellCompDirectiveNoFileComp
	}

	return cmd
}

func newCompletionCmd(root *cobra.Command) *cobra.Command {
	return &cobra.Command{
		Use:   "completion [bash|zsh|fish]",
		Short: "Generate shell completion script",
		Args:  cobra.ExactArgs(1),
		Run: func(cmd *cobra.Command, args []string) {
			switch args[0] {
			case "bash":
				root.GenBashCompletion(os.Stdout)
			case "zsh":
				root.GenZshCompletion(os.Stdout)
			case "fish":
				root.GenFishCompletion(os.Stdout, true)
			default:
				fmt.Println("unsupported shell")
			}
		},
	}
}

func approve(name string) {
	// 1. Check idempotency — read current spec.approved
	out, err := exec.Command(
		"kubectl",
		"get",
		"tenants.idp.rezakara.demo",
		name,
		"-o",
		"jsonpath={.spec.approved}",
	).Output()

	if err != nil {
		fmt.Println("failed to fetch resource:", err)
		os.Exit(1)
	}

	if strings.TrimSpace(string(out)) == "true" {
		fmt.Println("Tenant already approved")
		return
	}

	// 2. Patch spec.approved = true
	cmd := exec.Command(
		"kubectl",
		"patch",
		"tenants.idp.rezakara.demo",
		name,
		"--type=merge",
		"-p",
		`{"spec":{"approved":true}}`,
	)

	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	if err := cmd.Run(); err != nil {
		fmt.Println("approval failed:", err)
		os.Exit(1)
	}

	fmt.Println("Tenant approved:", name)
}
