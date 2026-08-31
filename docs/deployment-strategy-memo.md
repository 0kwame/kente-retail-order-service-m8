# Deployment Strategy: Blue-Green vs Canary

**To:** CTO, Kente Retail
**From:** Joseph Akayesi
**Re:** Which deployment strategy the order-service pipeline should use, and why
**Recommendation:** Blue-green. Implemented and demonstrable today.

---

## The decision in one paragraph

Both strategies remove the outage from a release. They differ in what they buy
with the complexity they cost. Canary buys **early detection of problems that
only show up under real traffic** — it pays for that with a period where two
versions serve customers at once, and with the monitoring needed to tell whether
the canary is actually healthy. Blue-green buys **an instant, complete reversal**
— one version serves at a time, and going back is a config reload. For a
single-service, stateless order API on one host, three weeks before the year's
biggest sales event, the ability to be *completely back to normal in under a
second* is worth more than the ability to detect a subtle regression slightly
earlier. That is the recommendation.

## Side by side

| | Blue-green | Canary |
|---|---|---|
| **Traffic during release** | 100% old, then 100% new | Split: e.g. 5% new, then 20%, then 100% |
| **Time to full rollback** | One nginx reload — sub-second, the old version never stopped | Shift traffic back, then decide what to do with the partially-migrated state |
| **Blast radius of a bad release** | 100% of users, for the seconds until rollback | 5% of users, for as long as it takes to notice |
| **What it needs to work** | Two environments, a switch, a health check | Weighted routing, per-version metrics, and an agreed "is the canary healthy?" rule |
| **Resource cost** | 2× the service (both colours always running) | ~1.1× |
| **Fails badly when** | The regression is only visible under production load, so the smoke test passes and 100% of users get it | Nobody is watching the metrics, so the canary sits at 5% quietly failing for hours |
| **State/schema handling** | Both colours share one database — migrations must be backward-compatible | Same problem, and for longer |

## Why blue-green, specifically for Kente Retail

**1. The requirement is zero downtime during Kente Fest, and blue-green gives a
guarantee rather than a reduction.** The old version keeps serving until the new
one has answered a health check and a behavioural smoke test. nginx then reloads,
which drains existing connections rather than dropping them. There is no window
in which nothing is listening — which is exactly what the current
`docker rm -f && docker run` release does have.

**2. Rollback speed is the metric that matters at peak.** During Kente Fest,
minutes of a broken checkout is real revenue. Blue-green rollback is a config
reload against a container that never stopped, so it is roughly as fast as the
switch was — about a second, and it needs no rebuild, no image pull, and no
redeploy. Canary rollback is faster to *start* but slower to reach a known-good
state, because you also have to reason about what the 5% did while they were on
the new version.

**3. Canary's advantage needs monitoring Kente Retail does not have yet.** A
canary is only as good as the rule that decides whether it is healthy. Without
per-version error rates and latency, a canary is just a slower blue-green with
extra steps — and one where 5% of customers are the monitoring. Blue-green's
health gate is a smoke test that either passes or does not, which works with the
observability that exists today.

**4. Doubling a single small container is cheap.** Blue-green's real cost is
running two copies. For one Spring Boot service on a t3.small that is
inconsequential. On a fleet of forty services it would be a genuine line item and
the calculation would change.

**5. It is one host.** Canary's traffic-splitting assumes a load balancer in front
of multiple instances. On a single deploy target, splitting traffic means nginx
weights across two local containers — technically possible, but you get canary's
complexity without canary's isolation, since both colours share the host, the
kernel and the database.

## What blue-green does not solve, stated plainly

- **Database migrations.** Both colours talk to the same data. The moment
  order-service owns a schema, every release needs migrations that are
  backward-compatible with the colour still running, or the rollback is a lie —
  you can put the old container back and it will fail against the new schema.
  This is the single biggest gap between this pipeline and a production-ready one,
  and it should be the next piece of work.
- **Regressions invisible to a smoke test.** A memory leak that takes an hour, or
  a slow query that only bites at peak concurrency, will pass the pre-switch smoke
  test and reach 100% of users. Canary would have caught these. The mitigation
  here is that rollback is fast and cheap, so the fix is "notice and revert
  quickly" rather than "expose fewer people".
- **In-flight requests at the moment of switch.** nginx drains, so requests
  already being served finish against the old colour. Anything that assumes
  sticky state across requests would need more thought; this service has none.

## The migration path, when it is worth it

The nginx upstream file that makes this work is one line. Moving to canary later
does not mean rebuilding the pipeline — it means changing that file to two
weighted `server` lines and adding a stage that reads per-colour error rates
before proceeding. That is a natural next step **once there is monitoring worth
gating on**, and I would revisit it after Kente Fest rather than before.

## Recommendation

**Adopt blue-green now.** It meets the zero-downtime requirement with a guarantee,
gives the fastest possible route back to a known-good state, needs no monitoring
Kente Retail does not yet have, and is already implemented and demonstrable in
this repo.

**Revisit canary after Kente Fest**, together with per-version metrics and the
schema-migration work — which is the harder and more valuable of the two.
