# MTTR reflection: the 02:11 to 02:18 window

MTTR (mean time to recover) is the average time from the start of a failure to the
end of its impact. It has three parts: detect, diagnose, repair. The supplied
incident log lets me measure each part against the new setup.

## What the log shows

IP `203.0.113.77` made its first probe at 02:11:42. At 02:11:58 `/actuator`
returned 200. At 02:14:52, 02:15:37 and 02:16:12 `/actuator/env` returned 200 with
8,423 bytes each time, and that response held the database password. At 02:18:29
the same path started to return 403. So the exposure lasted 6 minutes 47 seconds
from the first probe, and 3 minutes 37 seconds from the first leaked response to the
block. The log has no sign that anyone saw it while it happened.

## Where the time went, and what changed

| Part | Before | Now |
|---|---|---|
| Detect | Nobody was told. The block came because someone read the log later. | The `actuator-probe` alarm counts any `/actuator` request that reaches nginx. In the AWS run, a request for `/actuator/env` at 21:00:49 put the alarm in ALARM at 21:01:35, which is 46 seconds, and Slack had the message. The same delay after the 02:11:58 request would give an alert at about 02:12:45, which is before the first leaked response at 02:14:52. |
| Diagnose | Search two log files by hand. | One Logs Insights query returns the IP, the paths, the status and the first and last time. The dashboard shows the error ratio by `uri`. |
| Repair | A code or proxy change, then a deploy that stopped the old container first. | nginx returns 403 for `/actuator`, and a release moves traffic in about a second with a one-second rollback. |

## What faster recovery does not fix

The three leaked responses already left the building. Recovery time for the
service was short, but the password was exposed, so the real repair is to rotate the
secret. `scripts/set-secrets.sh --rotate-db` makes that one command, and the app
reads the new value at the next deploy. A short MTTR is good, but it does not reduce
the damage from data that has already gone. Only the controls from Problem 1
(no secret in the repo, no value shown by `/actuator/env`, nginx block) prevent it.

## Honest limits

The alert needs a person to read it. If the Slack channel has no owner at 02:00, the
detect time is the time until someone looks at their phone. The 404 alarm and the
error-ratio alert also need tuning with real traffic, because my thresholds are
starting values.
