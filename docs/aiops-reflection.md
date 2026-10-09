# AIOps reflection

AIOps (AI for IT operations) means using machine learning on logs and metrics to
find problems, group alerts and suggest causes. This note says where it would have
helped with the 02:11 incident, and where it would not.

## What the rule-based setup already catches

The incident has one clear signal: a request for `/actuator` from outside. A fixed
rule catches that on the first request. Prometheus alerts catch an error ratio above
5%, and the CloudWatch alarm catches `/actuator` and 404 bursts. For a known
pattern with a known path, a model adds nothing but cost and a new thing to explain.

## Where AIOps would add value

- **Unknown patterns.** A scanner that changes paths each time does not match my
  list. Anomaly detection on the share of 404s per client would still notice it.
  CloudWatch has anomaly detection for metrics, but it needs weeks of normal data to
  learn from.
- **Alert fatigue.** When many alerts fire for one cause, grouping them into one
  incident saves a person from reading ten messages at 02:00.
- **First-draft diagnosis.** A model can read a Logs Insights result and write the
  first summary: one IP, six probe paths, three leaked responses. This saves minutes,
  but a person must still check it, because a fluent summary can be wrong.

## Where I would not use it

- **Automatic action.** A model should not roll back a release or block an IP on its
  own. A false positive at peak time during Kente Fest is a self-made outage.
  Rollback here costs one second, so the person can do it after reading the alert.
- **Low traffic.** This service has very little traffic. A learned baseline on a few
  requests per minute is noise, and one customer who refreshes a page looks like an
  anomaly.
- **Data.** The access log has client IP addresses. Sending them to an outside model
  is a privacy decision for the client (CTO question 7).

## My conclusion

Fixed rules first, because they are cheap, explainable and enough for this incident.
Add anomaly detection after there is at least a month of real traffic and a Slack
channel with an owner. Use AI to write summaries and keep the decision with the
on-call person. I applied the same rule to my own use of AI in `docs/ai-log.md`: it
is good for drafts, and every fact still gets checked by running something.
