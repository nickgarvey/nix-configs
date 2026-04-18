# br-lan MDB / IPv6-stack desync

## Symptom

On the router, `bridge -d mdb show` for `br-lan` consistently has
**zero `host_joined` entries** (no rows with `port br-lan`) even while
`/proc/net/igmp6` shows the IPv6 stack has joined the usual groups on
the bridge — in particular `ff02::1:ff00:1` (solicited-node for the
router GUA `2001:470:482f::1`).

Structurally-verifiable via the `netaudit` dataset — see
`ipv6-control-audit/docs/schema.md` §11:

```sql
SELECT host, grp
FROM netaudit.igmp6
WHERE iface = 'br-lan'
  AND ts > now() - INTERVAL 3 MINUTE
  AND (host, grp) NOT IN (
      SELECT host, grp FROM netaudit.mdb
      WHERE bridge = 'br-lan' AND host_joined = 1
        AND ts > now() - INTERVAL 3 MINUTE
  )
GROUP BY host, grp;
```

A non-empty result means the bridge filter will drop multicast NS
targeting those groups before it reaches the local IP stack, so LAN
clients can't resolve the router's GUA over multicast NDP.

## History

`modules/router/default.nix` previously set `MulticastQuerier=true` on
the br-lan netdev on the theory that a local querier would trigger the
IPv6 stack to re-send MLD reports, which the bridge would then insert
as `host_joined` MDB entries. Evidence from the netaudit dataset: MLD
general queries **are** fired by the bridge every ~125s, and the IPv6
stack **does** emit MLDv1/v2 reports in response, but the bridge
snooping code never promotes those reports into `host_joined` rows for
the groups the local stack actually cares about. The fix didn't work.

## Current workaround (active)

`br-lan` has `MulticastSnooping=false`. That turns the bridge into a
plain IPv6-multicast flooder — every multicast frame goes out every
port, including the host stack — so the broken filter isn't consulted
at all.

Trade-off: wasted bandwidth on IPv6 multicast (MLD reports, NDP NS to
other hosts' solicited-node groups, mDNS, etc). On a ~dozen-host LAN
this is negligible.

## Possible real fixes (pick one when we come back to this)

1. **Kernel-path investigation.** Instrument `br_multicast_host_join` /
   `br_ip6_multicast_add_router` to learn why the local stack's MLD
   reports aren't creating `host_joined` rows on br-lan. Candidate
   suspects:
   - The `pmctx` passed on the RX-from-self path is not the one
     snooping expects. When the bridge's own IP stack emits an MLD
     report, it loops through `br_dev_xmit` with the bridge itself as
     source. The bridge's snooping code may only promote to
     `host_joined` on the ingress-from-physical-port path, never the
     self-TX path.
   - Interaction with `MulticastQuerier=true`: when the bridge is also
     the querier, its own TX-side snooping handling may differ from a
     pure passive snooper's.
   - Kernel version regression — worth diffing against a known-good
     kernel / bridge config.
2. **Static MDB entries.** `bridge mdb add dev br-lan port br-lan grp
   ff02::1:ff00:1 permanent` for the router's own solicited-node
   group(s). Precise, doesn't disable snooping fleet-wide, but has to
   track any address change on br-lan (script-from-SLAAC).
3. **Different bridge driver.** `nftables` flow-based forwarding or
   move the LAN off a Linux bridge entirely (hardware switch doing all
   multicast filtering). Overkill for homelab.
4. **Accept the flood.** Keep `MulticastSnooping=false` permanently and
   delete this doc. Snooping at homelab scale mostly costs power, not
   correctness.

## Related

- `modules/router/default.nix` — br-lan config, has a short TODO
  referencing this file.
- `ipv6-control-audit/` — the netaudit pipeline used to characterize
  the bug. See `docs/schema.md` §11 (desync), §12 (NUD transitions),
  `docs/runbook.md` ("Is the bridge snooping layer out of sync…").
- Earlier PROBLEM.txt analysis in `ndp-debug/` is **superseded**: it
  asserted `MulticastQuerier=true` was a no-op because the bridge
  wasn't actually querying. The netaudit dataset proves the bridge
  *does* query every 125s; the failure is further downstream in the
  snooping → MDB-insert path.
