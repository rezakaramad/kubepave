package pdns

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	"golang.org/x/net/publicsuffix"
)

// Client defines the interface used by validation layer.
type Client interface {
	CheckDNSAvailable(ctx context.Context, fqdn string) (DNSAvailabilityResult, error)
}

// DNSAvailabilityResult represents the availability of a DNS name.
type DNSAvailabilityResult struct {
	Available bool
	Reason    string
}

// ---------------------------------------------------------------------
// Implementation
// ---------------------------------------------------------------------

type client struct {
	baseURL string
	apiKey  string
	client  *http.Client
}

// New creates a new PowerDNS client.
func New(baseURL, apiKey string, httpClient *http.Client) Client {
	if httpClient == nil {
		httpClient = &http.Client{
			Timeout: 3 * time.Second,
		}
	}

	return &client{
		baseURL: strings.TrimSuffix(baseURL, "/"),
		apiKey:  apiKey,
		client:  httpClient,
	}
}

// ---------------------------------------------------------------------
// API call
// ---------------------------------------------------------------------

func (c *client) CheckDNSAvailable(ctx context.Context, fqdn string) (DNSAvailabilityResult, error) {
	fqdn = ensureTrailingDot(fqdn)

	zone, err := extractZone(fqdn)
	if err != nil {
		return DNSAvailabilityResult{}, err
	}

	url := fmt.Sprintf("%s/servers/localhost/zones/%s", c.baseURL, zone)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return DNSAvailabilityResult{}, fmt.Errorf("build request: %w", err)
	}

	req.Header.Set("X-API-Key", c.apiKey)

	resp, err := c.client.Do(req)
	if err != nil {
		return DNSAvailabilityResult{}, fmt.Errorf("pdns request failed: %w", err)
	}
	defer resp.Body.Close()

	// Zone not found → DNS available
	if resp.StatusCode == http.StatusNotFound {
		return DNSAvailabilityResult{Available: true}, nil
	}

	if resp.StatusCode != http.StatusOK {
		return DNSAvailabilityResult{}, fmt.Errorf("pdns unexpected status: %d", resp.StatusCode)
	}

	var zoneData struct {
		RRsets []struct {
			Name string `json:"name"`
			Type string `json:"type"`
		} `json:"rrsets"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&zoneData); err != nil {
		return DNSAvailabilityResult{}, fmt.Errorf("decode pdns response: %w", err)
	}

	for _, rr := range zoneData.RRsets {
		if rr.Name == fqdn {
			return DNSAvailabilityResult{
				Available: false,
				Reason:    fmt.Sprintf("dns %q already exists", fqdn),
			}, nil
		}
	}

	return DNSAvailabilityResult{Available: true}, nil
}

// ---------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------

// BuildFQDN builds a DNS name like: pay.dev.rezakara.demo.
func BuildFQDN(name, prefix, base string) string {
	base = strings.TrimSuffix(base, ".")
	return fmt.Sprintf("%s.%s.%s.", name, prefix, base)
}

func extractZone(fqdn string) (string, error) {
	trimmed := strings.TrimSuffix(fqdn, ".")

	domain, err := publicsuffix.EffectiveTLDPlusOne(trimmed)
	if err != nil {
		return "", fmt.Errorf("cannot determine zone for fqdn %q: %w", fqdn, err)
	}

	return domain + ".", nil
}

func ensureTrailingDot(s string) string {
	if strings.HasSuffix(s, ".") {
		return s
	}
	return s + "."
}
