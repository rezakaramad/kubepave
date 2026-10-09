# otelcol-meta-collector

A small collector with one job: take the **other collectors' own health metrics** and forward them to Mimir. Who watches the watchers? This one.

## Four ways to monitor a collector

| # | How | Catch |
|---|---|---|
| 1 | The collector scrapes itself with its own Prometheus receiver | A loop: if it's stuck, its own metrics can't get out |
| 2 | Prometheus scrapes its port 8888 | Needs a Prometheus, and covers metrics only |
| 3 | The collector pushes straight to the backend | Every collector hits the backend on its own |
| 4 | The collector pushes to a **dedicated collector** | One extra small component |

## Why we chose 4

- **No loop.** A collector never reports through its own pipeline. If its memory limiter starts dropping data, the alarm still gets out.
- **One funnel.** Every collector in a cluster sends to one place, which then makes one connection to Mimir and tags everything with the cluster name.
- **Nothing new to run.** It's just another collector, with no Prometheus to install.

The meta-collector sends its own metrics straight to Mimir, not through itself (option 3), so it avoids the loop too.

## How it's wired

- The other collectors push every 60 s to `http://meta-collector.observability.svc:4318/v1/metrics` (`service.telemetry.metrics.readers`).
- The meta-collector forwards to Mimir over OTLP.

## Good to know

- It's one replica. If it's down, the internal metrics pause, but real telemetry keeps flowing. An alert on missing collector metrics would catch it.
- Metric names depend on the method (for example a `_bytes` suffix). Check the real names in Mimir before writing alerts.

Background: Adriana Villela's write-up ["Let's learn how to send internal OTel Collector telemetry to an observability backend"](https://medium.com/womenintechnology/lets-learn-how-to-send-internal-otel-collector-telemetry-to-an-observability-backend-9aef6a18f317).

You can read more about internal telemetry [here](https://opentelemetry.io/docs/collector/internal-telemetry).
