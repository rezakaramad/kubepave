package main

import (
	"context"
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

type fakePDNSClient struct{}

func (fakePDNSClient) CheckDNSAvailable(_ context.Context, _ string) (DNSAvailabilityResult, error) {
	return DNSAvailabilityResult{Available: true}, nil
}

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
		"FailsOnMissingInput": {
			reason: "The Function should return a fatal result when the required validator input is incomplete",
			args: args{
				ctx: context.Background(),
				req: &fnv1.RunFunctionRequest{
					Meta: &fnv1.RequestMeta{Tag: "missing-input"},
					Observed: &fnv1.State{
						Composite: &fnv1.Resource{Resource: resource.MustStructJSON(`{
							"apiVersion": "idp.rezakara.demo/v1alpha1",
							"kind": "Tenant",
							"metadata": {"name": "payment"},
							"spec": {
								"dnsName": "payment",
								"approved": false,
								"owner": {"team": "platform", "email": "platform@example.com"}
							}
						}`)},
					},
					Input: resource.MustStructJSON(`{
						"apiVersion": "platform.rezakara.demo/v1beta1",
						"kind": "Input"
					}`),
				},
			},
			want: want{
				rsp: &fnv1.RunFunctionResponse{
					Meta: &fnv1.ResponseMeta{Tag: "missing-input", Ttl: durationpb.New(response.DefaultTTL)},
					Results: []*fnv1.Result{
						{
							Severity: fnv1.Severity_SEVERITY_FATAL,
							Message:  "cannot parse function input: dns.baseDomain is required",
							Target:   fnv1.Target_TARGET_COMPOSITE.Enum(),
						},
					},
				},
			},
		},
		"WaitsForApproval": {
			reason: "The Function should validate successfully and wait for approval when the tenant is not approved",
			args: args{
				ctx: context.Background(),
				req: &fnv1.RunFunctionRequest{
					Meta: &fnv1.RequestMeta{Tag: "waiting"},
					Observed: &fnv1.State{
						Composite: &fnv1.Resource{Resource: resource.MustStructJSON(`{
							"apiVersion": "idp.rezakara.demo/v1alpha1",
							"kind": "Tenant",
							"metadata": {"name": "payment"},
							"spec": {
								"dnsName": "payment",
								"approved": false,
								"owner": {"team": "platform", "email": "platform@example.com"}
							}
						}`)},
					},
					Input: resource.MustStructJSON(`{
						"apiVersion": "platform.rezakara.demo/v1beta1",
						"kind": "Input",
						"dns": {"baseDomain": "rezakara.demo"},
						"clusters": [
							{"name": "minikube-workload", "prefix": "wl"}
						]
					}`),
				},
			},
			want: want{
				rsp: &fnv1.RunFunctionResponse{
					Meta: &fnv1.ResponseMeta{Tag: "waiting", Ttl: durationpb.New(response.DefaultTTL)},
					Conditions: []*fnv1.Condition{
						{
							Type:   "Valid",
							Status: fnv1.Status_STATUS_CONDITION_TRUE,
							Reason: "ValidationPassed",
							Target: fnv1.Target_TARGET_COMPOSITE.Enum(),
						},
						{
							Type:   "Approved",
							Status: fnv1.Status_STATUS_CONDITION_FALSE,
							Reason: "WaitingForApproval",
							Target: fnv1.Target_TARGET_COMPOSITE.Enum(),
						},
						{
							Type:   "Ready",
							Status: fnv1.Status_STATUS_CONDITION_FALSE,
							Reason: "WaitingForApproval",
							Target: fnv1.Target_TARGET_COMPOSITE.Enum(),
						},
					},
				},
			},
		},
	}

	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			f := &Function{log: logging.NewNopLogger(), pdns: fakePDNSClient{}}
			rsp, err := f.RunFunction(tc.args.ctx, tc.args.req)

			if diff := cmp.Diff(tc.want.rsp, rsp, protocmp.Transform(), protocmp.IgnoreFields(&fnv1.RunFunctionResponse{}, "desired")); diff != "" {
				t.Errorf("%s\nf.RunFunction(...): -want rsp, +got rsp:\n%s", tc.reason, diff)
			}

			if diff := cmp.Diff(tc.want.err, err, cmpopts.EquateErrors()); diff != "" {
				t.Errorf("%s\nf.RunFunction(...): -want err, +got err:\n%s", tc.reason, diff)
			}
		})
	}
}
