// Provisioning journals each remotely allocated identity before continuing. Random
// request names recover ambiguous creation responses; retries verify exact DNS
// ownership and retirement never deletes reassigned records.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
)

type cloudflareAPI struct {
	token, base string
	client      *http.Client
}
type cloudflareError struct {
	status int
	codes  []int
}

func (e *cloudflareError) Error() string {
	return fmt.Sprintf("Cloudflare request failed (HTTP %d, codes %v)", e.status, e.codes)
}
func cloudflareMissing(err error) bool {
	var failure *cloudflareError
	return errors.As(err, &failure) && failure.status == 404
}
func (api cloudflareAPI) request(ctx context.Context, method, path string, body, result any) error {
	var input io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			return err
		}
		input = bytes.NewReader(data)
	}
	req, err := http.NewRequestWithContext(ctx, method, api.base+path, input)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+api.token)
	req.Header.Set("Content-Type", "application/json")
	res, err := api.client.Do(req)
	if err != nil {
		return fmt.Errorf("Cloudflare %s request failed: %w", method, err)
	}
	defer res.Body.Close()
	var envelope struct {
		Success bool
		Result  json.RawMessage
		Errors  []struct{ Code int }
	}
	if err = json.NewDecoder(io.LimitReader(res.Body, 1<<20)).Decode(&envelope); err != nil {
		return fmt.Errorf("Cloudflare returned invalid response (HTTP %d)", res.StatusCode)
	}
	if res.StatusCode < 200 || res.StatusCode >= 300 || !envelope.Success {
		var codes []int
		for _, e := range envelope.Errors {
			codes = append(codes, e.Code)
		}
		return &cloudflareError{res.StatusCode, codes}
	}
	if result != nil {
		return json.Unmarshal(envelope.Result, result)
	}
	return nil
}

type cloudflareTunnel struct {
	ID, Name  string
	DeletedAt *string `json:"deleted_at"`
}
type cloudflareDNS struct {
	ID, Name, Content, Type string
	Proxied                 bool
}

func (s tunnelState) ownsDNS(record cloudflareDNS) bool {
	return record.Type == "CNAME" && record.Content == s.ID+".cfargotunnel.com" && (record.Name == s.appHost() || record.Name == s.filesHost())
}
func (api cloudflareAPI) allocate(ctx context.Context, s *tunnelState, path string) error {
	var zone struct{ Name string }
	if err := api.request(ctx, "GET", "/zones/"+s.ZoneID, nil, &zone); err != nil {
		return err
	}
	if zone.Name != s.Domain {
		return errors.New("configured domain must exactly match the Cloudflare zone for free first-level certificates")
	}
	base := "/accounts/" + s.AccountID + "/cfd_tunnel"
	if s.ID == "" {
		var found []cloudflareTunnel
		if err := api.request(ctx, "GET", base+"?name="+url.QueryEscape(s.Name)+"&is_deleted=false", nil, &found); err != nil {
			return err
		}
		if len(found) > 1 {
			return errors.New("ambiguous tunnel allocation name; inspect the host state before retrying")
		}
		var tunnel cloudflareTunnel
		if len(found) == 1 {
			tunnel = found[0]
		} else if err := api.request(ctx, "POST", base, map[string]any{"name": s.Name, "config_src": "cloudflare"}, &tunnel); err != nil {
			return err
		}
		if !tunnelUUID.MatchString(tunnel.ID) || tunnel.DeletedAt != nil {
			return errors.New("Cloudflare returned an invalid tunnel identity")
		}
		s.ID = tunnel.ID
		if err := writePrivateJSON(path, s); err != nil {
			return err
		}
	}
	var remote cloudflareTunnel
	if err := api.request(ctx, "GET", base+"/"+s.ID, nil, &remote); err != nil {
		return fmt.Errorf("inspect existing tunnel; refusing replacement: %w", err)
	}
	if remote.ID != s.ID || remote.Name != s.Name || remote.DeletedAt != nil {
		return errors.New("tunnel identity changed; refusing to adopt or replace it")
	}
	for _, host := range []string{s.appHost(), s.filesHost()} {
		var record cloudflareDNS
		if id := s.DNSRecords[host]; id != "" {
			if err := api.request(ctx, "GET", "/zones/"+s.ZoneID+"/dns_records/"+id, nil, &record); err != nil {
				return err
			}
		} else {
			var records []cloudflareDNS
			endpoint := "/zones/" + s.ZoneID + "/dns_records"
			if err := api.request(ctx, "GET", endpoint+"?name="+url.QueryEscape(host), nil, &records); err != nil {
				return err
			}
			if len(records) > 1 {
				return fmt.Errorf("DNS collision for %s", host)
			}
			if len(records) == 1 {
				record = records[0]
			} else if err := api.request(ctx, "POST", endpoint, map[string]any{"type": "CNAME", "name": host, "content": s.ID + ".cfargotunnel.com", "proxied": true, "ttl": 1}, &record); err != nil {
				return err
			}
		}
		if record.Name != host || !s.ownsDNS(record) || !record.Proxied || record.ID == "" {
			return fmt.Errorf("DNS record for %s belongs to another route; refusing to change it", host)
		}
		s.DNSRecords[host] = record.ID
		if err := writePrivateJSON(path, s); err != nil {
			return err
		}
	}
	tokenPath := filepath.Join(filepath.Dir(path), "runtime-token")
	if _, err := os.Stat(tokenPath); errors.Is(err, os.ErrNotExist) {
		var token string
		if err = api.request(ctx, "GET", base+"/"+s.ID+"/token", nil, &token); err != nil {
			return err
		}
		if token == "" {
			return errors.New("Cloudflare returned an empty runtime token")
		}
		return writePrivate(tokenPath, []byte(token))
	} else {
		return err
	}
}
func (api cloudflareAPI) route(ctx context.Context, s tunnelState, port string) error {
	origin := "http://127.0.0.1:" + port
	ingress := []map[string]string{{"hostname": s.appHost(), "service": origin}, {"hostname": s.filesHost(), "service": origin}, {"service": "http_status:404"}}
	return api.request(ctx, "PUT", "/accounts/"+s.AccountID+"/cfd_tunnel/"+s.ID+"/configurations", map[string]any{"config": map[string]any{"ingress": ingress}}, nil)
}
func (api cloudflareAPI) retire(ctx context.Context, s *tunnelState) error {
	if s.ID == "" {
		return errors.New("allocation identity is pending; run up --tunnel to recover it before retirement")
	}
	var tunnel cloudflareTunnel
	err := api.request(ctx, "GET", "/accounts/"+s.AccountID+"/cfd_tunnel/"+s.ID, nil, &tunnel)
	if err != nil && !cloudflareMissing(err) {
		return err
	}
	if err == nil && (tunnel.ID != s.ID || tunnel.Name != s.Name) {
		return errors.New("tunnel ownership changed; refusing retirement")
	}
	records := map[string]cloudflareDNS{}
	for _, host := range []string{s.appHost(), s.filesHost()} {
		var matches []cloudflareDNS
		if err := api.request(ctx, "GET", "/zones/"+s.ZoneID+"/dns_records?name="+url.QueryEscape(host), nil, &matches); err != nil {
			return err
		}
		for _, record := range matches {
			if !s.ownsDNS(record) {
				return fmt.Errorf("DNS record %s no longer belongs to this tunnel; refusing retirement", record.ID)
			}
			records[record.ID] = record
		}
	}
	for _, id := range s.DNSRecords {
		var record cloudflareDNS
		err := api.request(ctx, "GET", "/zones/"+s.ZoneID+"/dns_records/"+id, nil, &record)
		if cloudflareMissing(err) {
			continue
		}
		if err != nil {
			return err
		}
		if !s.ownsDNS(record) {
			return fmt.Errorf("DNS record %s was reassigned; refusing retirement", id)
		}
		records[id] = record
	}
	for id := range records {
		if err := api.request(ctx, "DELETE", "/zones/"+s.ZoneID+"/dns_records/"+id, nil, nil); err != nil && !cloudflareMissing(err) {
			return err
		}
	}
	err = api.request(ctx, "DELETE", "/accounts/"+s.AccountID+"/cfd_tunnel/"+s.ID, nil, nil)
	if cloudflareMissing(err) {
		return nil
	}
	return err
}
