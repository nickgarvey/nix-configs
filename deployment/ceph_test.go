package main

import (
	"fmt"
	"testing"
	"time"
)

// osdTreeJSON is `ceph osd tree -f json` for the three-node cluster, trimmed,
// with each OSD's status given.
func osdTreeJSON(joor, zah, frul string) string {
	return fmt.Sprintf(`{"nodes":[
{"id":-1,"name":"default","type":"root","children":[-5,-3,-7]},
{"id":-7,"name":"frul","type":"host","children":[2]},
{"id":2,"name":"osd.2","type":"osd","status":%q},
{"id":-3,"name":"joor","type":"host","children":[0]},
{"id":0,"name":"osd.0","type":"osd","status":%q},
{"id":-5,"name":"zah","type":"host","children":[1]},
{"id":1,"name":"osd.1","type":"osd","status":%q}],"stray":[]}`, frul, joor, zah)
}

const pgStatClean = `{"pg_ready":true,"pg_summary":{"num_pg_by_state":[{"name":"active+clean","num":194}],"num_pgs":194}}`
const pgStatDegraded = `{"pg_ready":true,"pg_summary":{"num_pg_by_state":[{"name":"active+clean","num":130},{"name":"active+undersized+degraded","num":64}],"num_pgs":194}}`

func cephHost(name string) Host {
	for _, h := range AllHosts {
		if h.Name == name {
			return h
		}
	}
	panic("no host " + name)
}

func TestStorageHostsHaveCephGate(t *testing.T) {
	for _, n := range []string{"joor", "zah", "frul"} {
		if !cephHost(n).CephHealthCheck {
			t.Errorf("%s: CephHealthCheck not set", n)
		}
	}
}

func TestCephBeforeDeployRefusesWhenAnotherNodeIsDown(t *testing.T) {
	fake := &FakeRunner{Responses: []FakeResponse{
		{Match: MatchContains("ceph osd tree"), Result: RunResult{Stdout: osdTreeJSON("up", "down", "up")}},
	}}
	if CephBeforeDeploy(fake, cephHost("joor")) {
		t.Fatal("expected refusal: zah's OSD is down")
	}
	if len(fake.CallsContaining("set-group noout")) != 0 {
		t.Error("noout must not be set when refusing")
	}
}

func TestCephBeforeDeployAllowsFixingOwnDownOSD(t *testing.T) {
	fake := &FakeRunner{Responses: []FakeResponse{
		{Match: MatchContains("ceph osd tree"), Result: RunResult{Stdout: osdTreeJSON("down", "up", "up")}},
	}}
	if !CephBeforeDeploy(fake, cephHost("joor")) {
		t.Fatal("expected to proceed: only joor's own OSD is down")
	}
	if len(fake.CallsContaining("sudo ceph osd set-group noout joor")) != 1 {
		t.Error("expected noout set on joor")
	}
}

func noSleep(time.Duration) {}

func TestCephAfterDeployWaitsThenClearsNoout(t *testing.T) {
	polls := 0
	fake := &FakeRunner{Responses: []FakeResponse{
		{Match: func(argv []string) bool {
			if !MatchContains("ceph pg stat")(argv) {
				return false
			}
			polls++
			return polls <= 2
		}, Result: RunResult{Stdout: pgStatDegraded}},
		{Match: MatchContains("ceph pg stat"), Result: RunResult{Stdout: pgStatClean}},
		{Match: MatchContains("ceph osd tree"), Result: RunResult{Stdout: osdTreeJSON("up", "up", "up")}},
	}}
	if !CephAfterDeploy(fake, cephHost("zah"), noSleep) {
		t.Fatal("expected healthy after PGs recover")
	}
	if polls != 3 {
		t.Errorf("expected 3 pg polls, got %d", polls)
	}
	if len(fake.CallsContaining("sudo ceph osd unset-group noout zah")) != 1 {
		t.Error("expected noout cleared on zah")
	}
}

func TestCephAfterDeployTimeoutKeepsNoout(t *testing.T) {
	fake := &FakeRunner{Responses: []FakeResponse{
		{Match: MatchContains("ceph osd tree"), Result: RunResult{Stdout: osdTreeJSON("up", "down", "up")}},
		{Match: MatchContains("ceph pg stat"), Result: RunResult{Stdout: pgStatDegraded}},
	}}
	if CephAfterDeploy(fake, cephHost("zah"), noSleep) {
		t.Fatal("expected failure: zah's OSD never comes back")
	}
	if len(fake.CallsContaining("unset-group noout")) != 0 {
		t.Error("noout must stay set when Ceph is not healthy")
	}
}

func TestDeployRefusedByCephNeverActivates(t *testing.T) {
	resps := append([]FakeResponse{
		{Match: MatchContains("ceph osd tree"), Result: RunResult{Stdout: osdTreeJSON("up", "up", "down")}},
	}, buildOKResponses(fakeSystemPath)...)
	fake := &FakeRunner{Responses: resps}
	var warnings []string
	ctx := testCtx(fake)
	ctx.Warnings = &warnings
	if Deploy(ctx, cephHost("joor"), ModeSafe, Plan{SystemPath: fakeSystemPath}) {
		t.Fatal("expected refusal: frul's OSD is down")
	}
	if len(fake.CallsContaining("switch-to-configuration")) != 0 {
		t.Error("must not activate when the Ceph gate refuses")
	}
}

func TestDeployCephHappyPathClearsNoout(t *testing.T) {
	resps := append([]FakeResponse{
		{Match: MatchContains("ceph osd tree"), Result: RunResult{Stdout: osdTreeJSON("up", "up", "up")}},
		{Match: MatchContains("ceph pg stat"), Result: RunResult{Stdout: pgStatClean}},
	}, buildOKResponses(fakeSystemPath)...)
	fake := &FakeRunner{Responses: resps}
	var warnings []string
	ctx := testCtx(fake)
	ctx.Warnings = &warnings
	host := cephHost("frul")
	host.K8sHealthCheck = false // covered by the k8s tests
	if !Deploy(ctx, host, ModeSafe, Plan{SystemPath: fakeSystemPath}) {
		t.Fatal("expected success")
	}
	assertOrder(t, joinedCalls(fake), []string{
		"ceph osd set-group noout frul",
		"switch-to-configuration test",
		"switch-to-configuration boot",
		"ceph osd unset-group noout frul",
	})
	if len(warnings) != 0 {
		t.Errorf("unexpected warnings: %v", warnings)
	}
}
