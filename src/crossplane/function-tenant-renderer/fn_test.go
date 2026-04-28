package main

import (
	"context"
	"strings"
	"testing"

	"github.com/google/go-cmp/cmp"
	"github.com/google/go-cmp/cmp/cmpopts"
	"google.golang.org/protobuf/testing/protocmp"
	"google.golang.org/protobuf/types/known/durationpb"

	"github.com/crossplane/function-sdk-go/logging"
	fnv1 "github.com/crossplane/function-sdk-go/proto/v1"
	"github.com/crossplane/function-sdk-go/resource"
	"github.com/crossplane/function-sdk-go/response"
)

func TestRunFunction(t *testing.T) {
	type args struct {
		ctx context.Context
		req *fnv1.RunFunctionRequest
	}
	type want struct {
		rsp *fnv1.RunFunctionResponse
		err error
	}

	cases := map[string]struct {
		reason string
		args   args
		want   want
	}{
		"FatalOnMissingObservedXR": {
			reason: "The Function should return a fatal result when no observed XR is present",
			args: args{
				ctx: context.Background(),
				req: &fnv1.RunFunctionRequest{
					Meta: &fnv1.RequestMeta{Tag: "no-xr"},
				},
			},
			want: want{
				rsp: &fnv1.RunFunctionResponse{
					Meta: &fnv1.ResponseMeta{Tag: "no-xr", Ttl: durationpb.New(response.DefaultTTL)},
					Results: []*fnv1.Result{
						{
							Severity: fnv1.Severity_SEVERITY_FATAL,
							Target:   fnv1.Target_TARGET_COMPOSITE.Enum(),
						},
					},
				},
			},
		},
		"RendersManifestsForValidTenant": {
			reason: "The Function should render manifests and return a normal result for a valid Tenant XR and input",
			args: args{
				ctx: context.Background(),
				req: &fnv1.RunFunctionRequest{
					Meta: &fnv1.RequestMeta{Tag: "render"},
					Observed: &fnv1.State{
						Composite: &fnv1.Resource{
							Resource: resource.MustStructJSON(`{
								"apiVersion": "idp.rezakara.demo/v1alpha1",
								"kind": "Tenant",
								"metadata": {"name": "acme"},
								"spec": {
									"dnsName": "acme",
									"owner": {"team": "platform", "email": "platform@example.com"},
									"argocd": {
										"syncPolicy": {
											"automatedSync": true,
											"prune": true,
											"selfHeal": true
										}
									}
								}
							}`),
						},
					},
					Input: resource.MustStructJSON(`{
						"apiVersion": "tenant.rezakara.demo/v1alpha1",
						"kind": "PlatformConfig",
						"clusters": [
							{"name": "minikube-workload", "environmentPrefix": "wl"}
						],
						"rbac": {
							"roles": [
								{
									"name": "admin",
									"policies": [
										{"resource": "applications", "actions": ["get", "update"]}
									]
								}
							]
						}
					}`),
				},
			},
			want: want{
				rsp: &fnv1.RunFunctionResponse{
					Meta: &fnv1.ResponseMeta{Tag: "render", Ttl: durationpb.New(response.DefaultTTL)},
					Results: []*fnv1.Result{
						{
							Severity: fnv1.Severity_SEVERITY_NORMAL,
							Message:  `Rendered tenant "acme" manifests to Git`,
							Target:   fnv1.Target_TARGET_COMPOSITE.Enum(),
						},
					},
				},
			},
		},
	}

	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			f := &Function{
				log:                  logging.NewNopLogger(),
				exportRepoURL:        "kubepave-tenants",
				exportRepoBranch:     "main",
				exportRepoBasePath:   "tenants",
				crossplaneNamespace:  "crossplane",
				baselineRepoURL:      "https://github.com/rezakaramad/kubepave.git",
				baselineRepoBranch:   "main",
				baselineRepoBasePath: "charts/baseline-tenant",
				gitopsRepoURL:        "https://github.com/rezakaramad/kubepave.git",
				gitopsRepoBranch:     "main",
				gitopsRepoBasePath:   "charts/gitops-tenant",
			}
			rsp, err := f.RunFunction(tc.args.ctx, tc.args.req)

			// For fatal cases only check severity; message contains internal details we don't want to pin.
			if tc.want.rsp != nil && len(tc.want.rsp.Results) > 0 && tc.want.rsp.Results[0].Severity == fnv1.Severity_SEVERITY_FATAL {
				if len(rsp.Results) == 0 || rsp.Results[0].Severity != fnv1.Severity_SEVERITY_FATAL {
					t.Errorf("%s: expected a fatal result, got: %v", tc.reason, rsp.Results)
				}
				return
			}

			// For normal results, verify the message prefix.
			if tc.want.rsp != nil && len(tc.want.rsp.Results) > 0 {
				if len(rsp.Results) == 0 {
					t.Errorf("%s: expected results but got none", tc.reason)
					return
				}
				wantMsg := tc.want.rsp.Results[0].Message
				if !strings.Contains(rsp.Results[0].Message, wantMsg) {
					t.Errorf("%s: got message %q, want it to contain %q", tc.reason, rsp.Results[0].Message, wantMsg)
				}
			}

			if diff := cmp.Diff(tc.want.err, err, cmpopts.EquateErrors()); diff != "" {
				t.Errorf("%s\nf.RunFunction(...): -want err, +got err:\n%s", tc.reason, diff)
			}

			_ = protocmp.Transform()
		})
	}
}
