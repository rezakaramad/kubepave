package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	"golang.org/x/net/publicsuffix"
)

type PDNSClient interface {
	CheckDNSAvailable(ctx context.Context, fqdn string) (DNSAvailabilityResult, error)
}

type DNSAvailabilityResult struct {
	Available bool
	Reason    string
}

// ---------------------------------------------------------------------
// Implementation
// ---------------------------------------------------------------------

type powerDNSClient struct {
	baseURL string
	apiKey  string
	client  *http.Client
}

// Constructor with injectable HTTP client
func NewPowerDNSClient(baseURL, apiKey string, client *http.Client) PDNSClient {
	if client == nil {
		// Default HTTP client with timeout
		client = &http.Client{Timeout: 3 * time.Second}
	}

	return &powerDNSClient{
		baseURL: baseURL,
		apiKey:  apiKey,
		client:  client,
	}
}

// ---------------------------------------------------------------------
// API call
// ---------------------------------------------------------------------

func (p *powerDNSClient) CheckDNSAvailable(ctx context.Context, fqdn string) (DNSAvailabilityResult, error) {
	// Ensure fqdn always has trailing dot (PowerDNS format)
	fqdn = ensureTrailingDot(fqdn)

	// Extract authoritative zone from fqdn
	zone, err := extractZone(fqdn)
	if err != nil {
		return DNSAvailabilityResult{}, err
	}

	// Build PowerDNS zone endpoint URL
	url := fmt.Sprintf("%s/servers/localhost/zones/%s", p.baseURL, zone)

	// Create HTTP request with context
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return DNSAvailabilityResult{}, fmt.Errorf("build request: %w", err)
	}

	// Add API key header for authentication
	req.Header.Set("X-API-Key", p.apiKey)

	// Execute HTTP request to PowerDNS
	resp, err := p.client.Do(req)
	if err != nil {
		return DNSAvailabilityResult{}, fmt.Errorf("pdns request failed: %w", err)
	}
	defer resp.Body.Close()

	// Zone not found → no records exist → fqdn is available
	if resp.StatusCode == http.StatusNotFound {
		return DNSAvailabilityResult{
			Available: true,
		}, nil
	}

	// Any non-200 (other than 404) is treated as an error
	if resp.StatusCode != http.StatusOK {
		return DNSAvailabilityResult{}, fmt.Errorf("pdns unexpected status: %d", resp.StatusCode)
	}

	// Minimal struct to decode only needed fields from response
	var zoneData struct {
		RRsets []struct {
			Name string `json:"name"`
			Type string `json:"type"`
		} `json:"rrsets"`
	}

	// Decode JSON response body into struct
	if err := json.NewDecoder(resp.Body).Decode(&zoneData); err != nil {
		return DNSAvailabilityResult{}, fmt.Errorf("decode pdns response: %w", err)
	}

	// Check if fqdn already exists among returned RRsets
	for _, rr := range zoneData.RRsets {
		if rr.Name == fqdn {
			return DNSAvailabilityResult{
				Available: false,
				Reason:    fmt.Sprintf("dns %q already exists in PowerDNS", fqdn),
			}, nil
		}
	}

	// No matching record found → fqdn is available
	return DNSAvailabilityResult{
		Available: true,
	}, nil
}

// ---------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------

// extractZone determines the authoritative zone using public suffix list.
// Example:
// foo.bar.example.co.uk. → example.co.uk.
func extractZone(fqdn string) (string, error) {
	// Remove trailing dot before processing
	trimmed := strings.TrimSuffix(fqdn, ".")

	// Determine effective TLD+1 (authoritative zone)
	domain, err := publicsuffix.EffectiveTLDPlusOne(trimmed)
	if err != nil {
		return "", fmt.Errorf("cannot determine zone for fqdn %q: %w", fqdn, err)
	}

	// Return zone in PowerDNS format (with trailing dot)
	return domain + ".", nil
}

// Ensures fqdn ends with a trailing dot (required by PowerDNS)
func ensureTrailingDot(s string) string {
	if strings.HasSuffix(s, ".") {
		return s
	}
	return s + "."
}
