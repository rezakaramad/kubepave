// Package main implements a Composition Function.
package main

import (
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/alecthomas/kong"
	"github.com/crossplane/function-sdk-go"
	"github.com/crossplane/function-tenantrequest-renderer/model"

	"k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"

	ctrlclient "sigs.k8s.io/controller-runtime/pkg/client"
	ctrlconfig "sigs.k8s.io/controller-runtime/pkg/client/config"
)

// CLI of this Function.
type CLI struct {
	// Enable debug logging. By default, only info logs are emitted.
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

	workloadClusters := parseClusters(getEnv("WORKLOAD_CLUSTERS", ""))

	// ------------------------------------------------------------------
	// Build Kubernetes client
	// ------------------------------------------------------------------
	// Load the Kubernetes client configuration for this process.
	// This figures out how the app should connect to the Kubernetes API server.
	// If that config cannot be found or built, stop startup and return the error
	cfg, err := ctrlconfig.GetConfig()
	if err != nil {
		return err
	}

	// Create a registry of Kubernetes resource types the client knows how to work with.
	// Add the standard built-in Kubernetes objects (like Pods, Services, Deployments) to that registry.
	scheme := runtime.NewScheme()
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))

	// Build a Kubernetes client using the config and the scheme we prepared above.
	// This client is what the function will use to talk to the Kubernetes API.
	// If client creation fails, stop startup and return the error.
	kubeClient, err := ctrlclient.New(cfg, ctrlclient.Options{
		Scheme: scheme,
	})
	if err != nil {
		return err
	}

	// Create a custom HTTP client to control timeouts, transport, retries, etc.
	httpClient := &http.Client{
		Timeout: 5 * time.Second,
	}

	// Create a PowerDNS client using settings from environment variables.
	// PDNS_API_URL tells it where the PowerDNS API is, and PDNS_API_KEY is used for authentication.
	// If those env vars are missing, fall back to the default URL and an empty API key.
	pdnsClient := New(
		getEnv("PDNS_API_URL", "http://host.minikube.internal:5380/api/v1"),
		getEnv("PDNS_API_KEY", ""),
		httpClient,
	)

	// ------------------------------------------------------------------
	// Function setup
	// ------------------------------------------------------------------
	fn := &Function{
		log:                 log,
		workloadClusters:    workloadClusters,
		kube:                kubeClient,
		pdns:                pdnsClient,
		dnsBaseDomain:       getEnv("DNS_BASE_DOMAIN", "rezakara.demo"),
		crossplaneNamespace: getEnv("CROSSPLANE_NAMESPACE", "crossplane"),
	}

	// Run a server, and whenever a Crossplane request comes in, hand it to this fn object
	return function.Serve(fn,
		function.Listen(c.Network, c.Address),
		function.MTLSCertificates(c.TLSCertsDir),
		function.Insecure(c.Insecure),
		function.MaxRecvMessageSize(c.MaxRecvMessageSize*1024*1024))
}

func parseClusters(s string) []model.Cluster {
	var out []model.Cluster

	for _, item := range strings.Split(s, ",") {
		parts := strings.Split(item, ":")
		if len(parts) != 2 {
			continue // or log warning
		}

		out = append(out, model.Cluster{
			Name:   strings.TrimSpace(parts[0]),
			Prefix: strings.TrimSpace(parts[1]),
		})
	}

	return out
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
