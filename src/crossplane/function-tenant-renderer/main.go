// Package main implements a Composition Function.
package main

import (
	"os"

	"github.com/alecthomas/kong"

	"github.com/crossplane/function-sdk-go"
)

// CLI of this Function.
type CLI struct {
	Debug bool `help:"Emit debug logs in addition to info logs." short:"d"`

	Network            string `default:"tcp"                                                                                        help:"Network on which to listen for gRPC connections."`
	Address            string `default:":9443"                                                                                      help:"Address at which to listen for gRPC connections."`
	TLSCertsDir        string `env:"TLS_SERVER_CERTS_DIR"                                                                           help:"Directory containing server certs (tls.key, tls.crt) and the CA used to verify client certificates (ca.crt)"`
	Insecure           bool   `help:"Run without mTLS credentials. If you supply this flag --tls-server-certs-dir will be ignored."`
	MaxRecvMessageSize int    `default:"4"                                                                                          help:"Maximum size of received messages in MB."`
}

// Run this Function.
func (c *CLI) Run() error {
	log, err := function.NewLogger(c.Debug)
	if err != nil {
		return err
	}

	// ------------------------------------------------------------------
	// Function setup
	// ------------------------------------------------------------------
	fn := &Function{
		log: log,

		exportRepoURL:        getEnv("EXPORT_REPO_URL", "kubepave-tenants"),
		exportRepoBranch:     getEnv("EXPORT_REPO_BRANCH", "main"),
		exportRepoBasePath:   getEnv("EXPORT_REPO_BASE_PATH", "tenants"),
		baselineRepoURL:      getEnv("BASELINE_REPO_URL", "kubepave"),
		baselineRepoBranch:   getEnv("BASELINE_REPO_BRANCH", "main"),
		baselineRepoBasePath: getEnv("BASELINE_REPO_BASE_PATH", "charts/baseline-tenant"),
		gitopsRepoURL:        getEnv("GITOPS_REPO_URL", "kubepave"),
		gitopsRepoBranch:     getEnv("GITOPS_REPO_BRANCH", "main"),
		gitopsRepoBasePath:   getEnv("GITOPS_REPO_BASE_PATH", "charts/gitops-tenant"),
		crossplaneNamespace:  getEnv("CROSSPLANE_NAMESPACE", "crossplane"),
	}

	// Run a server, and whenever a Crossplane request comes in, hand it to this fn object
	return function.Serve(fn,
		function.Listen(c.Network, c.Address),
		function.MTLSCertificates(c.TLSCertsDir),
		function.Insecure(c.Insecure),
		function.MaxRecvMessageSize(c.MaxRecvMessageSize*1024*1024))
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func main() {
	ctx := kong.Parse(&CLI{}, kong.Description("A Crossplane Composition Function."))
	ctx.FatalIfErrorf(ctx.Run())
}
