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
									"approved": true,
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
						Resources: map[string]*fnv1.Resource{
							"entra-group-admin-minikube-workload-wl": {
								Resource: resource.MustStructJSON(`{
									"apiVersion": "groups.azuread.m.upbound.io/v1beta1",
									"kind": "Group",
									"status": {
										"atProvider": {
											"objectId": "11111111-1111-1111-1111-111111111111"
										}
									}
								}`),
							},
						},
					},
					Input: resource.MustStructJSON(`{
						"apiVersion": "platform.rezakara.demo/v1beta1",
						"kind": "Input",
						"tenant": {
							"bindings": [
								{"name": "admin", "cluster": "minikube-workload", "environmentPrefix": "wl"}
							]
						}
					}`),
				},
			},
			want: want{
				rsp: &fnv1.RunFunctionResponse{
					Meta: &fnv1.ResponseMeta{Tag: "render", Ttl: durationpb.New(response.DefaultTTL)},
					Conditions: []*fnv1.Condition{
						{
							Type:   "Rendered",
							Status: fnv1.Status_STATUS_CONDITION_TRUE,
							Reason: "Available",
							Target: fnv1.Target_TARGET_COMPOSITE.Enum(),
						},
					},
				},
			},
		},
		"WaitsForPrincipalObjectID": {
			reason: "The Function should wait for principal object IDs before rendering GitOps manifests",
			args: args{
				ctx: context.Background(),
				req: &fnv1.RunFunctionRequest{
					Meta: &fnv1.RequestMeta{Tag: "waiting"},
					Observed: &fnv1.State{
						Composite: &fnv1.Resource{
							Resource: resource.MustStructJSON(`{
								"apiVersion": "idp.rezakara.demo/v1alpha1",
								"kind": "Tenant",
								"metadata": {"name": "acme"},
								"spec": {
									"dnsName": "acme",
									"approved": true,
									"owner": {"team": "platform", "email": "platform@example.com"}
								}
							}`),
						},
					},
					Input: resource.MustStructJSON(`{
						"apiVersion": "platform.rezakara.demo/v1beta1",
						"kind": "Input",
						"tenant": {
							"bindings": [
								{"name": "admin", "cluster": "minikube-workload", "environmentPrefix": "wl"}
							]
						}
					}`),
				},
			},
			want: want{
				rsp: &fnv1.RunFunctionResponse{
					Meta: &fnv1.ResponseMeta{Tag: "waiting", Ttl: durationpb.New(response.DefaultTTL)},
					Conditions: []*fnv1.Condition{
						{
							Type:   "Rendered",
							Status: fnv1.Status_STATUS_CONDITION_FALSE,
							Reason: "WaitingForPrincipalObjectID",
							Target: fnv1.Target_TARGET_COMPOSITE.Enum(),
						},
					},
				},
			},
		},
		"RendersManifestsForUserPrincipalTenant": {
			reason: "The Function should create a User principal when azure.principalType is set to user",
			args: args{
				ctx: context.Background(),
				req: &fnv1.RunFunctionRequest{
					Meta: &fnv1.RequestMeta{Tag: "free-tier"},
					Observed: &fnv1.State{
						Composite: &fnv1.Resource{
							Resource: resource.MustStructJSON(`{
								"apiVersion": "idp.rezakara.demo/v1alpha1",
								"kind": "Tenant",
								"metadata": {"name": "payment"},
								"spec": {
									"dnsName": "payment",
									"approved": true,
									"owner": {"team": "platform", "email": "platform@example.com"}
								}
							}`),
						},
						Resources: map[string]*fnv1.Resource{
							"entra-user-admin": {
								Resource: resource.MustStructJSON(`{
									"apiVersion": "users.azuread.m.upbound.io/v1beta1",
									"kind": "User",
									"status": {
										"atProvider": {
											"objectId": "22222222-2222-2222-2222-222222222222"
										}
									}
								}`),
							},
						},
					},
					Input: resource.MustStructJSON(`{
						"apiVersion": "platform.rezakara.demo/v1beta1",
						"kind": "Input",
						"azure": {
							"principalType": "user",
							"userPrincipalDomain": "rkaramadgmail.onmicrosoft.com"
						},
						"tenant": {
							"bindings": [
								{"name": "admin", "cluster": "minikube-workload", "environmentPrefix": "wl"}
							]
						}
					}`),
				},
			},
			want: want{
				rsp: &fnv1.RunFunctionResponse{
					Meta: &fnv1.ResponseMeta{Tag: "free-tier", Ttl: durationpb.New(response.DefaultTTL)},
					Conditions: []*fnv1.Condition{
						{
							Type:   "Rendered",
							Status: fnv1.Status_STATUS_CONDITION_TRUE,
							Reason: "Available",
							Target: fnv1.Target_TARGET_COMPOSITE.Enum(),
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

			if tc.want.rsp != nil && len(tc.want.rsp.Conditions) > 0 {
				if len(rsp.Conditions) == 0 {
					t.Errorf("%s: expected conditions but got none", tc.reason)
					return
				}
				wantCondition := tc.want.rsp.Conditions[0]
				gotCondition := rsp.Conditions[0]
				if gotCondition.GetType() != wantCondition.GetType() || gotCondition.GetStatus() != wantCondition.GetStatus() || gotCondition.GetReason() != wantCondition.GetReason() {
					t.Errorf("%s: got condition %+v, want type=%q status=%v reason=%q", tc.reason, gotCondition, wantCondition.GetType(), wantCondition.GetStatus(), wantCondition.GetReason())
				}
				if name == "RendersManifestsForValidTenant" && !strings.Contains(gotCondition.GetMessage(), `Rendered 2 resources for tenant "acme"`) {
					t.Errorf("%s: got condition message %q, want it to contain %q", tc.reason, gotCondition.GetMessage(), `Rendered 2 resources for tenant "acme"`)
				}
			}

			if name == "RendersManifestsForValidTenant" {
				if rsp.GetDesired() == nil || len(rsp.GetDesired().GetResources()) != 2 {
					t.Errorf("%s: expected 2 desired resources, got %d", tc.reason, len(rsp.GetDesired().GetResources()))
				}
				if _, ok := rsp.GetDesired().GetResources()["tenant-rendered-manifests"]; !ok {
					t.Errorf("%s: expected tenant-rendered-manifests desired resource", tc.reason)
				}
				if _, ok := rsp.GetDesired().GetResources()["entra-group-admin-minikube-workload-wl"]; !ok {
					t.Errorf("%s: expected Entra group desired resource", tc.reason)
				}
			}

			if name == "RendersManifestsForUserPrincipalTenant" {
				if rsp.GetDesired() == nil || len(rsp.GetDesired().GetResources()) != 4 {
					t.Errorf("%s: expected 4 desired resources in user principal mode, got %d", tc.reason, len(rsp.GetDesired().GetResources()))
				}
				if _, ok := rsp.GetDesired().GetResources()["tenant-rendered-manifests"]; !ok {
					t.Errorf("%s: expected tenant-rendered-manifests desired resource", tc.reason)
				}
				if _, ok := rsp.GetDesired().GetResources()["entra-user-admin"]; !ok {
					t.Errorf("%s: expected Entra user desired resource", tc.reason)
				}
				if _, ok := rsp.GetDesired().GetResources()["entra-user-password-admin"]; !ok {
					t.Errorf("%s: expected password generator desired resource", tc.reason)
				}
				if _, ok := rsp.GetDesired().GetResources()["entra-user-password-secret-admin"]; !ok {
					t.Errorf("%s: expected password secret desired resource", tc.reason)
				}
			}

			if name == "WaitsForPrincipalObjectID" {
				if rsp.GetDesired() == nil || len(rsp.GetDesired().GetResources()) != 1 {
					t.Errorf("%s: expected 1 desired resource while waiting, got %d", tc.reason, len(rsp.GetDesired().GetResources()))
				}
				if _, ok := rsp.GetDesired().GetResources()["entra-group-admin-minikube-workload-wl"]; !ok {
					t.Errorf("%s: expected Entra group desired resource while waiting", tc.reason)
				}
				if _, ok := rsp.GetDesired().GetResources()["tenant-rendered-manifests"]; ok {
					t.Errorf("%s: did not expect tenant-rendered-manifests while waiting for principal object IDs", tc.reason)
				}
				if !strings.Contains(rsp.Conditions[0].GetMessage(), `Waiting for principal object IDs for tenant "acme"`) {
					t.Errorf("%s: got condition message %q, want it to contain %q", tc.reason, rsp.Conditions[0].GetMessage(), `Waiting for principal object IDs for tenant "acme"`)
				}
			}

			if diff := cmp.Diff(tc.want.err, err, cmpopts.EquateErrors()); diff != "" {
				t.Errorf("%s\nf.RunFunction(...): -want err, +got err:\n%s", tc.reason, diff)
			}

			_ = protocmp.Transform()
		})
	}
}
